# CharCards

A fully manual, AI-assisted character tracker plugin for [KOReader](https://github.com/koreader/koreader).

**No background scanning, no automatic character extraction — you decide when a character gets added and what counts as new information about them.**

CharCards was originally created for Ukrainian readers and the interface and Gemini prompts are Ukrainian by default. An **English localization patch** is now included, so the plugin can also be used in English.

## English

### How it works

CharCards combines the control of a manual character tracker with some of the automation of AI-assisted trackers, while keeping the amount of book text sent to AI deliberately limited.

**You and only you decide:**

* which characters to add;
* when to add them;
* what information is important;
* which parts of the book should be used to update a character.

There is no automatic scan of the whole book, chapter, or page in the background.

### Add a character

Select a character's name in the text and choose **Add Character**.

When a new character is created, CharCards sends Gemini only a limited context around the current page:

* 2 pages before the current page;
* the current page;
* the next page.

Gemini uses this context to create a short character card containing information such as:

* aliases;
* occupation;
* appearance;
* personality;
* relationships with other characters;
* defining traits;
* background.

The context is limited intentionally. CharCards does **not** send the whole book or chapter to Gemini.

### Add information to a character

You can select any passage in the book and choose **Add to Character**.

Then select one of your existing characters.

Gemini sees:

* only the text you selected;
* the current contents of the relevant character fields.

It returns a short rewritten version that combines the existing information with the new information.

This means you can decide yourself which passages are important enough to add to a character.

You can also edit every field of a character card manually.

### Character names and aliases

CharCards can optionally underline character names and aliases directly in the text.

This feature is **disabled by default** and can be enabled from the plugin menu.

When a new name or alias is added, CharCards searches the book for that new name. It does not rescan all character names every time a character card is updated.

Tapping an underlined name opens a compact character card with information such as occupation, relationships, defining trait and background.

### Book series

By default, every book has its own separate character list.

If several books belong to a series, you can connect them to a shared series:

**Character Cards → Book Series → Create New Series**

or:

**Character Cards → Book Series → Link to Existing Series**

After linking, the character cards are stored in a shared series file. A character encountered in the first book is immediately available in the next book, so you can continue updating the same card instead of starting from scratch.

Existing character data is not lost when a book is linked to a series. If the book already has its own character cards, they are merged into the shared series pool. Matching characters are combined using the same principle as **Add to Character**, without creating duplicates or losing existing information. New characters are simply added.

**Unlink from Series** returns the book to its own separate character list.

### Installation

Copy the `charcards.koplugin` folder to:


/koreader/plugins/


The folder should contain at least:


charcards.koplugin/
├── _meta.lua
└── main.lua

Restart KOReader.

The plugin will appear under:

**Tools → Character Cards**

### Gemini API key

CharCards requires a Gemini API key.

You can get a free key from [Google AI Studio](https://aistudio.google.com/).

There are two ways to configure it.

#### 1. From KOReader

Open:

**Character Cards → Gemini API Key**

Enter the key and save it.

Alternatively, simply try to perform an action such as **Add Character**. If no API key is configured, CharCards will ask you to enter one.

#### 2. Through USB

If you don't want to type a long API key on an e-reader touchscreen, create:

```text
charcards.koplugin/api.lua
```

with:

```lua
return "your_key_here"
```

### English localization

The plugin itself is Ukrainian by default, but an English localization patch is included in the repository.

Copy:

```text
patches/1-charcards-en.lua
```

to:

```text
/koreader/patches/
```

Then restart KOReader.

The interface and Gemini prompts will now be in English.

To return to Ukrainian, simply remove:

```text
/koreader/patches/1-charcards-en.lua
```

and restart KOReader.

### Internet connection

The two actions that communicate with Gemini first check the internet connection.

If Wi-Fi is disabled, CharCards can offer to enable it using KOReader's standard Wi-Fi dialog instead of simply failing with a network error.

### Privacy / spoilers

One of the main ideas behind CharCards is to avoid sending unnecessary book content to AI.

When creating a character, Gemini receives only the limited context around the current page.

After that, Gemini receives only text that you explicitly choose to add to a character, together with the existing contents of the relevant character fields.

There is no background scan of the whole book, chapter, or page.

You choose what information is sent.

### Known limitations

* **EPUB only.** CharCards is designed for EPUB. FB2 is not directly supported yet. Converting FB2 to EPUB before reading is recommended.
* **Character context is limited to one EPUB spine item.** If a character appears at the very beginning of an EPUB chapter, the available context simply stops at the beginning of that chapter.
* **Cyrillic word boundaries.** Character highlighting uses the regular-expression search built into KOReader's crengine. Its `\b` word boundary is tied to ASCII letters and does not properly recognize Cyrillic. Therefore Cyrillic names are searched as ordinary substrings without word-boundary protection. As a result, a short character name can occasionally be underlined inside an unrelated word containing the same sequence of letters.
* **One Gemini API key.** The plugin currently uses one API key for the whole plugin, not a separate key per book.

### Feedback

CharCards is still being developed.

Bug reports, suggestions and feedback are very welcome. If something doesn't work correctly on your device or with a particular EPUB, please let me know.

### Support

If you find CharCards useful and have the opportunity, you can buy me a coffee:

[Ko-fi](https://ko-fi.com/poostoon)

### License

MIT — see [LICENSE](https://github.com/poostoon/charcards/blob/main/LICENSE).

---

## Українською

**CharCards** — плагін для KOReader, який веде картки персонажів книги
вручну, за твоєю командою, без жодного фонового сканування.

### Як це працює

* **Виділив ім'я персонажа в тексті → «Додати персонажа».**
  Плагін бере поточну сторінку + кілька сторінок назад як контекст і питає
  Gemini скласти коротку картку: псевдоніми, рід занять, зовнішність,
  характер, звʼязки з іншими персонажами, найхарактерніша риса, бекграунд.

* **Виділив будь-який уривок → «Додати до персонажа».**
  Обираєш зі списку вже доданих персонажів — Gemini бачить поточний текст
  кожного поля цілком і повертає вже переформульоване повне значення, що
  об'єднує старе й нове стисло.

* **Підкреслення в тексті.** За бажанням (вимкнено за замовчуванням —
  вмикається в меню) плагін підкреслює вже знайдені імена й псевдоніми прямо
  в тексті сторінки. Пересканування книги запускається лише коли зʼявляється
  справді нове ім'я чи псевдонім (не при кожному оновленні картки), і шукає
  лише це нове ім'я, а не всіх персонажів заново. Тап на підкреслене ім'я
  показує компактну картку: рід занять, звʼязки, найхарактерніша риса,
  бекграунд.

* **Ручне редагування.** Будь-яке поле картки (включно з ім'ям) можна
  виправити вручну через «Змінити персонажа» — окремий діалог на кожне поле.

* **Серія книг.** За замовчуванням кожна книга ізольована — свій окремий
  набір персонажів. Якщо книга — частина серії, її можна прив'язати до
  спільної серії (**Картки персонажів → Серія книг → Створити нову серію**
  або **Прив'язати до існуючої**): тоді картки читаються й пишуться у
  спільний файл на всі книги серії, а не в сайдкар однієї книги. Персонаж,
  зустрінутий у першій книзі, одразу доступний і в другій — можна
  продовжувати доповнювати його картку, не починаючи з нуля. Прив'язка не
  втрачає вже накопичені дані: якщо в книзі до прив'язки вже були власні
  картки, вони зливаються зі спільним пулом серії (однакові персонажі
  об'єднуються тим самим принципом, що й «Додати до персонажа» — без
  дублів і без втрати інформації, нові персонажі просто додаються).
  «Відв'язати від серії» повертає книгу до її власного, окремого списку.

### Встановлення

Скопіювати папку `charcards.koplugin` з файлами `main.lua` і `_meta.lua`
в папку:

```text
/koreader/plugins/
```

Перезапустити KOReader. Пункт меню зʼявиться в:

**Інструменти → Картки персонажів**

### Ключ Gemini API

Потрібен безкоштовний ключ з [Google AI Studio](https://aistudio.google.com/).

Два способи задати ключ:

1. **Через меню в KOReader** — Картки персонажів → Ключ Gemini API →
   ввести й зберегти. Або просто виконай будь-яку дію («Додати персонажа») —
   плагін сам запропонує ввести ключ, якщо його ще нема.

2. **Вручну через USB** — створи файл
   `charcards.koplugin/api.lua` з одним рядком:

   ```lua
   return "твій_ключ_тут"
   ```

   Зручно, якщо не хочеш набирати довгий ключ на сенсорному екрані.

### Localization / English

Для англійського інтерфейсу скопіюй:

```text
patches/1-charcards-en.lua
```

у:

```text
/koreader/patches/
```

і перезапусти KOReader.

Щоб повернутися до української — просто видали цей файл.

### Мережа

Обидві дії, що звертаються до Gemini, спершу перевіряють підключення до
інтернету. Якщо Wi-Fi вимкнено — плагін сам пропонує його ввімкнути
(штатний діалог KOReader), а не просто падає з помилкою мережі.

### Відомі обмеження

* **Межа слова для кирилиці.** Підкреслення персонажів у тексті шукає імена
  через вбудований у crengine регекс-пошук. Його `\b` (межа слова)
  прив'язана до ASCII-літер і не бачить кирилицю — тому кириличні імена
  шукаються як звичайний підрядок, без захисту межі слова. Наслідок: коротке
  ім'я персонажа вряди-годи підкреслить частину не пов'язаного слова, в
  якому воно трапляється як підрядок.

* **Контекст для нової картки** береться в межах одного розділу
  (spine-елемента EPUB). Якщо персонаж з'явився на самому початку розділу —
  вікно контексту просто впирається в початок розділу.

* Розраховано на **EPUB** (текст сторінки видобувається через unzip +
  OPF/spine). FB2 напряму не підтримується (поки що) — рекомендується
  конвертувати у EPUB перед читанням.

* Один ключ Gemini API на весь плагін (не per-book).

### Ліцензія

MIT — див. [LICENSE](https://github.com/poostoon/charcards/blob/main/LICENSE).

### Підтримка

Якщо плагін тобі корисний, можеш пригостити мене кавою:

[Ko-fi](https://ko-fi.com/poostoon)
