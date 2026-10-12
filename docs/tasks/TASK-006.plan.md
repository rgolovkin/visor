# План реализации TASK-006: виджет «Быстрые заметки»

Спецификация: `docs/tasks/TASK-006.md`. Базовый план: `TASK-001.plan.md`. ADR: ADR-004 (ввод текста в non-key панели — ключевой), ADR-002 (data/notes.json, broken/newer/conflict, flush).
Рекомендуемая очередь: 6-я задача (после таймера, где `NotchTextField` и AC-22 уже проверены вживую).

## Архитектурное решение
```
NotesExpandedView ── NotesListView (поиск: NotchTextField) ── NotchTextEditor (NSTextView, ADR-004)
        │ intents                                   │ textDidChange (каждый ввод)
        ▼                                           ▼
NotesWidget (@MainActor @Observable) ──► NotesStore (@MainActor @Observable): notes, selectedID, readOnly, issue
                                              │ DebouncedSaver(500 мс) ; flush() синхронно
                                              ▼
                                         NotesFile: AtomicFile(data/notes.json) + mtime-сверка + broken/newer/conflict
```
- Загрузка **лениво** при первом `visibilityDidChange(.expanded)` (НФТ: не при старте приложения).
- Сохранение: debounce 500 мс после последнего изменения (AC-3); синхронный `flush()` при: `visibilityDidChange(.hidden)` (панель свернулась/вкладка сменилась), `TextInputCoordinator.end()` (потеря фокуса), `deactivate()`, `flush()` реестра на Quit (AC-4).
- Почему `NSTextView`, а не SwiftUI `TextEditor`: в non-key панели SwiftUI не даёт узнать о клике до получения фокуса, нет `hasMarkedText()` для IME и нет контроля plain-text вставки и лимита — ADR-004.

## Файлы
```
Widgets/Notes/NotesWidget.swift         — id "notes", priority 0, isActive = false всегда, symbolName "note.text"
Widgets/Notes/NotesStore.swift          — модель списка, сортировка, поиск, пустые заметки
Widgets/Notes/NotesFile.swift           — формат и политика файла
Widgets/Notes/Note.swift                — Note (Codable, Sendable), NotesDocument
Widgets/Notes/NotesSettings.swift       — Codable
Widgets/Notes/NotesViews.swift          — список, редактор, тулбар, сообщения, settings
Window/TextInput/NotchTextEditor.swift  — NEW: многострочный редактор (NSScrollView + NotchNSTextView)
Tests/Widgets/Notes/NotesStoreTests.swift, NotesFileTests.swift, NotesSearchPerformanceTests.swift, NoteTitleTests.swift
```

## Типы и сигнатуры
```swift
struct Note: Codable, Equatable, Sendable, Identifiable {
    var id: String             // UUID().uuidString
    var text: String
    var createdAt: Date        // ISO-8601
    var updatedAt: Date
    var pinned: Bool
    var extra: [String: JSONValue]   // неизвестные поля элемента сохраняются (ADR-002)
}
struct NotesDocument: Sendable { var schemaVersion: Int; var notes: [Note]; var raw: [String: JSONValue] }

enum NotesLoadResult: Sendable { case loaded(NotesDocument, modDate: Date?), empty, recoveredBroken(backup: URL), newerSchema(NotesDocument, version: Int) }
struct NotesFile: Sendable {
    init(url: URL)
    func load() -> NotesLoadResult                               // broken → moveAside(".broken-<ts>") (AC-10); newer → read-only (AC-11)
    func save(_ doc: NotesDocument, expectedModDate: Date?) throws -> Date
        // если текущий mtime != expected → copy на диске в "notes.conflict-<ts>.json", затем атомарная запись (AC-13)
}

@MainActor @Observable final class NotesStore {
    private(set) var notes: [Note]
    var selectedID: String?
    var query: String
    private(set) var readOnly: Bool
    private(set) var issue: NotesIssue?                 // .recovered(path) / .readOnlyNewer / .writeFailed / .tooLarge
    var visibleNotes: [Note] { get }                     // фильтр + сортировка (заморожена во время редактирования)
    func loadIfNeeded()
    func createNote() -> String
    func updateText(_ id: String, _ text: String)        // > 1 МБ (UTF-8) → отклонить, issue = .tooLarge (AC-12)
    func delete(_ id: String)
    func togglePin(_ id: String)
    func leaveNote(_ id: String)                         // пустая → удалить без подтверждения (AC-8); разморозить сортировку
    func flush()
}
enum NoteTitle { static func title(of text: String) -> String; static func preview(of text: String) -> String }  // первая непустая строка (AC-5)
enum NotesSearch { static func filter(_ notes: [Note], query: String) -> [Note] }  // range(of:options: [.caseInsensitive, .diacriticInsensitive]) (AC-6)

struct NotesSettings: Codable, Equatable, Sendable {
    var sortBy = "updated"        // "updated" | "created"
    var fontSize = 13             // 12...18
    var deleteConfirmation = true
    var pinnedFirst = true
}

// Window/TextInput/NotchTextEditor.swift
struct NotchTextEditor: NSViewRepresentable {
    let documentID: String                    // смена id → заменить string; иначе НЕ трогать textView.string (не сбивать курсор)
    let initialText: String
    let fontSize: CGFloat
    let maxBytes: Int
    let onChange: @MainActor (String) -> Void
    let onEndEditing: @MainActor () -> Void
    let autoFocus: Bool                        // «Новая» → курсор в редакторе (AC-1)
}
```

### Правила
- **Ввод** (AC-2): подкласс `NSTextView` — `acceptsFirstMouse = true`, `mouseDown` → `TextInputCoordinator.begin(self)` → `super`; `resignFirstResponder` → `onEndEditing` + `coordinator.end()`; `performKeyEquivalent` для ⌘X/C/V/A/Z/⇧⌘Z (ADR-004); `isRichText = false`, `importsGraphics = false`, `allowsUndo = true`, `isAutomatic*Substitution = false`. «Новая» с `autoFocus`: вызвать `coordinator.begin(textView)` программно (окно становится key по явному действию пользователя — кнопке «Новая»; это в рамках Q1: фокус в поле по действию пользователя).
- **Лимит 1 МБ** — в `textView(_:shouldChangeTextIn:replacementString:)` считаем итоговую длину `utf8.count`; превышение → `false` + сообщение (AC-12). Для отзывчивости на 1 МБ: `layoutManager.allowsNonContiguousLayout = true`.
- **Сортировка** (AC-5): `pinnedFirst` → закреплённые сверху; затем по `updatedAt`/`createdAt` по убыванию. Пока редактор в фокусе — порядок заморожен (снимок id), пересортировка в `leaveNote`.
- **Поиск** ≤ 100 мс на 1000 заметок — проверяется perf-тестом (`ContinuousClock.measure` в Swift Testing, порог 100 мс на Debug с запасом).
- **Удаление** (AC-7): при `deleteConfirmation` — `InlineConfirmView` в панели (не системный алерт).
- **Последняя открытая заметка** — `selectedID` в `widgets[notes].settings.lastSelectedID`? Нет: это не настройка, а состояние → храним в `notes.json` в корне (`"lastSelectedId"`), аддитивно к формату спецификации.
- **Дубликаты id** при загрузке → второй получает новый UUID (граничный случай).
- **Ошибка записи** (нет места/прав): `issue = .writeFailed`, текст остаётся в памяти, повтор при следующем изменении (DebouncedSaver).
- **Приватность**: `Log` никогда не получает текст заметок; только счётчики/коды ошибок.
- Формат файла документируется в `docs/formats/notes.md` (короткий файл; для Windows-клиента) — создаётся в шаге 1.

## Шаги реализации
1. `Note`, `NotesDocument`, `NotesFile` + тесты (temp dir): round-trip с неизвестными полями; битый → `.broken-<ts>` + `recoveredBroken`; `schemaVersion: 2` → `newerSchema`, `save` не вызывается (store в readOnly); mtime изменён извне → создан `notes.conflict-<ts>.json` с внешней версией, наша записана; запись в read-only папку → throws. + `docs/formats/notes.md`. → AC-10, AC-11, AC-13.
2. `NoteTitle`, `NotesSearch`, `NotesStore` + тесты: сортировка/pinned; пустая заметка удаляется в `leaveNote`; лимит 1 МБ; дубликаты id; debounce 500 мс → одна запись на серию из 10 изменений; `flush()` пишет сразу; perf поиска на 1000 заметок. → AC-3, AC-5, AC-6, AC-8, AC-12.
3. `NotchTextEditor` (Window/TextInput/) — без привязки к заметкам. Проверка: `make build`.
4. `NotesWidget` + views + settings (sortBy, fontSize `Stepper` 12–18, deleteConfirmation, pinnedFirst; кнопка «Очистить заметки» с подтверждением — по TASK-002 Q2), регистрация в каталоге. Ленивая загрузка, flush на `.hidden`/`deactivate`. → AC-1, AC-2, AC-4, AC-7, AC-9, AC-14.
5. Ручная проверка, CPU.

## Соответствие AC → шаг
AC-1 → 4; AC-2 → 3 + 4 + 5 (вручную); AC-3 → 2 + 5 (kill -9); AC-4 → 4; AC-5, AC-6, AC-8, AC-12 → 2; AC-7, AC-9, AC-14 → 4; AC-10, AC-11, AC-13 → 1.

## Что проверить глазами
1. Навести на чёлку → вкладка «Заметки» → «Новая»: курсор мигает в редакторе. Напечатать по-русски и по-английски, переключая раскладку; ⌘A, ⌘C, ⌘V, ⌘Z, ⇧⌘Z работают.
2. Увести курсор с панели во время набора — панель остаётся. Включить японскую раскладку (Kana), начать композицию (подчёркнутый текст), увести курсор — панель остаётся.
3. Кликнуть в Safari — фокус ушёл туда (печать идёт в Safari), панель свернулась через ~0.3 с; заметка сохранена: `cat ~/Library/Application\ Support/NotchApp/data/notes.json`.
4. Вставить форматированный текст из Pages/Safari — вставляется как простой текст.
5. Напечатать, через ~1 с `kill -9 $(pgrep -x NotchApp)` → перезапуск → текст на месте (кроме последних ≤ 0.5 с).
6. Испортить `notes.json` (дописать мусор) → при открытии вкладки сообщение с путём к `notes.json.broken-…`.
7. Изменить `notes.json` в редакторе во время работы и затем что-то напечатать в чёлке → рядом появился `notes.conflict-….json`.
8. Вставить ~1 МБ текста — UI отзывчив; больше — понятное сообщение.
9. Создать пустую заметку, перейти на другую — пустая исчезла.
10. CPU в простое ~0%.

## Риски и trade-offs
- **Главный риск — ввод в non-activating панели** (IME, шорткаты). Митигировано: проверка уже пройдена на `NotchTextField` в TASK-004; fallback с `NSApp.activate()` описан в ADR-004.
- `notes.conflict-<ts>.json` хранит **внешнюю** версию с диска, а основной файл получает нашу (обе версии сохранены, ничего не теряется молча) — интерпретация формулировки «текущая версия сохраняется рядом».
- Синхронная запись на main при больших объёмах (десятки МБ) может дать подвисание — лимит 1 МБ на заметку и типичные объёмы делают это маловероятным; при необходимости выносим запись в фон (ADR-002).
- Поле `lastSelectedId` в корне notes.json — аддитивное расширение формата спецификации.
