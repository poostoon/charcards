-- main.lua
-- CharCards — мінімалістичний, повністю ручний трекер персонажів для KOReader.
--
-- Жодного автосканування, жодного фонового пошуку по тексту. Дії:
--   1) Виділив ім'я персонажа в тексті → "Додати персонажа" — бере це ім'я
--      + контекст (поточна сторінка + кілька сторінок назад), питає Gemini
--      повну картку (роль, псевдоніми, професія, зовнішність, характер,
--      звʼязки — та сама структура полів, що й у KoCharacters), зберігає.
--   2) Виділив довільний уривок → "Додати до персонажа" — обираєш зі списку
--      вже доданих персонажів; Gemini аналізує цитату СВОЇМИ словами (не
--      копіює її) і визначає, ЯКІ поля картки вона поповнює (професія,
--      зовнішність, характер, звʼязки, псевдоніми, роль) — плагін сам
--      домішує кожен шматок у потрібне поле, а не в один загальний список.
--   3) "Серія книг" — за бажанням, книгу можна прив'язати до спільної серії,
--      щоб персонажі (і вся їхня картка) переходили з першої книги в другу,
--      а не починались щоразу з нуля.
--
-- Дані зберігаються в сайдкарі книги (self.ui.doc_settings) — окремо від
-- будь-якого іншого плагіна, нічого спільного з KoCharacters. Якщо книга
-- прив'язана до серії — замість сайдкара книги картки читаються/пишуться
-- у спільний файл серії (DataStorage:getDataDir() .. "/charcards_series/").
--
-- Схема картки:
--   { id, name, aliases[], occupation, physical_description,
--     personality, relationships[], background, standout_trait }
-- (роль і окремий "звʼязок з головним персонажем" навмисно прибрані —
-- роль AI визначала ненадійно (фальс-аларми), а звʼязки з іншими
-- персонажами вже покриваються полем relationships)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager        = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local InputDialog       = require("ui/widget/inputdialog")
local ConfirmBox        = require("ui/widget/confirmbox")
local TextViewer        = require("ui/widget/textviewer")
local Menu              = require("ui/widget/menu")
local Screen            = require("device").screen
local Blitbuffer        = require("ffi/blitbuffer")
local InputContainer    = require("ui/widget/container/inputcontainer")
local FrameContainer    = require("ui/widget/container/framecontainer")
local OverlapGroup      = require("ui/widget/overlapgroup")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local TextBoxWidget     = require("ui/widget/textboxwidget")
local Font              = require("ui/font")
local Geom              = require("ui/geometry")
local GestureRange      = require("ui/gesturerange")
local DataStorage       = require("datastorage")
local LuaSettings       = require("luasettings")
local lfs               = require("libs/libkoreader-lfs")
local logger            = require("logger")

local ok_networkmgr, NetworkMgr = pcall(require, "ui/network/manager")

local json  = require("dkjson")
local https = require("ssl.https")
local ltn12 = require("ltn12")

local MODEL    = "gemini-3.1-flash-lite-preview"
local API_BASE = "https://generativelanguage.googleapis.com/v1beta/models/" .. MODEL .. ":generateContent"
local SETTING_UNDERLINE_ON = "charcards_underline_enabled"

local function log(msg) logger.info("CharCards: " .. tostring(msg)) end

-- ===== Ключ Gemini API — окремий файл api.lua ПРЯМО В ПАПЦІ ПЛАГІНА =====
-- Навмисно не в koreader/settings/ і не в спільному settings.reader.lua:
-- сюди можна підкласти ключ вручну через USB (одним рядком, без набору
-- довгого ключа на сенсорному екрані), відредагувавши звичайним текстовим
-- редактором. Формат файлу — просто return "ключ".
--
-- Застереження: цей файл лежить у теці ПЛАГІНА, тож при оновленні плагіна
-- (розпакування нової версії поверх/замість старої теки) він, на відміну
-- від koreader/settings/, може злетіти разом з рештою файлів — тоді
-- достатньо один раз ввести ключ на пристрої знову (діалог нижче сам його
-- перезапише в новий api.lua) або скопіювати старий api.lua в нову теку.

local function getPluginDir()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*)[/\\][^/\\]+$") or "."
end

local PLUGIN_DIR    = getPluginDir()
local API_KEY_FILE  = PLUGIN_DIR .. "/api.lua"

local function getApiKeySetting()
    local ok_load, chunk = pcall(loadfile, API_KEY_FILE)
    if not ok_load or not chunk then return nil end
    local ok_run, result = pcall(chunk)
    if not ok_run then
        log("api.lua: помилка виконання — " .. tostring(result))
        return nil
    end
    local key
    if type(result) == "string" then
        key = result
    elseif type(result) == "table" and type(result.key) == "string" then
        key = result.key
    end
    key = (key or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return key ~= "" and key or nil
end

local function saveApiKeySetting(key)
    key = (key or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local f = io.open(API_KEY_FILE, "w")
    if not f then
        log("не вдалося записати " .. API_KEY_FILE)
        return false
    end
    local escaped = key:gsub("\\", "\\\\"):gsub('"', '\\"')
    f:write("-- Ключ Gemini API для CharCards.\n")
    f:write("-- Можна редагувати вручну (через USB, звичайним текстовим редактором)\n")
    f:write("-- або через меню плагіна в KOReader. Формат: один рядок, return \"ключ\".\n")
    f:write('return "' .. escaped .. '"\n')
    f:close()
    return true
end

-- ===== Перевірка мережі перед зверненням до Gemini =====
-- Якщо Wi-Fi вимкнено — пропонує його ввімкнути (штатний діалог KOReader),
-- замість того щоб просто впасти з помилкою мережі.

local function ensureNetworkThen(on_ready)
    if not ok_networkmgr or not NetworkMgr then
        on_ready()  -- не можемо перевірити на цій платформі — пробуємо як є
        return
    end

    local connected = true
    pcall(function() connected = NetworkMgr:isConnected() end)
    if connected then
        on_ready()
        return
    end

    local wifi_on = true
    pcall(function() wifi_on = NetworkMgr:isWifiOn() end)
    if not wifi_on and NetworkMgr.promptWifiOn then
        local ok_prompt = pcall(function() NetworkMgr:promptWifiOn() end)
        if ok_prompt then
            UIManager:show(InfoMessage:new{
                text = "Коли Wi-Fi увімкнеться, повтори дію ще раз.",
                timeout = 4,
            })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = "Немає підключення до інтернету.", timeout = 3 })
end

-- ===== Українська нечутливість до регістру (Lua :lower() кирилицю не чіпає) =====

local CYR_LOWER = {}
do
    for b = 0x90, 0x9F do CYR_LOWER[string.char(0xD0, b)] = string.char(0xD0, b + 0x20) end -- А-П
    for b = 0xA0, 0xAF do CYR_LOWER[string.char(0xD0, b)] = string.char(0xD1, b - 0x20) end -- Р-Я
    for b = 0x80, 0x8F do CYR_LOWER[string.char(0xD0, b)] = string.char(0xD1, b + 0x10) end -- Ё Є І Ї ...
    CYR_LOWER[string.char(0xD2, 0x90)] = string.char(0xD2, 0x91) -- Ґ -> ґ
end
local function ukLower(s)
    if not s or s == "" then return "" end
    return (s:lower():gsub("[\208\209\210][\128-\191]", CYR_LOWER))
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
end

-- ===== JSON-виклик Gemini =====

local function stripCodeFences(text)
    return text:match("^```json%s*(.-)%s*```$")
        or text:match("^```%s*(.-)%s*```$")
        or text
end

-- Надсилає prompt, очікує від Gemini ЧИСТИЙ JSON-об'єкт у відповіді.
-- Повертає parsed_table, nil  АБО  nil, error_message.
local function callGemini(api_key, prompt)
    if not api_key or api_key == "" then
        return nil, "API-ключ не задано."
    end

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.2, maxOutputTokens = 1024 },
    })

    local response_body = {}
    local url = API_BASE .. "?key=" .. api_key

    local ok, status = https.request({
        url     = url,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then
        return nil, "Помилка мережі: " .. tostring(status)
    end
    if status ~= 200 then
        local raw = table.concat(response_body)
        local parsed = json.decode(raw)
        local detail = parsed and parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "Помилка API (HTTP " .. tostring(status) .. "): " .. tostring(detail)
    end

    local raw = table.concat(response_body)
    local parsed, _, err = json.decode(raw)
    if not parsed then
        return nil, "Не вдалося розібрати відповідь Gemini: " .. tostring(err)
    end

    local text
    if parsed.candidates and parsed.candidates[1]
       and parsed.candidates[1].content and parsed.candidates[1].content.parts
       and parsed.candidates[1].content.parts[1] then
        text = parsed.candidates[1].content.parts[1].text
    end
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1] and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini не повернув тексту (finishReason: " .. tostring(reason) .. ")"
    end

    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then
        return nil, "Gemini повернув невалідний JSON: " .. tostring(jerr) .. "\nСирий текст: " .. text:sub(1, 200)
    end
    return result
end

-- ===== Видобування тексту з EPUB (unzip + OPF spine), той самий перевірений =====
-- ===== метод, що вже надійно працює на цьому пристрої в KoCharacters.     =====

local function stripHtml(raw)
    local text = raw
    text = text:gsub("<[^>]+>", " ")
    text = text:gsub("&nbsp;",  " ")
    text = text:gsub("&amp;",   "&")
    text = text:gsub("&lt;",    "<")
    text = text:gsub("&gt;",    ">")
    text = text:gsub("&quot;",  '"')
    text = text:gsub("&apos;",  "'")
    text = text:gsub("&mdash;", "—")
    text = text:gsub("&ndash;", "–")
    text = text:gsub("&hellip;", "…")
    text = text:gsub("&laquo;", "«")
    text = text:gsub("&raquo;", "»")
    text = text:gsub("&[lr]squo;", "'")
    text = text:gsub("&[lr]dquo;", '"')
    text = text:gsub("&#%d+;",  " ")
    text = text:gsub("%s+",     " ")
    text = text:gsub("^%s+",    "")
    text = text:gsub("%s+$",    "")
    return text
end

-- Дістає HTML n-го елемента spine з .epub (n рахується від 1). nil, err якщо не вдалось.
local function popenRead(cmd)
    local ok, result = pcall(function()
        local h = io.popen(cmd, "r")
        if not h then return nil end
        local s = h:read("*a"); h:close(); return s
    end)
    if ok then return result end
    return nil
end

-- Діагностика на випадок, якщо unzip не спрацював: чи є бінарник взагалі,
-- чи проблема в чомусь іншому (права, шлях до файлу тощо). Викликається
-- лише коли основний виклик УЖЕ провалився — цінності на успішному шляху
-- не додає, тому не робимо це на кожен виклик.
local function diagnoseUnzip(epub_path)
    local parts = {}

    local which_out = popenRead("command -v unzip 2>&1")
    if not which_out or which_out:gsub("%s+", "") == "" then
        table.insert(parts, "бінарник unzip не знайдено в PATH")
    else
        table.insert(parts, "unzip знайдено: " .. trim(which_out))
    end

    local ver_out = popenRead("unzip -v 2>&1")
    if ver_out and ver_out ~= "" then
        table.insert(parts, "unzip -v: " .. trim(ver_out:match("^[^\n]*") or ver_out):sub(1, 120))
    end

    local ok_exists = popenRead("test -f '" .. epub_path .. "' && echo так || echo ні")
    table.insert(parts, "файл книги існує (test -f): " .. trim(ok_exists or "невідомо"))

    return table.concat(parts, " | ")
end

-- Дефіс, крапка та інші символи в id зі spine/manifest — спецсимволи в Lua
-- patterns (напр. "-" — лінивий повторювач), а не літерали. Без екранування
-- id з дефісом (звичайнісінька річ: "cover-page", "chapter-5" і т.д.) просто
-- ніколи не знаходиться, і весь ланцюжок мовчки падає.
local function escapeLuaPattern(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- href у маніфесті OPF за специфікацією МАЄ бути URI-кодованим (те, що
-- більшість генераторів цього не роблять для ASCII-імен — окрема історія),
-- і деякі конвертери таки кодують кириличні href як %D0%9B%D0%B5... — тоді
-- як самі імена файлів у ZIP лежать розкодованими. Без декодування шлях,
-- який ми підставляємо в unzip -p, просто не існує в архіві.
local function urlDecode(s)
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    return s
end

-- Дістає HTML n-го елемента spine з .epub (n рахується від 1). nil, err якщо не вдалось.
--
-- ВАЖЛИВО: тут навмисно немає жодного unzip -l (список файлів архіву).
-- На деяких пристроях (busybox unzip, поширений на бюджетних e-ink) -l
-- ламається саме на архівах із кириличними/нелатинськими назвами файлів
-- усередині — повертає порожній вивід, хоча сам файл читається абсолютно
-- нормально. META-INF/container.xml — фіксований, завжди ASCII шлях за
-- стандартом EPUB (OCF), тому його можна читати напряму через unzip -p,
-- а звідти вже дістати справжній шлях до .opf, і так по ланцюжку — без
-- жодного разу не звертаючись до листингу архіву.
local function fetchSpineChapterHtml(epub_path, n)
    local container = popenRead("unzip -p '" .. epub_path .. "' 'META-INF/container.xml' 2>/dev/null")
    if not container or #container < 20 then
        return nil, "не вдалося прочитати META-INF/container.xml (" .. diagnoseUnzip(epub_path) .. ")"
    end
    local opf_path = container:match('full%-path="([^"]+)"')
    if not opf_path then return nil, "container.xml: не знайдено full-path" end

    local opf = popenRead("unzip -p '" .. epub_path .. "' '" .. opf_path .. "' 2>/dev/null")
    if not opf or #opf < 50 then
        return nil, "не вдалося прочитати .opf (" .. diagnoseUnzip(epub_path) .. ")"
    end

    local count, item_id = 0, nil
    for idref in opf:gmatch([[itemref[^>]+idref="([^"]+)"]]) do
        count = count + 1
        if count == n then item_id = idref; break end
    end
    if not item_id then return nil, "spine#" .. n .. " не знайдено" end

    local esc_id = escapeLuaPattern(item_id)
    local pat1 = [[item[^>]+href="([^"]+)"[^>]+id="]] .. esc_id .. [["]]
    local pat2 = [[item[^>]+id="]] .. esc_id .. [["[^>]+href="([^"]+)"]]
    local href = opf:match(pat2) or opf:match(pat1)
    if not href then return nil, "href для spine-елемента не знайдено" end
    href = urlDecode(href)

    local base = opf_path:match("^(.*/)") or ""
    local full = base .. href
    local chapter = popenRead("unzip -p '" .. epub_path .. "' '" .. full .. "' 2>/dev/null")
    if not chapter or #chapter < 100 then
        return nil, "не вдалося прочитати розділ (" .. diagnoseUnzip(epub_path) .. ")"
    end
    return chapter
end

-- Контекст для нової картки: поточна сторінка + до back_pages сторінок назад,
-- у межах одного spine-елемента (розділу). Якщо персонаж з'явився одразу на
-- початку розділу — вікно просто впирається в початок розділу, це нормальна,
-- прогнозована деградація, не помилка.
local function getContextText(self, back_pages)
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then return nil, "немає відкритої книги" end
    if type(doc.getPageXPointer) ~= "function" then
        return nil, "цей тип документа не підтримується (потрібен EPUB/FB2-подібний)"
    end

    local page
    local ok_pg = pcall(function() page = self.ui.view.state.page end)
    if not ok_pg or not page then return nil, "не вдалося визначити сторінку" end

    local ok1, xp_cur = pcall(function() return doc:getPageXPointer(page) end)
    if not ok1 or not xp_cur then return nil, "getPageXPointer не вдався" end
    local ok2, pos_cur = pcall(function() return doc:getPosFromXPointer(xp_cur) end)
    if not ok2 or not pos_cur then return nil, "getPosFromXPointer не вдався" end

    local frag_idx = tonumber(tostring(xp_cur):match("DocFragment%[(%d+)%]")) or 1

    -- Кінець вікна: кінець поточної сторінки (не заходимо вперед).
    local pos_end = pos_cur
    local ok3, xp_end = pcall(function() return doc:getPageXPointer(page + 1) end)
    if ok3 and xp_end then
        local ok4, p = pcall(function() return doc:getPosFromXPointer(xp_end) end)
        if ok4 and p then pos_end = p end
    end

    -- Початок вікна: позиція за back_pages сторінок до поточної.
    local back_page = math.max(1, page - (back_pages or 2))
    local pos_back = pos_cur
    local ok5, xp_back = pcall(function() return doc:getPageXPointer(back_page) end)
    if ok5 and xp_back then
        local ok6, p = pcall(function() return doc:getPosFromXPointer(xp_back) end)
        if ok6 and p then pos_back = p end
    end

    -- Межі поточного фрагмента (розділу) — потрібні, щоб перевести позиції
    -- в частку 0..1 і застосувати цю частку до вже очищеного HTML-тексту.
    local frag_start_pos, frag_end_pos = 0, 0
    local ok_toc, toc = pcall(function() return doc:getToc() end)
    if ok_toc and type(toc) == "table" then
        local best_page, best_idx = 0, 0
        for i, entry in ipairs(toc) do
            local ep = tonumber(entry.page) or 0
            if ep <= page and ep > best_page then
                best_page, best_idx = ep, i
                if entry.xpointer then
                    local ok_xp, p = pcall(function() return doc:getPosFromXPointer(entry.xpointer) end)
                    if ok_xp and p then frag_start_pos = p end
                end
            end
        end
        local next_entry = toc[best_idx + 1]
        if next_entry and next_entry.xpointer then
            local ok_xp, p = pcall(function() return doc:getPosFromXPointer(next_entry.xpointer) end)
            if ok_xp and p then frag_end_pos = p end
        end
    end

    local chapter, err = fetchSpineChapterHtml(doc.file, frag_idx)
    if not chapter then return nil, err end

    local text = stripHtml(chapter)
    if #text < 50 then return nil, "після очищення тексту замало" end

    local frag_span = math.max((frag_end_pos > 0 and frag_end_pos or pos_end + 20000) - frag_start_pos, 1)
    local function ratioOf(pos)
        return math.max(0, math.min(1, (pos - frag_start_pos) / frag_span))
    end

    local s = math.max(1, math.floor(ratioOf(pos_back) * #text))
    local e = math.min(#text, math.max(s + 200, math.floor(ratioOf(pos_end) * #text)))

    local MAX = 6000
    if e - s > MAX then s = e - MAX end
    return text:sub(s, e)
end

-- ===== Серії книг (спільний пул персонажів на кілька книг) =====
--
-- За замовчуванням книга не прив'язана до жодної серії — картки лежать
-- у сайдкарі книги, як і раніше, кожна книга ізольована. Якщо користувач
-- явно привʼязує книгу до серії (KoCharacters → Серія книг), картки для
-- цієї книги перенаправляються в СПІЛЬНИЙ файл серії — читання/запис,
-- підкреслення в тексті, усе працює з цим спільним пулом. Прив'язка сама
-- по собі — це один маленький покажчик у сайдкарі КОЖНОЇ книги окремо
-- (self.ui.doc_settings), тому різні книги можуть незалежно вирішувати,
-- до якої серії (чи жодної) вони належать.

local SERIES_DIR = DataStorage:getDataDir() .. "/charcards_series"

local function ensureSeriesDir()
    if lfs.attributes(SERIES_DIR, "mode") ~= "directory" then
        lfs.mkdir(SERIES_DIR)
    end
end

-- Прибираємо символи, небезпечні для імені файлу; кирилицю лишаємо як є.
local function sanitizeSeriesId(name)
    return trim(name):gsub('[/\\:%*%?"<>|]', "_")
end

local function getSeriesFile(series_id)
    ensureSeriesDir()
    return LuaSettings:open(SERIES_DIR .. "/" .. series_id .. ".lua")
end

-- Список усіх наявних серій — {id=, name=} — читає директорію напряму,
-- окремого індексного файлу не тримаємо (менше що може розсинхронізуватись).
local function listSeries()
    ensureSeriesDir()
    local list = {}
    for entry in lfs.dir(SERIES_DIR) do
        if entry:match("%.lua$") then
            local id = entry:gsub("%.lua$", "")
            local ok, s = pcall(LuaSettings.open, LuaSettings, SERIES_DIR .. "/" .. entry)
            local name = (ok and s and s:readSetting("name")) or id
            table.insert(list, { id = id, name = name })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function getSeriesId(self)
    local id = self.ui.doc_settings and self.ui.doc_settings:readSetting("charcards_series_id")
    if id and id ~= "" then return id end
    return nil
end

local function setSeriesId(self, series_id)
    if not self.ui.doc_settings then return end
    self.ui.doc_settings:saveSetting("charcards_series_id", series_id or "")
    self.ui.doc_settings:flush()
end

-- ===== Зберігання карток (сайдкар книги — або спільний файл серії, якщо привʼязано) =====

-- Підпис набору персонажів (імена+псевдоніми) — використовується і для
-- кешу підкреслень, і тут, щоб зрозуміти, чи saveCards() реально додав/
-- прибрав якесь ІМʼЯ (а не просто оновив поле в уже наявного персонажа).
local function cardsSignature(cards)
    local parts = {}
    for _, c in ipairs(cards) do
        table.insert(parts, c.name or "")
        if c.aliases then for _, a in ipairs(c.aliases) do table.insert(parts, a) end end
    end
    return table.concat(parts, "|")
end

-- Які саме імена/псевдоніми є в new_cards, але не було в old_cards — щоб
-- пересканувати книгу на предмет ЛИШЕ нового імені, а не всіх персонажів
-- заново (позиції вже відомих персонажів і так лежать у кеші).
local function newTermsSince(old_cards, new_cards)
    local old_set = {}
    for _, c in ipairs(old_cards) do
        if c.name then old_set[trim(c.name)] = true end
        if c.aliases then for _, a in ipairs(c.aliases) do old_set[trim(a)] = true end end
    end
    local new_terms = {}
    for _, c in ipairs(new_cards) do
        local names = { c.name }
        if c.aliases then for _, a in ipairs(c.aliases) do table.insert(names, a) end end
        for _, n in ipairs(names) do
            local clean = trim(n)
            if #clean >= 3 and not old_set[clean] then
                table.insert(new_terms, clean)
                old_set[clean] = true  -- уникнути дублів у самому new_terms
            end
        end
    end
    return new_terms
end

local function loadCards(self)
    local series_id = getSeriesId(self)
    if series_id then
        local data = getSeriesFile(series_id):readSetting("cards")
        if type(data) ~= "table" then data = {} end
        return data
    end
    local data = self.ui.doc_settings and self.ui.doc_settings:readSetting("charcards")
    if type(data) ~= "table" then data = {} end
    return data
end

-- Пересканування (і, відповідно, підкреслення) запускаємо ЛИШЕ якщо набір
-- імен/псевдонімів справді змінився — новий персонаж чи нове ім'я для вже
-- наявного. Просте оновлення поля (характер, звʼязки тощо) на пошук у
-- тексті ніяк не впливає, тож і сканувати книгу заново нема сенсу.
local function saveCards(self, cards)
    local old_cards = loadCards(self)
    local old_sig = cardsSignature(old_cards)
    local new_sig = cardsSignature(cards)
    local new_terms = (old_sig ~= new_sig) and newTermsSince(old_cards, cards) or nil

    local series_id = getSeriesId(self)
    if series_id then
        local s = getSeriesFile(series_id)
        s:saveSetting("cards", cards)
        s:flush()
    elseif self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("charcards", cards)
        self.ui.doc_settings:flush()
    else
        return
    end

    if new_terms and self._scheduleRescan then
        self:_scheduleRescan(new_terms)
    end
end

local function findCardByName(cards, name)
    local target = ukLower(trim(name))
    for _, c in ipairs(cards) do
        if ukLower(c.name) == target then return c end
        if c.aliases then
            for _, a in ipairs(c.aliases) do
                if ukLower(a) == target then return c end
            end
        end
    end
    return nil
end

-- ===== Поля картки: підписи й логіка домішування нової інформації =====

-- Дописує нове значення до текстового поля, лише якщо його там ще немає
-- (проста підрядкова перевірка, регістронезалежна щодо кирилиці) — так
-- поле накопичується, а не втрачає вже відоме. Використовується ЛИШЕ для
-- об'єднання двох уже повних карток (привʼязка до серії, дивись нижче) —
-- там нема іншого проходу AI, який міг би переписати текст начисто.
local function mergeTextField(existing, new_value)
    new_value = trim(new_value or "")
    if new_value == "" then return existing, false end
    existing = existing or ""
    if existing == "" then return new_value, true end
    if ukLower(existing):find(ukLower(new_value), 1, true) then
        return existing, false  -- вже є ця інформація (чи її частина)
    end
    return existing .. "; " .. new_value, true
end

-- Додає нові елементи в масив (aliases/relationships) з дедуплікацією
-- проти вже наявних (регістронезалежно, кирилиця враховується).
local function mergeArrayField(existing, new_items)
    existing = existing or {}
    if type(new_items) ~= "table" then return existing, false end
    local seen = {}
    for _, v in ipairs(existing) do seen[ukLower(trim(v))] = true end
    local added = false
    for _, v in ipairs(new_items) do
        v = trim(v)
        if v ~= "" and not seen[ukLower(v)] then
            table.insert(existing, v)
            seen[ukLower(v)] = true
            added = true
        end
    end
    return existing, added
end

-- Застосовує результат Gemini для "Додати до персонажа": для текстових
-- полів (рід занять/зовнішність/характер/бекграунд) Gemini бачить старий
-- текст ЦІЛКОМ і повертає вже готове, повністю переформульоване значення
-- поля — тому тут просто ВСТАНОВЛЮЄМО його, а не дописуємо. Так вона сама
-- прибирає повтори ЗМІСТОМ ("лисий" / "без волосся" / "з лисою головою" —
-- одне й те саме), а не лише дослівні збіги, які раніше ловив підрядковий
-- пошук. Списки (псевдоніми/звʼязки) і найхарактерніша риса — без змін.
local function mergeUpdateIntoCard(card, update)
    local changed = {}

    local function setTextField(field, label)
        local new_value = trim(update[field] or "")
        if new_value == "" then return end
        if ukLower(new_value) == ukLower(card[field] or "") then return end
        card[field] = new_value
        table.insert(changed, label)
    end

    setTextField("occupation", "рід занять")
    setTextField("physical_description", "зовнішність")
    setTextField("personality", "характер")
    setTextField("background", "бекграунд")

    local new_aliases, aliases_changed = mergeArrayField(card.aliases, update.aliases)
    card.aliases = new_aliases
    if aliases_changed then table.insert(changed, "інші імена") end

    local new_rel, rel_changed = mergeArrayField(card.relationships, update.relationships)
    card.relationships = new_rel
    if rel_changed then table.insert(changed, "звʼязки") end

    -- standout_trait — це "НАЙхарактерніша" риса, одна, а не список, тому
    -- перезаписуємо, коли Gemini впевнено пропонує нову — вважаємо, що
    -- пізніший аналіз має більше контексту й обирає влучніше.
    if type(update.standout_trait) == "string" and trim(update.standout_trait) ~= "" then
        local new_trait = trim(update.standout_trait)
        if ukLower(new_trait) ~= ukLower(card.standout_trait or "") then
            card.standout_trait = new_trait
            table.insert(changed, "характерна риса")
        end
    end

    return changed
end

-- Об'єднує дві вже ПОВНІ картки того самого персонажа з різних книг серії
-- (привʼязка до серії, дивись CharCards:_linkToSeries) — тут нема проходу
-- AI, який міг би переписати текст, тож для текстових полів лишається
-- стара, консервативніша логіка "дописати, якщо це справді нове".
local function combineCardsForSeries(existing, incoming)
    local changed = {}

    local new_occ, occ_changed = mergeTextField(existing.occupation, incoming.occupation)
    existing.occupation = new_occ
    if occ_changed then table.insert(changed, "рід занять") end

    local new_phys, phys_changed = mergeTextField(existing.physical_description, incoming.physical_description)
    existing.physical_description = new_phys
    if phys_changed then table.insert(changed, "зовнішність") end

    local new_pers, pers_changed = mergeTextField(existing.personality, incoming.personality)
    existing.personality = new_pers
    if pers_changed then table.insert(changed, "характер") end

    local new_bg, bg_changed = mergeTextField(existing.background, incoming.background)
    existing.background = new_bg
    if bg_changed then table.insert(changed, "бекграунд") end

    local new_aliases, aliases_changed = mergeArrayField(existing.aliases, incoming.aliases)
    existing.aliases = new_aliases
    if aliases_changed then table.insert(changed, "інші імена") end

    local new_rel, rel_changed = mergeArrayField(existing.relationships, incoming.relationships)
    existing.relationships = new_rel
    if rel_changed then table.insert(changed, "звʼязки") end

    if type(incoming.standout_trait) == "string" and trim(incoming.standout_trait) ~= "" then
        local new_trait = trim(incoming.standout_trait)
        if ukLower(new_trait) ~= ukLower(existing.standout_trait or "") then
            existing.standout_trait = new_trait
            table.insert(changed, "характерна риса")
        end
    end

    return changed
end

-- Компактна картка для попапу при тапу на підкреслене ім'я в тексті:
-- короткий витяг з роду занять, звʼязків, найхарактерніша риса й
-- бекграунд. Навмисно коротша за formatCardText — це швидкий погляд,
-- не повний профіль (звʼязки обрізаються до перших двох, довгі поля —
-- до ~150 символів).
-- Стискає текст до max_len символів (по кодовим точкам UTF-8, не байтах,
-- щоб не розрізати кириличний символ навпіл) з "…" в кінці за потреби.
local function truncateForCompact(text, max_len)
    if not text or text == "" then return text end
    local chars, count = {}, 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > max_len then
            return table.concat(chars) .. "…"
        end
        table.insert(chars, ch)
    end
    return text
end

local function formatCompactCardText(card)
    local lines = {}
    if card.occupation and card.occupation ~= "" then
        table.insert(lines, truncateForCompact(card.occupation, 100))
    end
    if card.relationships and #card.relationships > 0 then
        local preview = {}
        for i = 1, math.min(2, #card.relationships) do
            table.insert(preview, card.relationships[i])
        end
        local rel_line = table.concat(preview, "; ")
        if #card.relationships > 2 then rel_line = rel_line .. "…" end
        table.insert(lines, rel_line)
    end
    if card.standout_trait and card.standout_trait ~= "" then
        table.insert(lines, card.standout_trait)
    end
    if card.background and card.background ~= "" then
        if #lines > 0 then table.insert(lines, "") end
        table.insert(lines, truncateForCompact(card.background, 150))
    end
    if #lines == 0 then
        table.insert(lines, "Даних поки нема.")
    end
    return table.concat(lines, "\n")
end

-- Текстове представлення картки для перегляду (TextViewer).
local function formatCardText(card)
    local lines = {}
    if card.aliases and #card.aliases > 0 then
        table.insert(lines, "Інші імена: " .. table.concat(card.aliases, ", "))
    end
    if card.occupation and card.occupation ~= "" then
        table.insert(lines, "Рід занять: " .. card.occupation)
    end
    if card.aliases and #card.aliases > 0 or (card.occupation and card.occupation ~= "") then
        table.insert(lines, "")
    end
    if card.physical_description and card.physical_description ~= "" then
        table.insert(lines, "Зовнішність:")
        table.insert(lines, card.physical_description)
        table.insert(lines, "")
    end
    if card.personality and card.personality ~= "" then
        table.insert(lines, "Характер:")
        table.insert(lines, card.personality)
        table.insert(lines, "")
    end
    if card.relationships and #card.relationships > 0 then
        table.insert(lines, "Звʼязки:")
        for _, r in ipairs(card.relationships) do
            table.insert(lines, "• " .. r)
        end
        table.insert(lines, "")
    end
    if card.standout_trait and card.standout_trait ~= "" then
        table.insert(lines, "Найхарактерніше: " .. card.standout_trait)
        table.insert(lines, "")
    end
    if card.background and card.background ~= "" then
        table.insert(lines, "Бекграунд:")
        table.insert(lines, card.background)
    end
    if #lines == 0 then
        table.insert(lines, "Даних поки нема.")
    end
    return table.concat(lines, "\n")
end

-- ===== Підкреслення імен у тексті + попап з компактною карткою =====
--
-- За замовчуванням ВИМКНЕНО (SETTING_UNDERLINE_ON має бути точно `true`) —
-- відкриття книги саме по собі нічого не сканує й нічого не малює, доки
-- користувач сам не увімкне через меню. Урок з попереднього проєкту: авто-
-- сканування при кожному відкритті книги на повільному e-ink відчувається
-- як зависання.

local MIN_TERM_LEN  = 3
local MAX_REGEX_LEN = 600

local function escapeRegex(s)
    local esc = s:gsub("([%^%$%.%*%+%?%(%)%[%]%{%}|\\])", "\\%1")
    esc = esc:gsub("%s+", "\\s+")
    return esc
end

-- Терміни для пошуку: імена + псевдоніми всіх карток книги. lookup —
-- точний (регістрозалежний) рядок -> картка, БЕЗ lower() з обох боків,
-- бо пошук у тексті теж регістрозалежний (case_insensitive=false нижче).
local function collectUnderlineTerms(self)
    local cards = loadCards(self)
    local lookup, terms = {}, {}
    for _, c in ipairs(cards) do
        local names = { c.name }
        if c.aliases then
            for _, a in ipairs(c.aliases) do table.insert(names, a) end
        end
        for _, n in ipairs(names) do
            local clean = trim(n)
            if #clean >= MIN_TERM_LEN and not lookup[clean] then
                lookup[clean] = c
                table.insert(terms, clean)
            end
        end
    end
    return terms, lookup
end

-- Межа слова \b у регекс-рушії crengine прив'язана до ASCII %w і не бачить
-- кирилицю — кожне українське ім'я автоматично потрапляє в гілку без меж
-- (пошук підрядком). Це свідомий компроміс, той самий, що й у попередньому
-- проєкті: без нього кирилична \b-межа просто ніколи не спрацьовує.
local function buildUnderlineChunks(terms)
    table.sort(terms, function(a, b) return #a > #b end)
    local with_boundary, without_boundary = {}, {}
    for _, t in ipairs(terms) do
        local esc = escapeRegex(t)
        if t:match("^[%w]") and t:match("[%w]$") then
            table.insert(with_boundary, esc)
        else
            table.insert(without_boundary, esc)
        end
    end
    local function chunkList(list, wrap)
        local chunks, current, current_len = {}, {}, 0
        for _, esc in ipairs(list) do
            if current_len + #esc + 1 > MAX_REGEX_LEN and #current > 0 then
                table.insert(chunks, current)
                current, current_len = {}, 0
            end
            table.insert(current, esc)
            current_len = current_len + #esc + 1
        end
        if #current > 0 then table.insert(chunks, current) end
        local patterns = {}
        for _, c in ipairs(chunks) do
            local body = table.concat(c, "|")
            table.insert(patterns, wrap and ("\\b(" .. body .. ")\\b") or ("(" .. body .. ")"))
        end
        return patterns
    end
    local patterns = {}
    for _, p in ipairs(chunkList(with_boundary, true)) do table.insert(patterns, p) end
    for _, p in ipairs(chunkList(without_boundary, false)) do table.insert(patterns, p) end
    return patterns
end

local function getCurrentPageSafe(self)
    local ok, pg = pcall(function() return self.ui.view.state.page end)
    if ok and pg then return pg end
    return 1
end

local function buildMatchesByPage(self, doc, matches)
    if not self.ui.rolling or not doc or not doc.getPageFromXPointer then return nil end
    local by_page = {}
    for _, m in ipairs(matches) do
        local ok, page = pcall(doc.getPageFromXPointer, doc, m.start_xp)
        if ok and page then
            by_page[page] = by_page[page] or {}
            table.insert(by_page[page], m)
        end
    end
    return by_page
end

local function cacheSig(self)
    local doc = self.ui and self.ui.document
    if not doc then return "" end
    local page = getCurrentPageSafe(self)
    local pos = ""
    if doc.getCurrentPos then pcall(function() pos = doc:getCurrentPos() end) end
    local hash = ""
    if doc.getDocumentRenderingHash then pcall(function() hash = doc:getDocumentRenderingHash() end) end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    return table.concat({ tostring(page), tostring(pos), tostring(hash), tostring(sw), tostring(sh) }, "|")
end

-- ===== Компактний попап (той самий перевірений шаблон: OverlapGroup,
-- onTapOutside, dismiss/onShow з таймером — без кастомних paintTo/getSize,
-- які й спричиняли зависання рідера в попередній версії). =====

local CompactCardPopup = InputContainer:extend{
    box = nil,
    title_text = "",
    description_text = "",
    timeout = 8,
    timer_handle = nil,
    _closed = false,
}

function CompactCardPopup:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local sc = function(n) return Screen:scaleBySize(n) end

    local fs = tonumber(G_reader_settings and G_reader_settings:readSetting("cre_font_size")) or 22
    local face = Font:getFace("cfont", fs)

    local pad_h = 24
    local pad_v = math.floor(fs * 0.55)
    local card_w = math.floor(math.min(sw, sh) * 0.82)
    local text_w = card_w - pad_h * 2

    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, TextBoxWidget:new{ text = self.title_text, face = face, width = text_w, bold = true })
    table.insert(vg, VerticalSpan:new{ width = math.max(6, math.floor(fs * 0.35)) })
    table.insert(vg, TextBoxWidget:new{ text = self.description_text, face = face, width = text_w })

    local card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = sc(2),
        color = Blitbuffer.COLOR_DARK_GRAY,
        radius = 0,
        padding_top = pad_v, padding_bottom = pad_v,
        padding_left = pad_h, padding_right = pad_h,
        width = card_w,
        vg,
    }
    local card_size = card:getSize()
    card_w = card_size.w
    local card_h = math.min(card_size.h, sh - sc(40))

    local margin = sc(10)
    local box = self.box
    local ref_x = box.x + box.w / 2
    local ref_bottom = box.y + box.h
    local ref_top = box.y

    local popup_x = math.max(0, math.min(sw - card_w, math.floor(ref_x - card_w / 2)))
    local popup_y
    if ref_bottom + margin + card_h <= sh then
        popup_y = ref_bottom + margin
    else
        popup_y = math.max(0, ref_top - margin - card_h)
    end
    card.overlap_offset = { popup_x, popup_y }

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } }
    }
    self[1] = OverlapGroup:new{ dimen = Geom:new{ w = sw, h = sh }, card }
end

function CompactCardPopup:onTapOutside() self:dismiss(); return true end
function CompactCardPopup:onClose() self:dismiss(); return true end

function CompactCardPopup:dismiss()
    if self.timer_handle then
        pcall(function() self.timer_handle:cancel() end)
        self.timer_handle = nil
    end
    if not self._closed then
        self._closed = true
        UIManager:close(self)
    end
end

function CompactCardPopup:onShow()
    if self.timeout and self.timeout > 0 then
        local this = self
        self.timer_handle = UIManager:scheduleIn(self.timeout, function()
            if not this._closed then this:dismiss() end
        end)
    end
    UIManager:setDirty(self, "ui")
    return true
end

-- ===== Плагін =====

local CharCards = WidgetContainer:extend{
    name = "charcards",
    is_doc_only = true,
}

function CharCards:init()
    self.ui.menu:registerToMainMenu(self)

    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        local self_ref = self

        self.ui.highlight:addToHighlightDialog("charcards_add_new", function(highlight_instance)
            return {
                text = "Додати персонажа",
                callback = function()
                    local selected = highlight_instance.selected_text
                    local name = selected and (selected.text or selected.word or "") or ""
                    name = trim(name)
                    if highlight_instance.highlight_dialog then
                        UIManager:close(highlight_instance.highlight_dialog)
                    end
                    if name ~= "" then self_ref:onAddNewCharacter(name) end
                end,
            }
        end)

        self.ui.highlight:addToHighlightDialog("charcards_add_fact", function(highlight_instance)
            return {
                text = "Додати до персонажа",
                callback = function()
                    local selected = highlight_instance.selected_text
                    local quote = selected and (selected.text or selected.word or "") or ""
                    quote = trim(quote)
                    if highlight_instance.highlight_dialog then
                        UIManager:close(highlight_instance.highlight_dialog)
                    end
                    if quote ~= "" then self_ref:onAddFactToCharacter(quote) end
                end,
            }
        end)
    end

    -- Малювання підкреслень і обробку тапу монтуємо завжди (дешево, нічого
    -- не робить, поки нема даних чи вимкнено) — саме СКАНУВАННЯ книги не
    -- запускається тут: воно тільки за явною командою з меню.
    self:mountUnderlineOverlay()
    self:mountTapHandler()

    log("плагін ініціалізовано")
end

-- ===== Підкреслення: сканування, кеш, малювання, тап =====

function CharCards:clearUnderlines()
    self._cc_boxes = nil
    self._cc_xp_matches = nil
    self._cc_by_page = nil
    if self.ui and self.ui.view and self.ui.view.dialog then
        UIManager:setDirty(self.ui.view.dialog, "ui")
    end
end

function CharCards:mountUnderlineOverlay()
    if self._cc_paint_wrapped then return end
    local view = self.ui and self.ui.view
    if not view then return end
    local plugin = self
    local orig = view.paintTo
    view.paintTo = function(view_self, bb, x, y)
        orig(view_self, bb, x, y)
        local ok, err = pcall(function() plugin:_drawUnderlines(bb) end)
        if not ok then log("помилка малювання: " .. tostring(err)) end
    end
    self._cc_paint_wrapped = true
end

function CharCards:mountTapHandler()
    if self._cc_tap_wrapped then return end
    local hl = self.ui and self.ui.highlight
    if not hl then return end
    local plugin = self
    local orig_tap = hl.onTap
    hl.onTap = function(hl_self, _, ges)
        if ges and plugin:_handleTap(ges) then return true end
        if orig_tap then return orig_tap(hl_self, _, ges) end
    end
    self._cc_tap_wrapped = true
end

function CharCards:_handleTap(ges)
    if G_reader_settings:readSetting(SETTING_UNDERLINE_ON) ~= true then return false end
    if not self._cc_boxes or #self._cc_boxes == 0 then return false end
    local tx, ty = ges.pos.x, ges.pos.y
    for _, box in ipairs(self._cc_boxes) do
        if tx >= box.x and tx <= box.x + box.w
        and ty >= box.y - 8 and ty <= box.y + box.h + 8 then
            self:_showCompactCardFromTap(box)
            return true
        end
    end
    return false
end

function CharCards:_showCompactCardFromTap(box)
    local cards = loadCards(self)
    local card
    for _, c in ipairs(cards) do
        if c.name == box.entity_name then card = c; break end
    end
    if not card then return end

    UIManager:show(CompactCardPopup:new{
        box = box,
        title_text = card.name,
        description_text = formatCompactCardText(card),
        timeout = 8,
    })
end

local function resolveBoxesImpl(self)
    local sig = cacheSig(self)
    if self._cc_box_sig == sig and self._cc_boxes then return end
    self._cc_box_sig = sig

    local doc = self.ui and self.ui.document
    if not doc or not self._cc_xp_matches or #self._cc_xp_matches == 0 then
        self._cc_boxes = {}
        return
    end

    local to_resolve = self._cc_xp_matches
    if self._cc_by_page then
        local page = getCurrentPageSafe(self)
        to_resolve = {}
        for _, pg in ipairs({ page - 1, page, page + 1 }) do
            local bucket = self._cc_by_page[pg]
            if bucket then for _, m in ipairs(bucket) do table.insert(to_resolve, m) end end
        end
    end

    local groups = {}
    for _, match in ipairs(to_resolve) do
        local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, match.start_xp, match.end_xp, true)
        if ok and boxes and #boxes > 0 then
            local group_boxes = {}
            local top_y, top_x
            for _, box in ipairs(boxes) do
                table.insert(group_boxes, { x = box.x, y = box.y, w = box.w, h = box.h, entity_name = match.entity_name })
                if not top_y or box.y < top_y or (box.y == top_y and box.x < top_x) then
                    top_y, top_x = box.y, box.x
                end
            end
            table.insert(groups, { key = match.entity_name or "", sort_y = top_y, sort_x = top_x, boxes = group_boxes })
        end
    end

    table.sort(groups, function(a, b)
        if a.sort_y ~= b.sort_y then return a.sort_y < b.sort_y end
        return a.sort_x < b.sort_x
    end)

    local seen, resolved = {}, {}
    for _, g in ipairs(groups) do
        if not seen[g.key] then
            seen[g.key] = true
            for _, box in ipairs(g.boxes) do table.insert(resolved, box) end
        end
    end
    self._cc_boxes = resolved
end

function CharCards:_resolveBoxes()
    resolveBoxesImpl(self)
end

function CharCards:_drawUnderlines(bb)
    if G_reader_settings:readSetting(SETTING_UNDERLINE_ON) ~= true then return end

    if not self._cc_xp_matches then
        if not self._cc_cache_checked then
            self._cc_cache_checked = true
            local cards = loadCards(self)
            local sig = cardsSignature(cards)
            self:_loadUnderlineCache(sig)
        end
        return  -- сканування — тільки вручну з меню, не звідси
    end

    self:_resolveBoxes()
    if not self._cc_boxes or #self._cc_boxes == 0 then return end

    local thick = Screen:scaleBySize(2)
    local color = Blitbuffer.Color8(0x50)
    for _, box in ipairs(self._cc_boxes) do
        if box.x and box.y and box.w and box.h then
            bb:paintRect(box.x, box.y + box.h - thick, box.w, thick, color)
        end
    end
end

function CharCards:_loadUnderlineCache(sig)
    local cache = self.ui.doc_settings and self.ui.doc_settings:readSetting("charcards_underline_cache")
    if type(cache) ~= "table" or cache.sig ~= sig or type(cache.matches) ~= "table" then
        return false
    end
    self._cc_xp_matches = cache.matches
    self._cc_by_page = buildMatchesByPage(self, self.ui and self.ui.document, cache.matches)
    self._cc_box_sig = nil
    if self.ui.view then
        if self.ui.view.dialog then UIManager:setDirty(self.ui.view.dialog, "ui") end
        UIManager:setDirty(nil, "ui")
    end
    return true
end

function CharCards:_saveUnderlineCache(sig)
    if not self.ui.doc_settings then return end
    self.ui.doc_settings:saveSetting("charcards_underline_cache", { sig = sig, matches = self._cc_xp_matches or {} })
    self.ui.doc_settings:flush()
end

function CharCards:scanForCharacters(force, silent)
    if G_reader_settings:readSetting(SETTING_UNDERLINE_ON) ~= true then
        self:clearUnderlines()
        return
    end
    if not self.ui or not self.ui.document then return end
    if self._cc_scan_in_progress then return end

    local doc = self.ui.document
    if not doc.findAllText then
        log("findAllText не підтримується для цього типу документа")
        self._cc_xp_matches = {}
        self._cc_boxes = {}
        return
    end

    local terms, lookup = collectUnderlineTerms(self)
    local sig = cardsSignature(loadCards(self))

    if not force and self:_loadUnderlineCache(sig) then return end

    if #terms == 0 then
        self._cc_xp_matches = {}
        self._cc_boxes = {}
        self._cc_by_page = nil
        self._cc_box_sig = nil
        if self.ui.view and self.ui.view.dialog then UIManager:setDirty(self.ui.view.dialog, "ui") end
        return
    end

    self._cc_scan_in_progress = true
    local patterns = buildUnderlineChunks(terms)
    local hits = {}
    local idx = 0
    local plugin = self

    local function finishScan()
        local ok_f, err_f = pcall(function()
            local unique = {}
            for _, h in ipairs(hits) do
                local e = h["end"]
                if not unique[e] or #h.matched_text > #unique[e].matched_text then unique[e] = h end
            end
            local xp_matches = {}
            for _, h in pairs(unique) do
                local matched = trim(h.matched_text or "")
                local entity = lookup[matched]
                if entity then
                    table.insert(xp_matches, { start_xp = h.start, end_xp = h["end"], entity_name = entity.name })
                end
            end
            plugin._cc_xp_matches = xp_matches
            plugin._cc_by_page = buildMatchesByPage(plugin, doc, xp_matches)
            plugin._cc_box_sig = nil
            log("scanForCharacters: " .. #xp_matches .. " згадувань")
            if not silent then
                UIManager:show(InfoMessage:new{ text = #xp_matches .. " згадувань персонажів знайдено", timeout = 3 })
            end
            if plugin.ui.view then
                if plugin.ui.view.dialog then UIManager:setDirty(plugin.ui.view.dialog, "ui") end
                UIManager:setDirty(nil, "ui")
            end
            UIManager:scheduleIn(0.5, function()
                if not plugin.destroyed then plugin:_saveUnderlineCache(sig) end
            end)
        end)
        plugin._cc_scan_in_progress = false
        if not ok_f then log("finishScan помилка: " .. tostring(err_f)) end
    end

    local function step()
        if plugin.destroyed or not plugin.ui or not plugin.ui.document then
            plugin._cc_scan_in_progress = false
            return
        end
        idx = idx + 1
        local pat = patterns[idx]
        if not pat then finishScan(); return end
        local ok1, hits1 = pcall(function() return doc:findAllText(pat, false, 0, 5000, true) end)
        if ok1 and hits1 then
            for _, h in ipairs(hits1) do table.insert(hits, h) end
        else
            log("findAllText не вдався, чанк=" .. idx .. "/" .. #patterns)
        end
        -- Невелика (не нульова) пауза між шматками — не просто повертає
        -- керування в той самий такт подій, а справді дає KOReader шанс
        -- обробити гортання сторінки чи тап, перш ніж брати наступний
        -- шматок регексу. Разом з меншим MAX_REGEX_LEN вище (600 замість
        -- 3000 — тобто вп'ятеро більше, вп'ятеро коротших шматків) кожен
        -- окремий "гальм" стає значно менш помітним під час читання.
        UIManager:scheduleIn(0.02, step)
    end

    if not silent then
        UIManager:show(InfoMessage:new{ text = "Сканую книгу на персонажів…", timeout = 2 })
    end
    UIManager:scheduleIn(0.02, step)
end

function CharCards:_scheduleRescan(new_terms)
    if G_reader_settings:readSetting(SETTING_UNDERLINE_ON) ~= true then return end

    -- Накопичуємо нові терміни, якщо кілька збережень трапляються швидко
    -- одне за одним (кілька правок поспіль) — усі знайдуться одним заходом.
    if new_terms and #new_terms > 0 then
        self._cc_pending_new_terms = self._cc_pending_new_terms or {}
        for _, t in ipairs(new_terms) do table.insert(self._cc_pending_new_terms, t) end
    end

    if self._cc_rescan_fn then UIManager:unschedule(self._cc_rescan_fn) end
    local plugin = self
    self._cc_rescan_fn = function()
        if plugin.destroyed then return end
        local pending = plugin._cc_pending_new_terms
        plugin._cc_pending_new_terms = nil
        -- silent=true / інкрементальний скан: це фонове автоперескання
        -- після збереження (додав/оновив персонажа), не ручний запуск з
        -- меню — тож без "Сканую.../N знайдено" повідомлень, і, коли
        -- можливо, шукаємо ЛИШЕ нові імена (позиції вже відомих персонажів
        -- і так є в кеші, наново їх шукати по всій книзі нема сенсу).
        if pending and #pending > 0 and plugin._cc_xp_matches then
            plugin:_incrementalScan(pending)
        else
            plugin:scanForCharacters(true, true)
        end
    end
    UIManager:scheduleIn(1.5, self._cc_rescan_fn)
end

-- Сканує книгу лише на задані терміни (нові імена/псевдоніми) й ДОДАЄ
-- знайдене до вже наявного кешу позицій, замість перебудовувати все з нуля.
-- Використовує ту саму чанковану findAllText-логіку, що й повний скан.
function CharCards:_incrementalScan(new_terms)
    if self._cc_scan_in_progress then return end  -- щось інше вже сканує — не заважаємо
    local doc = self.ui and self.ui.document
    if not doc or not doc.findAllText then return end

    local lookup = {}
    for _, c in ipairs(loadCards(self)) do
        if c.name then lookup[trim(c.name)] = c end
        if c.aliases then for _, a in ipairs(c.aliases) do lookup[trim(a)] = c end end
    end

    local patterns = buildUnderlineChunks(new_terms)
    local hits = {}
    local idx = 0
    local plugin = self

    local function finishIncremental()
        local ok_f, err_f = pcall(function()
            local unique = {}
            for _, h in ipairs(hits) do
                local e = h["end"]
                if not unique[e] or #h.matched_text > #unique[e].matched_text then unique[e] = h end
            end
            local added = 0
            plugin._cc_xp_matches = plugin._cc_xp_matches or {}
            for _, h in pairs(unique) do
                local matched = trim(h.matched_text or "")
                local entity = lookup[matched]
                if entity then
                    table.insert(plugin._cc_xp_matches, { start_xp = h.start, end_xp = h["end"], entity_name = entity.name })
                    added = added + 1
                end
            end
            plugin._cc_by_page = buildMatchesByPage(plugin, doc, plugin._cc_xp_matches)
            plugin._cc_box_sig = nil
            log("incrementalScan: +" .. added .. " нових згадувань")
            if plugin.ui.view then
                if plugin.ui.view.dialog then UIManager:setDirty(plugin.ui.view.dialog, "ui") end
                UIManager:setDirty(nil, "ui")
            end
            local sig = cardsSignature(loadCards(plugin))
            UIManager:scheduleIn(0.5, function()
                if not plugin.destroyed then plugin:_saveUnderlineCache(sig) end
            end)
        end)
        plugin._cc_scan_in_progress = false
        if not ok_f then log("incrementalScan помilka: " .. tostring(err_f)) end
    end

    local function step()
        if plugin.destroyed or not plugin.ui or not plugin.ui.document then
            plugin._cc_scan_in_progress = false
            return
        end
        idx = idx + 1
        local pat = patterns[idx]
        if not pat then finishIncremental(); return end
        local ok1, hits1 = pcall(function() return doc:findAllText(pat, false, 0, 5000, true) end)
        if ok1 and hits1 then
            for _, h in ipairs(hits1) do table.insert(hits, h) end
        else
            log("findAllText (інкремент) не вдався, чанк=" .. idx .. "/" .. #patterns)
        end
        UIManager:scheduleIn(0.02, step)
    end

    self._cc_scan_in_progress = true
    UIManager:scheduleIn(0.02, step)
end

function CharCards:addToMainMenu(menu_items)
    local self_ref = self
    menu_items.charcards = {
        text          = "Картки персонажів",
        sorting_hint  = "tools",
        sub_item_table = {
            {
                text     = "Список персонажів",
                callback = function() self_ref:showCardList() end,
            },
            {
                text_func = function()
                    local k = getApiKeySetting()
                    return "Ключ Gemini API" .. ((k and k ~= "") and " (задано)" or " (не задано)")
                end,
                keep_menu_open = true,
                callback = function() self_ref:showApiKeyDialog() end,
            },
            {
                text_func = function()
                    local series_id = getSeriesId(self_ref)
                    if not series_id then return "Серія книг (не прив'язано)" end
                    local name = getSeriesFile(series_id):readSetting("name") or series_id
                    return "Серія книг: " .. name
                end,
                keep_menu_open = true,
                callback = function() self_ref:showSeriesMenu() end,
            },
            {
                text = "Підкреслення персонажів у тексті",
                keep_menu_open = true,
                sub_item_table = {
                    {
                        text = "Увімкнути підкреслення",
                        checked_func = function()
                            return G_reader_settings:readSetting(SETTING_UNDERLINE_ON) == true
                        end,
                        callback = function()
                            local cur = G_reader_settings:readSetting(SETTING_UNDERLINE_ON) == true
                            G_reader_settings:saveSetting(SETTING_UNDERLINE_ON, not cur)
                            if cur then
                                self_ref:clearUnderlines()
                            else
                                self_ref:scanForCharacters(true)
                            end
                        end,
                    },
                    {
                        text = "Пересканувати зараз",
                        keep_menu_open = true,
                        callback = function() self_ref:scanForCharacters(true) end,
                    },
                },
            },
        },
    }
end

-- ===== API-ключ =====

function CharCards:getApiKey(on_have_key)
    local key = getApiKeySetting()
    if key and key ~= "" then on_have_key(key); return end

    local self_ref = self
    local dialog
    dialog = InputDialog:new{
        title      = "Ключ Gemini API",
        input      = "",
        input_hint = "Встав ключ (aistudio.google.com)",
        buttons    = {{
            { text = "Скасувати", callback = function() UIManager:close(dialog) end },
            {
                text             = "Зберегти",
                is_enter_default = true,
                callback         = function()
                    local k = trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    if k == "" then return end
                    saveApiKeySetting(k)
                    on_have_key(k)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharCards:showApiKeyDialog()
    local current = getApiKeySetting() or ""
    local dialog
    dialog = InputDialog:new{
        title      = "Ключ Gemini API",
        input      = current,
        input_hint = "Встав ключ (aistudio.google.com)",
        buttons    = {{
            { text = "Скасувати", callback = function() UIManager:close(dialog) end },
            {
                text     = "Очистити",
                callback = function()
                    UIManager:close(dialog)
                    saveApiKeySetting("")
                    UIManager:show(InfoMessage:new{ text = "Ключ видалено.", timeout = 2 })
                end,
            },
            {
                text             = "Зберегти",
                is_enter_default = true,
                callback         = function()
                    local k = trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    saveApiKeySetting(k)
                    UIManager:show(InfoMessage:new{
                        text = k ~= "" and "Ключ збережено." or "Ключ видалено.",
                        timeout = 2,
                    })
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ===== Серія книг =====

function CharCards:showSeriesMenu()
    local self_ref = self
    local series_id = getSeriesId(self)
    local items = {}

    if series_id then
        local s = getSeriesFile(series_id)
        local name = s:readSetting("name") or series_id
        local n_cards = #loadCards(self)
        table.insert(items, {
            text = "Ця книга прив'язана до серії «" .. name .. "» (" .. n_cards .. " персонаж(ів))",
            callback = function() end,
        })
        table.insert(items, {
            text = "Відв'язати від серії",
            keep_menu_open = false,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "Відв'язати цю книгу від серії «" .. name .. "»?\n\n" ..
                           "Персонажі серії нікуди не зникнуть — вони й далі доступні " ..
                           "з будь-якої іншої книги, привʼязаної до цієї серії. Ця книга " ..
                           "просто повернеться до власного, окремого списку персонажів " ..
                           "(того, що був до привʼязки).",
                    ok_text = "Відв'язати",
                    ok_callback = function()
                        setSeriesId(self_ref, nil)
                        self_ref:clearUnderlines()
                        UIManager:show(InfoMessage:new{ text = "Відв'язано від серії.", timeout = 2 })
                    end,
                })
            end,
        })
    else
        table.insert(items, {
            text = "Прив'язати до існуючої серії",
            callback = function() self_ref:showLinkToSeriesPicker() end,
        })
        table.insert(items, {
            text = "Створити нову серію й привʼязати цю книгу",
            callback = function() self_ref:showCreateSeriesDialog() end,
        })
    end

    UIManager:show(Menu:new{
        title       = "Серія книг",
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    })
end

function CharCards:showLinkToSeriesPicker()
    local self_ref = self
    local series_list = listSeries()
    if #series_list == 0 then
        UIManager:show(InfoMessage:new{
            text = "Ще немає жодної серії. Спершу створи нову — «Серія книг → Створити нову серію».",
            timeout = 4,
        })
        return
    end
    local items = {}
    for _, s in ipairs(series_list) do
        table.insert(items, {
            text     = s.name,
            callback = function() self_ref:_linkToSeries(s.id, s.name) end,
        })
    end
    UIManager:show(Menu:new{
        title       = "Обери серію",
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    })
end

function CharCards:showCreateSeriesDialog()
    local self_ref = self
    local dialog
    dialog = InputDialog:new{
        title      = "Назва серії",
        input      = "",
        input_hint = "напр. Талісман",
        buttons    = {{
            { text = "Скасувати", callback = function() UIManager:close(dialog) end },
            {
                text             = "Створити",
                is_enter_default = true,
                callback         = function()
                    local name = trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    if name == "" then return end
                    -- унікальний id (назва + час створення) — дві серії з однаковою
                    -- назвою не зіллються випадково в один файл
                    local id = sanitizeSeriesId(name) .. "_" .. tostring(os.time())
                    local s = getSeriesFile(id)
                    s:saveSetting("name", name)
                    s:flush()
                    self_ref:_linkToSeries(id, name)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Привʼязує поточну книгу до серії. Якщо в книги вже були власні картки
-- (набрані до привʼязки) — переносить їх у спільний пул серії, обʼєднуючи
-- з уже наявними там персонажами тим самим принципом, що й "Додати до
-- персонажа" (нічого не втрачається, максимум зрідка здублюється фраза).
function CharCards:_linkToSeries(series_id, series_name)
    local self_ref = self
    local local_cards = self.ui.doc_settings and self.ui.doc_settings:readSetting("charcards")
    if type(local_cards) ~= "table" then local_cards = {} end

    setSeriesId(self, series_id)

    if #local_cards > 0 then
        local series_cards = loadCards(self)
        local added, merged = 0, 0
        for _, lc in ipairs(local_cards) do
            local existing = findCardByName(series_cards, lc.name)
            if existing then
                combineCardsForSeries(existing, lc)
                merged = merged + 1
            else
                table.insert(series_cards, lc)
                added = added + 1
            end
        end
        saveCards(self, series_cards)
        UIManager:show(InfoMessage:new{
            text = "Привʼязано до серії «" .. series_name .. "». Додано " .. added ..
                   " нових персонажів, обʼєднано з наявними: " .. merged .. ".",
            timeout = 4,
        })
    else
        UIManager:show(InfoMessage:new{
            text = "Привʼязано до серії «" .. series_name .. "».",
            timeout = 3,
        })
    end

    self_ref:clearUnderlines()
    if G_reader_settings:readSetting(SETTING_UNDERLINE_ON) == true then
        -- silent: тут уже є своє інформативне повідомлення про підсумки
        -- привʼязки вище, зайвий "Сканую.../N знайдено" був би надлишковим
        self_ref:scanForCharacters(true, true)
    end
end

-- ===== Дія 1: додати нового персонажа за виділеним ім'ям =====

function CharCards:onAddNewCharacter(name)
    if not self.ui.doc_settings then
        UIManager:show(InfoMessage:new{ text = "Немає відкритої книги." })
        return
    end

    local cards = loadCards(self)
    local existing = findCardByName(cards, name)
    if existing then
        UIManager:show(InfoMessage:new{
            text = "«" .. existing.name .. "» вже є в картках.",
            timeout = 3,
        })
        self:showCardView(existing)
        return
    end

    local self_ref = self
    self:getApiKey(function(api_key)
        ensureNetworkThen(function()
        UIManager:show(InfoMessage:new{ text = "Аналізую контекст для «" .. name .. "»…", timeout = 2 })

        local context, ctx_err = getContextText(self_ref, 2)
        if not context then
            UIManager:show(InfoMessage:new{ text = "Не вдалося зібрати контекст: " .. tostring(ctx_err) })
            return
        end

        local prompt = "Ти аналізуєш уривок художньої книги українською мовою.\n\n" ..
            "Уривок (кілька останніх сторінок, які читач щойно прочитав):\n\"\"\"\n" ..
            context .. "\n\"\"\"\n\n" ..
            "У цьому уривку згадується персонаж на ім'я «" .. name .. "». Склади про нього " ..
            "коротку картку на основі ЛИШЕ цього уривка — нічого не вигадуй, не бери інформацію " ..
            "звідки-інде. Порожні поля лиши порожніми, якщо в уривку про це нічого нема.\n\n" ..
            "Формат відповіді — СУВОРО лише JSON, без пояснень і без ```:\n" ..
            '{\n' ..
            '  "aliases": ["інше ім\'я чи прізвисько, якщо в уривку так до нього звертаються"],\n' ..
            '  "occupation": "рід занять/статус (наприклад: коваль, вітчим Джека, власник компанії) — порожній рядок якщо невідомо",\n' ..
            '  "physical_description": "зовнішність ЛИШЕ якщо явно описана в тексті, інакше порожній рядок",\n' ..
            '  "personality": "стабільні риси характеру, зроблені висновком із того, як він діє/говорить (не переказ подій) — порожній рядок якщо не видно",\n' ..
            '  "relationships": ["ХТО ЦЕЙ ПЕРСОНАЖ для іншої людини — завжди в такому напрямку: \'донька короля\', \'вітчим Джека\', \'ворог Спіді\'. НІКОЛИ не описуй у зворотному напрямку (не \'батько — король\', а \'донька короля\')."],\n' ..
            '  "standout_trait": "ОДНА найпомітніша, найхарактерніша риса — зовнішня чи поведінкова, те, за чим його одразу впізнати — або порожній рядок",\n' ..
            '  "background": "коротка передісторія/походження персонажа, якщо згадано в уривку (звідки він, що з ним було раніше) — інакше порожній рядок"\n' ..
            '}'

        local result, err = callGemini(api_key, prompt)
        if not result then
            UIManager:show(InfoMessage:new{ text = "Gemini: " .. tostring(err) })
            return
        end

        local aliases = {}
        if type(result.aliases) == "table" then
            for _, a in ipairs(result.aliases) do
                a = trim(a)
                if a ~= "" and ukLower(a) ~= ukLower(name) then table.insert(aliases, a) end
            end
        end
        local relationships = {}
        if type(result.relationships) == "table" then
            for _, r in ipairs(result.relationships) do
                r = trim(r)
                if r ~= "" then table.insert(relationships, r) end
            end
        end

        local card = {
            id                       = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
            name                     = name,
            aliases                  = aliases,
            occupation               = type(result.occupation) == "string" and trim(result.occupation) or "",
            physical_description     = type(result.physical_description) == "string" and trim(result.physical_description) or "",
            personality              = type(result.personality) == "string" and trim(result.personality) or "",
            relationships            = relationships,
            background               = type(result.background) == "string" and trim(result.background) or "",
            standout_trait           = type(result.standout_trait) == "string" and trim(result.standout_trait) or "",
        }

        local cards2 = loadCards(self_ref)
        table.insert(cards2, card)
        saveCards(self_ref, cards2)

        UIManager:show(InfoMessage:new{ text = "Додано: " .. card.name, timeout = 2 })
        self_ref:showCardView(card)
        end)
    end)
end

-- ===== Дія 2: додати факт із виділеного уривка до існуючого персонажа =====

function CharCards:onAddFactToCharacter(quote)
    if not self.ui.doc_settings then
        UIManager:show(InfoMessage:new{ text = "Немає відкритої книги." })
        return
    end

    local cards = loadCards(self)
    if #cards == 0 then
        UIManager:show(InfoMessage:new{ text = "Ще нема жодного персонажа — спершу додай когось виділенням імені." })
        return
    end

    local self_ref = self
    local items = {}
    for _, c in ipairs(cards) do
        table.insert(items, {
            text     = c.name,
            callback = function()
                self_ref:_submitFact(c, quote)
            end,
        })
    end

    local picker
    picker = Menu:new{
        title       = "До якого персонажа додати?",
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    }
    UIManager:show(picker)
end

function CharCards:_submitFact(card, quote)
    local self_ref = self
    self:getApiKey(function(api_key)
        ensureNetworkThen(function()
        UIManager:show(InfoMessage:new{ text = "Аналізую уривок…", timeout = 2 })

        local prompt = 'Ось цитата з книги:\n"""\n' .. quote .. '\n"""\n\n' ..
            "Це стосується персонажа «" .. card.name .. "». Ось його поточна картка:\n" ..
            "Рід занять: " .. (card.occupation ~= "" and card.occupation or "невідомо") .. "\n" ..
            "Зовнішність: " .. (card.physical_description ~= "" and card.physical_description or "невідомо") .. "\n" ..
            "Характер: " .. (card.personality ~= "" and card.personality or "невідомо") .. "\n" ..
            "Звʼязки: " .. (#card.relationships > 0 and table.concat(card.relationships, "; ") or "невідомо") .. "\n" ..
            "Найхарактерніша риса: " .. (card.standout_trait ~= "" and card.standout_trait or "невідомо") .. "\n" ..
            "Бекграунд: " .. (card.background ~= "" and card.background or "невідомо") .. "\n\n" ..
            "Онови картку цитатою вище. Для полів \"occupation\", \"physical_description\", " ..
            "\"personality\", \"background\" поверни ПОВНЕ бажане значення поля (не лише новий " ..
            "шматок!) — об'єднай те, що вже записано вище, з тим, що дає цитата, стисло, своїми " ..
            "словами, без дублювання ЗМІСТУ. Якщо цитата підказує те саме, що вже записано, лише " ..
            "іншими словами (наприклад, у полі вже є «лисий», а цитата каже «з лисою головою» чи " ..
            "«без волосся») — це ОДНЕ Й ТЕ САМЕ, познач так лише ОДИН раз, обери влучніше " ..
            "формулювання, не пиши обидва. Якщо для якогось поля цитата взагалі нічого не додає — " ..
            "поверни його ПОТОЧНЕ значення без змін (скопіюй те, що вище), а не порожній рядок — " ..
            "порожній рядок лиши тільки якщо про це поле взагалі нічого не відомо ні зараз, ні з " ..
            "цитати. Кожне поле — максимум 1-2 короткі речення, ніколи не переписуй цитату дослівно.\n\n" ..
            "Формат відповіді — СУВОРО лише JSON, без пояснень і без ```:\n" ..
            '{\n' ..
            '  "occupation": "повне оновлене значення поля (або поточне без змін, або порожньо)",\n' ..
            '  "physical_description": "повне оновлене значення поля (або поточне без змін, або порожньо)",\n' ..
            '  "personality": "повне оновлене значення поля ЯК ВИСНОВОК із того, як персонаж діє/говорить (не переказ подій), або поточне без змін, або порожньо",\n' ..
            '  "aliases": ["нове ім\'я/прізвисько, якщо цитата його розкриває"],\n' ..
            '  "relationships": ["новий стосунок до когось, якщо є в цитаті — завжди у формі \'цей персонаж є [хтось] відносно [когось]\' (напр. \'донька короля\', не \'батько — король\')"],\n' ..
            '  "standout_trait": "ЛИШЕ якщо ця цитата показує щось помітніше/характерніше за те, що вже записано вище — нова найхарактерніша риса, інакше порожній рядок",\n' ..
            '  "background": "повне оновлене значення поля (або поточне без змін, або порожньо)"\n' ..
            '}'

        local result, err = callGemini(api_key, prompt)
        if not result then
            UIManager:show(InfoMessage:new{ text = "Gemini: " .. tostring(err) })
            return
        end

        local cards = loadCards(self_ref)
        local target = findCardByName(cards, card.name)
        if not target then
            UIManager:show(InfoMessage:new{ text = "Персонажа не знайдено в базі (видалили?)." })
            return
        end

        local changed = mergeUpdateIntoCard(target, result)
        if #changed == 0 then
            UIManager:show(InfoMessage:new{ text = "Gemini не знайшов нової інформації в цьому уривку.", timeout = 3 })
            return
        end

        saveCards(self_ref, cards)
        UIManager:show(InfoMessage:new{
            text = "Оновлено «" .. target.name .. "»: " .. table.concat(changed, ", "),
            timeout = 4,
        })
        end)
    end)
end

-- ===== Перегляд / список =====

-- ===== Ручне редагування картки (ім'я + всі поля) =====

function CharCards:onEditCard(card)
    local self_ref = self

    local function save()
        local cards = loadCards(self_ref)
        for _, c in ipairs(cards) do
            if c.id == card.id then
                c.name                  = card.name
                c.aliases               = card.aliases
                c.occupation            = card.occupation
                c.physical_description  = card.physical_description
                c.personality           = card.personality
                c.relationships         = card.relationships
                c.background            = card.background
                c.standout_trait        = card.standout_trait
                break
            end
        end
        saveCards(self_ref, cards)
    end

    local edit_menu
    local function showEditMenu()
        local function editTextField(label, current, multiline, on_save)
            local dialog
            dialog = InputDialog:new{
                title         = label,
                input         = current or "",
                allow_newline = multiline,
                buttons       = {{
                    { text = "Скасувати", callback = function() UIManager:close(dialog) end },
                    {
                        text             = "Зберегти",
                        is_enter_default = not multiline,
                        callback         = function()
                            UIManager:close(dialog)
                            on_save(trim(dialog:getInputText() or ""))
                        end,
                    },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

        local function afterSave()
            UIManager:close(edit_menu)
            showEditMenu()
        end

        local items = {
            {
                text     = "Ім'я: " .. (card.name or ""),
                callback = function()
                    editTextField("Ім'я", card.name, false, function(val)
                        if val ~= "" then card.name = val; save(); afterSave() end
                    end)
                end,
            },
            {
                text     = "Інші імена: " .. table.concat(card.aliases or {}, ", "),
                callback = function()
                    editTextField("Інші імена (через кому)", table.concat(card.aliases or {}, ", "), false, function(val)
                        local t = {}
                        for a in val:gmatch("[^,]+") do
                            local s = trim(a)
                            if s ~= "" then table.insert(t, s) end
                        end
                        card.aliases = t; save(); afterSave()
                    end)
                end,
            },
            {
                text     = "Рід занять: " .. (card.occupation or ""),
                callback = function()
                    editTextField("Рід занять", card.occupation, false, function(val)
                        card.occupation = val; save(); afterSave()
                    end)
                end,
            },
            {
                text     = "Зовнішність",
                callback = function()
                    editTextField("Зовнішність", card.physical_description, true, function(val)
                        card.physical_description = val; save(); afterSave()
                    end)
                end,
            },
            {
                text     = "Характер",
                callback = function()
                    editTextField("Характер", card.personality, true, function(val)
                        card.personality = val; save(); afterSave()
                    end)
                end,
            },
            {
                text     = "Звʼязки (кожен з нового рядка)",
                callback = function()
                    editTextField("Звʼязки (кожен з нового рядка)", table.concat(card.relationships or {}, "\n"), true, function(val)
                        local t = {}
                        for line in val:gmatch("[^\n]+") do
                            local s = trim(line)
                            if s ~= "" then table.insert(t, s) end
                        end
                        card.relationships = t; save(); afterSave()
                    end)
                end,
            },
            {
                text     = "Найхарактерніша риса: " .. (card.standout_trait or ""),
                callback = function()
                    editTextField("Найхарактерніша риса", card.standout_trait, false, function(val)
                        card.standout_trait = val; save(); afterSave()
                    end)
                end,
            },
            {
                text     = "Бекграунд",
                callback = function()
                    editTextField("Бекграунд", card.background, true, function(val)
                        card.background = val; save(); afterSave()
                    end)
                end,
            },
        }

        edit_menu = Menu:new{
            title       = "Редагувати: " .. card.name,
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = self_ref.ui,
        }
        UIManager:show(edit_menu)
    end

    showEditMenu()
end

function CharCards:showCardView(card)
    local self_ref = self
    local viewer
    viewer = TextViewer:new{
        title = card.name,
        text  = formatCardText(card),
        buttons_table = {{
            {
                text = "Видалити персонажа",
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = "Видалити «" .. card.name .. "» і всі його дані?",
                        ok_text = "Видалити",
                        ok_callback = function()
                            UIManager:close(viewer)
                            local cards = loadCards(self_ref)
                            local filtered = {}
                            for _, c in ipairs(cards) do
                                if c.id ~= card.id then table.insert(filtered, c) end
                            end
                            saveCards(self_ref, filtered)
                        end,
                    })
                end,
            },
            {
                text = "Змінити персонажа",
                callback = function()
                    UIManager:close(viewer)
                    self_ref:onEditCard(card)
                end,
            },
        }},
    }
    UIManager:show(viewer)
end

function CharCards:showCardList()
    local cards = loadCards(self)
    if #cards == 0 then
        UIManager:show(InfoMessage:new{
            text = "Ще нема жодного персонажа.\nВиділи ім'я в тексті → «Додати персонажа».",
            timeout = 4,
        })
        return
    end

    local self_ref = self
    local items = {}
    for _, c in ipairs(cards) do
        table.insert(items, {
            text     = c.name,
            callback = function() self_ref:showCardView(c) end,
        })
    end

    UIManager:show(Menu:new{
        title       = #cards .. " персонаж(ів)",
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    })
end

return CharCards
