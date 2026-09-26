--[[
1-charcards-en.lua — KOReader user-патч: англійська локалізація CharCards.

Плагін CharCards (github.com/poostoon/charcards) за замовчуванням українською.
Цей патч перекладає весь інтерфейс і обидва промпти до Gemini на англійську,
не чіпаючи жодного файлу самого плагіна — CharCards тримає всі рядки
інтерфейсу в одній таблиці CharCards.L (це власний плагін, тож рядки не
розкидані по коду напряму, а зведені в одне місце спеціально для такого
патчингу). Цей файл просто переписує значення в тій таблиці після того, як
клас плагіна завантажиться.

Встановлення: покласти файл у koreader/patches/1-charcards-en.lua,
перезапустити KOReader. Щоб повернутись до української — просто видалити
цей файл і перезапустити ще раз.

Якщо в майбутній версії CharCards зʼявиться новий рядок інтерфейсу, якого
нема в таблиці нижче — він просто лишиться українською, доки цей патч не
оновлять новим ключем. Це єдине, що потребує підтримки при оновленні
плагіна.
]]

local ok_userpatch, userpatch = pcall(require, "userpatch")
if not ok_userpatch or not userpatch or not userpatch.registerPatchPluginFunc then
    local ok_l, logger_boot = pcall(require, "logger")
    if ok_l then logger_boot.warn("charcards-en patch: userpatch API unavailable, skipping") end
    return
end

local logger = require("logger")
local function log(msg) logger.info("CharCardsEN: " .. tostring(msg)) end

userpatch.registerPatchPluginFunc("charcards", function(CharCardsClass)
    if CharCardsClass.__en_patched then return end
    CharCardsClass.__en_patched = true

    local L = CharCardsClass.L
    if not L then
        log("CharCards.L not found — plugin version too old for this patch, skipping")
        return
    end

    L.action_add_character = "Add character"
    L.action_add_fact = "Add to character"
    L.added_colon = "Added: "
    L.already_in_cards = "» is already in your cards."
    L.analyzing_context_for = "Analyzing context for «"
    L.analyzing_quote = "Analyzing excerpt…"
    L.api_key_cleared = "Key removed."
    L.api_key_hint = "Paste your key (aistudio.google.com)"
    L.api_key_not_set = "API key is not set."
    L.api_key_saved = "Key saved."
    L.api_key_title = "Gemini API key"
    L.appearance_colon = "Appearance:"
    L.appearance_colon_sp = "Appearance: "
    L.background_colon = "Background:"
    L.background_colon_sp = "Background: "
    L.btn_cancel = "Cancel"
    L.btn_clear = "Clear"
    L.btn_create = "Create"
    L.btn_delete = "Delete"
    L.btn_save = "Save"
    L.btn_unlink = "Unlink"
    L.change_character_btn = "Edit character"
    L.character_not_found_db = "Character not found in the database (deleted?)."
    L.characters_count_only = " character(s)"
    L.characters_count_paren = " character(s))"
    L.could_not_gather_context = "Could not gather context: "
    L.delete_character_btn = "Delete character"
    L.delete_confirm_prefix = "Delete «"
    L.delete_confirm_suffix = "» and all their data?"
    L.diag_file_exists_test = "book file exists (test -f): "
    L.diag_unzip_found = "unzip found: "
    L.doc_type_unsupported = "this document type is not supported (needs an EPUB/FB2-like format)"
    L.edit_aliases_colon = "Other names: "
    L.edit_aliases_hint = "Other names (comma-separated)"
    L.edit_appearance_label = "Appearance"
    L.edit_background_label = "Background"
    L.edit_name_colon = "Name: "
    L.edit_name_label = "Name"
    L.edit_occupation_colon = "Occupation: "
    L.edit_personality_label = "Personality"
    L.edit_relationships_hint = "Relationships (one per line)"
    L.edit_standout_colon = "Standout trait: "
    L.edit_title_prefix = "Edit: "
    L.err_api_http = "API error (HTTP "
    L.err_api_key_file_exec = "api.lua: execution error — "
    L.err_cant_determine_page = "could not determine the page"
    L.err_cant_parse_response = "Could not parse Gemini's response: "
    L.err_chapter_read_failed = "could not read the chapter ("
    L.err_container_not_found = "container.xml: full-path not found"
    L.err_container_read_failed = "could not read META-INF/container.xml ("
    L.err_gemini_invalid_json = "Gemini returned invalid JSON: "
    L.err_gemini_no_text_raw = "\nRaw text: "
    L.err_getpagexpointer = "getPageXPointer failed"
    L.err_getposfromxpointer = "getPosFromXPointer failed"
    L.err_href_not_found = "href for the spine item not found"
    L.err_network = "Network error: "
    L.err_opf_read_failed = "could not read .opf ("
    L.err_text_too_short = "too little text left after cleanup"
    L.err_unzip_not_in_path = "unzip binary not found in PATH"
    L.err_write_failed = "could not write "
    L.log_draw_error = "draw error: "
    L.log_findalltext_failed = "findAllText failed, chunk="
    L.log_findalltext_failed_inc = "findAllText (incremental) failed, chunk="
    L.log_finishscan_error = "finishScan error: "
    L.log_incrementalscan_error = "incrementalScan error: "
    L.log_mentions = " mentions"
    L.log_new_mentions = " new mentions"
    L.log_plugin_initialized = "plugin initialized"
    L.mentions_found_suffix = " character mentions found"
    L.menu_api_key_set = " (set)"
    L.menu_api_key_unset = " (not set)"
    L.menu_card_list = "Character list"
    L.menu_rescan_now = "Rescan now"
    L.menu_series = "Book series"
    L.menu_series_linked = "Book series: "
    L.menu_series_unlinked = "Book series (not linked)"
    L.menu_title = "Character Cards"
    L.menu_underline = "Underline characters in text"
    L.menu_underline_enable = "Enable underlining"
    L.net_no_connection = "No internet connection."
    L.net_wifi_prompt_ok = "Once Wi-Fi connects, try the action again."
    L.no_book_open = "No book is open."
    L.no_characters_at_all = "No characters yet.\nSelect a name in the text → «Add character»."
    L.no_characters_yet = "No characters yet — first add one by selecting a name."
    L.no_data_yet = "No data yet."
    L.nothing_new_from_quote = "Gemini didn't find any new information in this excerpt."
    L.occupation_label = "Occupation"
    L.personality_colon = "Personality:"
    L.personality_colon_sp = "Personality: "
    L.relationships_colon = "Relationships:"
    L.relationships_colon_sp = "Relationships: "
    L.scanning_book = "Scanning the book for characters…"
    L.series_added_merged = "». Added "
    L.series_added_merged_mid = " new character(s), merged with existing: "
    L.series_create_btn = "Create a new series and link this book"
    L.series_link_existing_btn = "Link to an existing series"
    L.series_linked_msg_pre = "Linked to series «"
    L.series_linked_prefix = "This book is linked to the series «"
    L.series_name_hint = "e.g. The Talisman"
    L.series_name_title = "Series name"
    L.series_none_yet = "No series yet. Create one first — «Book series → Create a new series»."
    L.series_pick_title = "Choose a series"
    L.series_unlink_body1 = "The series' characters won't disappear — they'll still be available "
    L.series_unlink_body2 = "from any other book linked to this series. This book will simply "
    L.series_unlink_body3 = "go back to its own, separate character list "
    L.series_unlink_body4 = "(the one it had before linking)."
    L.series_unlink_btn = "Unlink from series"
    L.series_unlink_confirm_pre = "Unlink this book from the series «"
    L.series_unlink_qmark = "»?\n\n"
    L.series_unlinked_msg = "Unlinked from series."
    L.standout_colon = "Standout trait: "
    L.unknown_value = "unknown"
    L.updated_colon = "Updated «"
    L.which_character_prompt = "Add to which character?"

    L.prompt_create_character = "You are analyzing an excerpt from a work of fiction in English.\n\n" ..
        "Excerpt (the last few pages the reader just read):\n\"\"\"\n{{context}}\n\"\"\"\n\n" ..
        "A character named \"{{name}}\" is mentioned in this excerpt. Write a short card for " ..
        "them based ONLY on this excerpt — don't invent anything, don't pull information from " ..
        "elsewhere. Leave fields empty if the excerpt says nothing about them.\n\n" ..
        "Response format — STRICTLY JSON only, no explanations, no ```:\n" ..
        '{\n' ..
        '  "aliases": ["another name or nickname, if the excerpt addresses them that way"],\n' ..
        '  "occupation": "occupation/status (e.g. blacksmith, Jack\'s stepfather, company owner) — empty string if unknown",\n' ..
        '  "physical_description": "appearance ONLY if explicitly described in the text, otherwise an empty string",\n' ..
        '  "personality": "stable character traits, inferred from how they act/speak (not a recap of events) — empty string if not evident",\n' ..
        '  "relationships": ["WHO THIS CHARACTER IS to another person — always in this direction: \'the king\'s daughter\', \'Jack\'s stepfather\', \'Speedy\'s enemy\'. NEVER describe it the other way around (not \'her father is the king\', but \'the king\'s daughter\')."],\n' ..
        '  "standout_trait": "ONE most noticeable, most distinctive trait — physical or behavioral, the thing that would identify them at a glance — or an empty string",\n' ..
        '  "background": "a short backstory/origin for the character, if mentioned in the excerpt (where they\'re from, what happened to them before) — otherwise an empty string"\n' ..
        '}'

    L.prompt_update_character = 'Here is a quote from the book:\n"""\n{{quote}}\n"""\n\n' ..
        "This is about the character \"{{name}}\". Here is their current card:\n" ..
        "Occupation: {{occupation}}\n" ..
        "Appearance: {{physical_description}}\n" ..
        "Personality: {{personality}}\n" ..
        "Relationships: {{relationships}}\n" ..
        "Standout trait: {{standout_trait}}\n" ..
        "Background: {{background}}\n\n" ..
        "Update the card using the quote above. For the fields \"occupation\", \"physical_description\", " ..
        "\"personality\", \"background\" return the FULL desired value of the field (not just the new " ..
        "fragment!) — combine what's already recorded above with what the quote adds, concisely, in " ..
        "your own words, without duplicating MEANING. If the quote suggests the same thing that's " ..
        "already recorded, just in different words (for example, the field already says \"bald\", and " ..
        "the quote says \"a bald head\" or \"no hair\") — that's the SAME THING, mark it only ONCE, " ..
        "pick the better phrasing, don't write both. If the quote adds nothing at all for some field — " ..
        "return its CURRENT value unchanged (copy what's above), not an empty string — leave it empty " ..
        "only if nothing at all is known about that field yet, neither now nor from the quote. Each " ..
        "field — at most 1-2 short sentences, never copy the quote verbatim.\n\n" ..
        "Response format — STRICTLY JSON only, no explanations, no ```:\n" ..
        '{\n' ..
        '  "occupation": "full updated value of the field (or the current value unchanged, or empty)",\n' ..
        '  "physical_description": "full updated value of the field (or the current value unchanged, or empty)",\n' ..
        '  "personality": "full updated value of the field AS AN INFERENCE from how the character acts/speaks (not a recap of events), or the current value unchanged, or empty",\n' ..
        '  "aliases": ["a new name/nickname, if the quote reveals one"],\n' ..
        '  "relationships": ["a new relationship to someone, if there is one in the quote — always in the form \'this character is [someone] relative to [someone else]\' (e.g. \'the king\'s daughter\', not \'her father is the king\')"],\n' ..
        '  "standout_trait": "ONLY if this quote shows something more noticeable/distinctive than what\'s already recorded above — a new standout trait, otherwise an empty string",\n' ..
        '  "background": "full updated value of the field (or the current value unchanged, or empty)"\n' ..
        '}'

    log("applied — interface and Gemini prompts are now in English")
end)

log("charcards-en patch registered")
