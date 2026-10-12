# План реализации TASK-001: ядро — NotchWindow, состояния, WidgetRegistry, config.json, меню-бар

Спецификация: `docs/tasks/TASK-001.md`
ADR: ADR-001 (окно/состояния/hover), ADR-002 (хранение), ADR-003 (протокол/реестр/concurrency), ADR-004 (ввод текста), ADR-005 (энергопотребление), ADR-006 (окно настроек/жизненный цикл).
Этот план — базовый для TASK-002..008: общие решения, структура папок, тестовая инфраструктура и порядок реализации описаны здесь.

---

## 0. Общая картина и порядок реализации задач

### Порядок задач (рекомендуемый)
| # | Задача | Почему здесь | Зависит от |
|---|---|---|---|
| 1 | TASK-001 ядро | всё строится на его контрактах | — |
| 2 | TASK-002 настройки | точка расширения настроек нужна всем виджетам; проверяет registry/config вживую | 001 |
| 3 | TASK-005 батарея | самый простой реальный виджет: событийный, без разрешений, без ввода текста; обкатывает peek с priority и кнопку внутри compact | 001, 002 |
| 4 | TASK-004 таймер | высший приоритет peek, первый data/-файл (`timer.json`), первый виджет с `NotchTextField` → **первая ручная проверка AC-22 TASK-001** | 001, 002 |
| 5 | TASK-003 календарь | разрешения (ленивые), actor вокруг EventKit, планирование «на ближайший момент» | 001, 002 |
| 6 | TASK-006 заметки | самые ценные данные; использует отлаженные к этому моменту ввод текста и data/-хранилище; добавляет `NotchTextEditor` | 001, 002, (004 — обкатанный `NotchTextField`) |
| 7 | TASK-008 монитор | изолированный, но самый рискованный по CPU; к этому моменту есть понимание замеров | 001, 002 |
| 8 | TASK-007 погода | сеть, кеш, backoff; единственная внешняя зависимость (риск лицензии отложен) | 001, 002, (006/004 — поле ввода) |

Каждая задача — отдельный цикл: реализация → ревью кода и безопасности (файлы data/ и config ревьюируются по ADR-002; ревью БД не нужно, БД нет) → техническое тестирование → приёмка.

### Структура папок (итоговая для всех задач)
```
App/            NotchApp.swift, AppDelegate.swift, AppEnvironment.swift, SingleInstanceGuard.swift, MenuBarContent.swift
Window/         NotchPanel.swift, NotchHostingView.swift, NotchWindowController.swift, NotchViewModel.swift, NotchStateMachine.swift
Window/Screen/  ScreenInfo.swift, ScreenResolver.swift, NotchGeometry.swift, ScreenManager.swift
Window/Views/   NotchRootView.swift, NotchShape.swift, CompactContainerView.swift, ExpandedPanelView.swift, TabBarView.swift, EmptyStateView.swift
Window/TextInput/ TextInputCoordinator.swift, NotchTextField.swift, (NotchTextEditor.swift — TASK-006)
Core/Logging/   Log.swift
Core/JSON/      JSONValue.swift
Core/Persistence/ AppPaths.swift, AtomicFile.swift, DebouncedSaver.swift, VersionedJSONFile.swift, BackupNaming.swift
Core/Config/    AppConfig.swift, ConfigCodec.swift, ConfigDefaults.swift, ConfigStore.swift, WidgetOrder.swift
Core/Widgets/   NotchWidget.swift, WidgetID.swift, WidgetVisibility.swift, WidgetContext.swift, WidgetSettingsHandle.swift, WidgetCatalog.swift, WidgetRegistry.swift, PeekResolver.swift
Core/Observation/ ObservationLoop.swift
Core/System/    NotificationObservation.swift, SystemEvents.swift
Core/Scheduling/ OneShotScheduler.swift
Core/UI/        CompactSplit.swift, InlineConfirmView.swift, WidgetMessageView.swift
Widgets/Clock/  ClockWidget.swift, ClockTicker.swift, ClockViews.swift
Widgets/<Name>/ ... (TASK-003..008)
Settings/       ... (TASK-002)
Resources/      Info.plist (генерируется XcodeGen), NotchApp.entitlements, Localizable.xcstrings, InfoPlist.xcstrings
Tests/          Core/..., Window/..., Widgets/<Name>/..., TestSupport/ (FakeWidget, TempDirectory)
```

### Правила для разработчика (действуют во всех задачах)
- После каждого шага: `make build` без warning'ов (warnings = errors) и `make test` зелёный.
- Всё UI и модели — `@MainActor`; тяжёлое — в `actor`; DTO — `Sendable` struct (ADR-003, раздел «Модель concurrency»).
- Никаких повторяющихся таймеров без обоснования (ADR-005).
- В NotchWindow — только `NotchTextField`/`NotchTextEditor`, не SwiftUI-поля (ADR-004).
- Строки UI — через `String(localized:)`/`LocalizedStringKey` → `Localizable.xcstrings` (en — язык разработки, ru — перевод).
- Логи — `Log.<category>` (`os.Logger`), без PII и без пользовательских данных (тексты заметок, события календаря, координаты).
- Подтверждения внутри NotchWindow — встроенный `InlineConfirmView`, **не** `.alert`/`.confirmationDialog` (системные алерты в borderless non-key панели отображаются некорректно/не получают фокус). В окне настроек — обычные `.confirmationDialog`.

---

## Архитектурное решение

### Поток данных
```
 config.json ⇄ ConfigStore (@MainActor, debounce 300 мс, atomic write)
                    ▲  ▼
 WidgetCatalog → WidgetRegistry (@Observable) ── activate/deactivate/visibility ──► виджеты (@Observable, @MainActor)
                    │ peekWinner (вычисляемое, реактивно от isActive)
                    ▼
 NotchViewModel (@Observable) ◄── NotchStateMachine (чистая) ◄── события: hover (NSTrackingArea), click, text input, peek availability
      │ state, geometry, selectedTabID
      ├──► NotchWindowController → NotchPanel.setFrame (ADR-001, стратегия «расширить → анимировать → ужать»)
      └──► NotchRootView (SwiftUI): NotchShape + CompactContainer / ExpandedPanel(TabBar + widget.makeExpandedView())
 ScreenManager (didChangeScreenParameters, коалесцирование 200 мс) → ScreenResolver (чистая) → NotchGeometry (чистая) → NotchViewModel
 AppDelegate → AppEnvironment (composition root); MenuBarExtra → Settings/Quit
```

### Ключевые типы и сигнатуры
(Полные контракты протокола и реестра — ADR-003; хранения — ADR-002.)

**Window**
```swift
enum NotchState: Equatable, Sendable { case collapsed, peek, expanded }

enum NotchEvent: Equatable, Sendable {
    case pointerEntered, pointerExited, clicked
    case openDelayElapsed(token: Int), closeDelayElapsed(token: Int)
    case peekAvailabilityChanged(Bool)
    case textInputBegan, textInputEnded
    case screenChanged
}
enum NotchEffect: Equatable, Sendable {
    case scheduleOpen(after: Duration, token: Int)
    case scheduleClose(after: Duration, token: Int)
    case cancelPending
    case transition(to: NotchState)
    case endTextInput
}
struct NotchStateMachine: Sendable {
    private(set) var state: NotchState
    private(set) var pointerInside: Bool
    private(set) var textInputActive: Bool
    private(set) var hasPeek: Bool
    mutating func handle(_ event: NotchEvent) -> [NotchEffect]
}
```
Правила переходов (основа unit-тестов):
- `pointerEntered` в collapsed/peek → `scheduleOpen(150 мс)`; `pointerExited` до срабатывания → `cancelPending` (AC-5).
- `openDelayElapsed(t)` с актуальным токеном и `pointerInside` → `transition(.expanded)`.
- `clicked` в peek/collapsed → немедленно `transition(.expanded)`.
- `pointerExited` в expanded и `!textInputActive` → `scheduleClose(300 мс)`; повторный `pointerEntered` → `cancelPending` (AC-6: разворот из текущего положения обеспечивает SwiftUI spring; машина лишь меняет цель).
- `closeDelayElapsed(t)` → `transition(hasPeek ? .peek : .collapsed)` (AC-4, AC-9).
- `textInputBegan` → `textInputActive = true`, `cancelPending`; `textInputEnded` → false и, если `!pointerInside`, `scheduleClose(300 мс)` (AC-22).
- `peekAvailabilityChanged(b)` в collapsed/peek → `transition(b ? .peek : .collapsed)`; в expanded только запоминается (AC-8, AC-9).
- `screenChanged` → `endTextInput`, `transition(hasPeek ? .peek : .collapsed)`.

```swift
@MainActor @Observable final class NotchViewModel {
    private(set) var state: NotchState
    private(set) var geometry: NotchGeometry
    var selectedTabID: String?            // запоминается между открытиями (в памяти)
    let registry: WidgetRegistry
    var onLayoutChange: (@MainActor (NotchLayoutRequest) -> Void)?   // для NotchWindowController
    func send(_ event: NotchEvent)         // прогоняет машину и исполняет эффекты (Task.sleep + токен)
    func animationDidFinish(for state: NotchState)  // из SwiftUI completion → ужать frame
}
struct NotchLayoutRequest { let frame: CGRect; let phase: Phase }  // .growBeforeAnimation / .shrinkAfterAnimation / .immediate
```

**Screen**
```swift
struct ScreenInfo: Equatable, Sendable {
    let id: String                // UUID из CGDisplayCreateUUIDFromDisplayID
    let name: String              // NSScreen.localizedName
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftWidth: CGFloat?
    let auxiliaryTopRightWidth: CGFloat?
    let isPrimary: Bool           // NSScreen.screens.first
    var hasNotch: Bool { safeAreaTop > 0 && auxiliaryTopLeftWidth != nil }
}
enum DisplayMode: String, Codable, Sendable { case auto, primary, notch, display }
enum ScreenResolver { static func resolve(screens: [ScreenInfo], mode: DisplayMode, displayID: String?) -> ScreenInfo? }
struct NotchGeometry: Equatable, Sendable {
    let screenID: String; let isPhysicalNotch: Bool
    let collapsedRect: CGRect; let peekRect: CGRect; let expandedRect: CGRect
    let notchWidth: CGFloat; let notchHeight: CGFloat
    static func make(for screen: ScreenInfo, sideWidth: CGFloat = 96, expandedSize: CGSize = .init(width: 520, height: 200)) -> NotchGeometry
}
@MainActor @Observable final class ScreenManager {
    private(set) var screens: [ScreenInfo]
    private(set) var current: ScreenInfo?
    func apply(mode: DisplayMode, displayID: String?)
    var onChange: (@MainActor (NotchGeometry?) -> Void)?
}
```
Правило `auto`: экран с физической чёлкой (если несколько — встроенный, т.е. первый с `hasNotch`), иначе primary. `notch`: экран с чёлкой, иначе primary. `display`: экран с `id == displayID`, иначе primary (выбор сохраняется — AC-12, TASK-002 AC-12).

**Core/Widgets** — см. ADR-003 (протокол `NotchWidget`, `WidgetContext`, `WidgetSettingsHandle`, `WidgetCatalog`, `WidgetRegistry`, `PeekResolver`).
```swift
enum ActivationReason: Sendable { case launch, userEnabled }
enum WidgetVisibility: Equatable, Sendable { case hidden, compact, expanded }
struct PeekCandidate: Sendable { let id: String; let priority: Int; let isActive: Bool; let order: Int }
enum PeekResolver { static func winner(_ candidates: [PeekCandidate]) -> String? }
```

**Core/Config, Persistence** — см. ADR-002. Сигнатуры:
```swift
struct AppPaths: Sendable { let root: URL; var config: URL; var dataDir: URL; func data(_ name: String) -> URL; static func standard() throws -> AppPaths }
struct AtomicFile: Sendable { let url: URL; func read() throws -> Data?; func write(_ data: Data) throws; func moveAside(suffix: String) throws -> URL; func copy(suffix: String) throws -> URL; func modificationDate() -> Date? }
enum BackupNaming { static func timestamp(_ date: Date) -> String }  // yyyyMMdd-HHmmss UTC
@MainActor final class DebouncedSaver { init(delay: Duration, save: @escaping @MainActor () -> Void); func markDirty(); func flush() }
enum ConfigCodec { static let currentSchemaVersion = 1; static func decode(_ data: Data) throws -> ConfigDocument; static func encode(_ doc: ConfigDocument) throws -> Data }
enum ConfigDefaults { static func document(catalogOrder: [String]) -> ConfigDocument }
@MainActor @Observable final class ConfigStore {
    private(set) var document: ConfigDocument
    private(set) var loadIssue: ConfigLoadIssue?     // .createdDefault / .recoveredBroken(URL) / .newerSchema(Int) / .writeFailed
    init(paths: AppPaths, saveDelay: Duration = .milliseconds(300))
    func load()
    func update(_ mutate: (inout ConfigDocument) -> Void)   // → markDirty
    func flush()
    func resetToDefaults()
}
enum WidgetOrder { static func reorder(entries: [WidgetConfigEntry], knownIDs: Set<String>, newKnownOrder: [String]) -> [WidgetConfigEntry]
                   static func reconcile(entries: [WidgetConfigEntry], catalog: [WidgetDescriptor]) -> [WidgetConfigEntry] }
```

**Core/System, Scheduling, Observation**
```swift
@MainActor final class NotificationObservation { init(center: NotificationCenter = .default, name: Notification.Name, object: AnyObject? = nil, handler: @escaping @MainActor () -> Void); func cancel() }
@MainActor final class SystemEvents {   // ленивые подписки: наблюдатели ставятся при первом подписчике, снимаются при последнем
    enum Kind: Sendable { case wake, willSleep, clockChanged, timeZoneChanged, dayChanged }
    func subscribe(_ kinds: Set<Kind>, handler: @escaping @MainActor (Kind) -> Void) -> SystemEventsSubscription  // cancel()
}
@MainActor final class OneShotScheduler { func schedule(at date: Date, tolerance: Duration, _ action: @escaping @MainActor () -> Void); func schedule(after: Duration, tolerance: Duration, _ action: @escaping @MainActor () -> Void); func cancel() }
@MainActor final class ObservationLoop<Value: Equatable> { init(read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void); func cancel() }
```
`ObservationLoop` внутри: `withObservationTracking({ read() }, onChange: { Task { @MainActor [weak self] in self?.fire() } })`; `fire` читает новое значение, сравнивает с предыдущим, вызывает `onChange` и перерегистрируется.

**Core/UI**
- `CompactSplit<Leading: View, Trailing: View>`: читает из `@Environment(\.notchGapWidth)` ширину физической чёлки и раскладывает `HStack { leading; Spacer(minLength: gap); trailing }` — так compact-вид виджета занимает обе стороны чёлки (Q4). Ширина каждой стороны ограничена `sideWidth`, контент обрезается (`.lineLimit(1)`, `.truncationMode(.tail)`).
- `InlineConfirmView(message:confirmTitle:cancelTitle:onConfirm:onCancel:)`.
- `WidgetMessageView(symbol:title:message:actionTitle:action:)` — единый вид для состояний «нет доступа», «нет данных», ошибок.

**Clock** (Widgets/Clock/)
```swift
@MainActor @Observable final class ClockWidget: NotchWidget {  // id "clock", priority 10, isActive = true всегда
    private(set) var now: Date
    init(context: WidgetContext)
}
enum ClockTicker { static func nextMinuteBoundary(after: Date, calendar: Calendar) -> Date
                   static func nextSecondBoundary(after: Date) -> Date }
```
Обновление: `OneShotScheduler` на следующую границу минуты (`.compact`) или секунды (`.expanded`); перепланирование после каждого срабатывания; `SystemEvents` `{wake, clockChanged, timeZoneChanged, dayChanged}` → немедленное обновление `now` и перепланирование (AC-19, ≤ 1 с). Форматирование: `Date.FormatStyle` с `.timeZone(.autoupdatingCurrent)` / `Locale.autoupdatingCurrent`; compact — `.dateTime.hour().minute()` (12/24 ч по локали), expanded — `.hour().minute().second()` + `.dateTime.weekday(.wide).day().month(.wide)`. Подписки только между `activate`/`deactivate`.

> Продуктовое следствие спецификации: часы `isActive = true` всегда → пока часы включены, на Mac с чёлкой видно peek с временем, а collapsed (полностью «железная» чёлка) достигается только при выключенных часах. Это прямо следует из AC-19 + шкалы приоритетов; если нужно иначе (часы только в expanded) — это изменение спецификации.

---

## Изменения в «БД» (файлы)
БД нет. Файлы — ADR-002:
- `~/Library/Application Support/NotchApp/config.json` (schemaVersion 1, формат из спецификации + аддитивное `general.displayName`).
- Папка `data/` создаётся лениво при первой записи data-файла.
- Миграции: `schemaVersion` 1; при будущих изменениях — функция `ConfigMigrations.migrate(raw:from:)` (в этой задаче не нужна, точка расширения в `ConfigCodec.decode`).

## Контракты
- Внешних API нет. Внутренние: протокол `NotchWidget` (ADR-003), формат config.json (спецификация + ADR-002).
- Меню-бар: «Настройки…» (⌘,) — в TASK-001 **неактивен** (`.disabled(true)`), активируется в TASK-002; «Выйти» (⌘Q).

## Изменения project.yml / Makefile / ресурсов
1. Test target (шаг 0):
```yaml
options:
  developmentLanguage: en
targets:
  NotchApp:
    # ... как сейчас, плюс:
    scheme:
      testTargets: [NotchAppTests]
    info:
      properties:
        # ... как сейчас (ключи разрешений добавляются в задачах 003/004)
  NotchAppTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests]
    dependencies:
      - target: NotchApp
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: dev.visor.NotchAppTests
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/NotchApp.app/Contents/MacOS/NotchApp
        BUNDLE_LOADER: $(TEST_HOST)
```
   Тесты хостятся в приложении (иначе нельзя `@testable import NotchApp` из app-таргета без выделения фреймворка). `AppDelegate` при наличии `XCTestConfigurationFilePath` не поднимает окна/виджеты (ADR-006).
   Если загрузка тест-бандла упадёт из-за Hardened Runtime + ad-hoc подписи (library validation) — добавить в `NotchApp.settings.configs.Debug`: `ENABLE_HARDENED_RUNTIME: NO` (Release не трогаем). Проверить в шаге 0.
   Фреймворк тестов — **Swift Testing** (`import Testing`, `@Test`, `#expect`), поставляется с Xcode 16 (Swift 6). Если Xcode старше — XCTest, структура та же.
2. Makefile: добавить цель
```make
test: gen
	xcodebuild -quiet -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```
   и `.PHONY: gen build run clean test`.
3. Ресурсы: `Resources/Localizable.xcstrings` (en + ru). `LOCALIZATION_PREFERS_STRING_CATALOGS: YES`, `SWIFT_EMIT_LOC_STRINGS: YES` в `settings.base` таргета. Ключи `Info.plist` добавляются **через `info.properties` в project.yml** (XcodeGen перегенерирует Info.plist), локализация описаний разрешений — `Resources/InfoPlist.xcstrings` (появится в TASK-003/004).

---

## Шаги реализации
Каждый шаг завершается `make build` (0 warnings) и `make test`. После шагов 6, 7, 8, 10 — ручная проверка (раздел «Что проверить глазами»).

1. **Тестовая инфраструктура.** project.yml (test target, scheme, developmentLanguage, string catalog settings), Makefile `test`, `Tests/TestSupport/TempDirectory.swift`, тривиальный `Tests/SmokeTests.swift`; `App/AppDelegate.swift` с `@NSApplicationDelegateAdaptor` и XCTest-guard; `Resources/Localizable.xcstrings`.
   Проверка: `make build && make test` зелёные; `make run` — иконка в меню-баре как раньше.
2. **Логирование и JSONValue.** `Core/Logging/Log.swift` (`enum Log { static let app, window, config, widgets = Logger(subsystem: "dev.visor.NotchApp", category: ...) }`), `Core/JSON/JSONValue.swift`.
   Тесты: round-trip всех кейсов, `merging` сохраняет неизвестные ключи, decode/encode Codable-структур через JSONValue, даты ISO-8601.
3. **Persistence + Config.** `Core/Persistence/*`, `Core/Config/*` (кроме связи с registry).
   Тесты (temp dir): нет файла → дефолт + файл создан (AC-13, порядок 7 id, `displayMode: auto`); мусор → `config.json.broken-<ts>` + дефолт (AC-14); `schemaVersion: 2` → известное прочитано, при сохранении создан `config.json.v2-backup-<ts>`, `schemaVersion` в файле остался 2, неизвестные поля на месте (AC-15); неизвестный widget id и неизвестные ключи в корне/`general`/элементе/`settings` переживают сохранение (AC-16); `WidgetOrder.reorder` держит неизвестные на своих слотах; `DebouncedSaver`: 5 `markDirty` подряд → 1 запись; `flush()` пишет немедленно (AC-17); запись в read-only папку → `loadIssue = .writeFailed`, без исключения наружу.
4. **Протокол виджета и реестр.** `Core/Widgets/*`, `Core/Observation/ObservationLoop.swift`, `Core/System/NotificationObservation.swift`, `Core/System/SystemEvents.swift`, `Core/Scheduling/OneShotScheduler.swift`.
   Тесты с `Tests/TestSupport/FakeWidget.swift` (`@MainActor @Observable`, счётчики `activateCount/deactivateCount`, последняя `visibility`): `PeekResolver` (приоритет, тайбрейк по порядку, пусто → nil — AC-7, AC-9); `setEnabled(false)` → `deactivate` 1 раз, виджет исчез из `enabledWidgets` и `peekWinner` (AC-18); быстрое on/off/on → ровно один активный цикл; `move` меняет config-порядок; `updateVisibility` вызывает `visibilityDidChange` только при изменении; `ObservationLoop` срабатывает на смену `isActive` у FakeWidget (AC-8).
5. **Composition root и меню-бар.** `App/AppEnvironment.swift`, `App/SingleInstanceGuard.swift`, `App/MenuBarContent.swift`, правка `App/NotchApp.swift` (MenuBarExtra → `MenuBarContent`, пункт «Настройки…» disabled, «Выйти» ⌘Q). `applicationWillTerminate → flushAll`.
   Проверка: `make run` → меню с двумя пунктами; повторный `open build/.../NotchApp.app` не создаёт второй процесс (`pgrep -x NotchApp | wc -l` = 1) (AC-20, AC-21); config.json создан.
6. **Экраны и статичное окно.** `Window/Screen/*`, `Window/NotchPanel.swift`, `Window/NotchHostingView.swift` (пока без hover), `Window/NotchWindowController.swift`, `Window/Views/NotchShape.swift`, минимальный `NotchRootView` (только collapsed-форма: на физической чёлке — чёрная форма в размер чёлки, на остальных — пилюля).
   Тесты: `ScreenResolver` для всех `DisplayMode` (чёлка+внешний, только внешний, clamshell — нет встроенного, `display` с отсутствующим id → primary); `NotchGeometry` (прямоугольник чёлки из aux-областей, пилюля ≥ 200×24, peek/expanded центрированы по чёлке).
   Ручная проверка: AC-1, AC-2, AC-10, AC-11, AC-12 (см. ниже).
7. **Машина состояний, hover, анимации.** `Window/NotchStateMachine.swift`, `Window/NotchViewModel.swift`, tracking area в `NotchHostingView`, стратегия frame «grow → animate → shrink» (ADR-001), spring + Reduce Motion, `NotchRootView` с тремя состояниями (expanded пока с заглушкой-текстом).
   Тесты машины состояний: все правила из раздела «Ключевые типы» — AC-3 (open через 150 мс), AC-4 (close 300 мс → peek/collapsed), AC-5 (выход < 150 мс — нет open), AC-6 (enter во время close → cancel, цель expanded), AC-22 (exit при textInputActive — нет close; textInputEnded вне панели → close), устаревший токен игнорируется.
   Ручная проверка: AC-3..6, плавность, Reduce Motion.
8. **Peek и expanded с вкладками.** `Window/Views/CompactContainerView.swift` (клик → `.clicked`), `ExpandedPanelView.swift`, `TabBarView.swift` (SF Symbol вкладки, порядок `registry.enabledWidgets`, `selectedTabID` в памяти; если выбранная вкладка выключена — первая), `EmptyStateView.swift` («Нет включённых виджетов» + «Открыть настройки», кнопка неактивна до TASK-002), `Core/UI/CompactSplit.swift`, `InlineConfirmView.swift`, `WidgetMessageView.swift`. `ObservationLoop` на `registry.peekWinner?.id` → `.peekAvailabilityChanged`. `registry.updateVisibility(state:selectedTabID:)` на каждый переход/смену вкладки. Переход compact-виджета A→B — `.transition(.opacity)` + `.id(widget.id)` внутри анимированного контейнера.
   Тесты: `NotchViewModel` с FakeWidget-ами (без окна): смена `isActive` у старшего FakeWidget в collapsed → state `.peek`, `peekWinnerID` меняется (AC-8); все неактивны → `.collapsed` (AC-9); видимость: expanded+вкладка X → X `.expanded`, остальные `.hidden`.
   Ручная проверка: AC-7, AC-8 (через временный DEBUG-переключатель в FakeWidget не нужен — проверяется в TASK-005/004 на реальных виджетах; здесь — часы), AC-23.
9. **Инфраструктура ввода текста.** `Window/TextInput/TextInputCoordinator.swift`, `NotchTextField.swift` (ADR-004), `NotchPanel.isTextInputActive` + `canBecomeKey`, события `.textInputBegan/.textInputEnded` в `NotchViewModel`, `endTextInput` при сворачивании и `screenChanged`.
   Тесты: уже покрыты машиной состояний (шаг 7); добавить тест `NotchViewModel`: `textInputBegan` → `pointerExited` → через 400 мс state всё ещё `.expanded`.
   Ручная проверка AC-22 — **переносится в TASK-004** (первый виджет с полем). Здесь только: окно по-прежнему не становится key при кликах/hover (AC-10).
10. **Виджет «Часы».** `Widgets/Clock/*`, регистрация в `WidgetCatalog`.
    Тесты: `ClockTicker.nextMinuteBoundary` (обычная минута, 59:59.999, переход суток, смена часового пояса через инъекцию `Calendar`/`TimeZone`); виджет: `visibilityDidChange(.expanded)` → запланирована секундная граница, `.hidden/.compact` → минутная; `deactivate` → `scheduler` отменён, подписок нет (AC-18).
    Ручная проверка: AC-19 (смена часового пояса/времени в Системных настройках, сон).
11. **Финальная проверка энергопотребления и локализации.** Прогон по ADR-005 (простой: выключить часы, чтобы получить collapsed; и с часами в peek), заполнить ru-переводы в `Localizable.xcstrings`.
    Проверка: НФТ (CPU < 0.5% средн. за 60 с, память < 60 МБ в Activity Monitor), UI на ru и en (смена языка системы или `-AppleLanguages (ru)` в схеме).

## Соответствие AC → шаг
| AC | Шаг | Как проверяется |
|---|---|---|
| AC-1 | 6 | тест геометрии + вручную |
| AC-2 | 6 | тест геометрии + вручную |
| AC-3, AC-4, AC-5, AC-6 | 7 | unit (машина) + вручную |
| AC-7, AC-8, AC-9 | 4, 8 | unit (PeekResolver, ViewModel) + вручную в TASK-004/005 |
| AC-10, AC-11 | 6, 9 | вручную |
| AC-12 | 6 | unit (resolver) + вручную |
| AC-13..AC-17 | 3 | unit |
| AC-18 | 4, 10 | unit (FakeWidget, Clock) |
| AC-19 | 10 | unit (ticker) + вручную |
| AC-20, AC-21 | 5 | вручную |
| AC-22 | 7, 9 | unit; вручную — в TASK-004 |
| AC-23 | 8 | вручную (+ unit на fallback выбранной вкладки) |

## Что проверить глазами (инструкция пользователю)
1. **Чёлка (AC-1)**: на MacBook с чёлкой при collapsed (часы выключены через config `"enabled": false` для `clock`) — ничего не видно, край чёлки не «толще» железной; сделать скриншот ⌘⇧4 зоны и увеличить — нет серой каймы/сдвига.
2. **Пилюля (AC-2)**: на внешнем мониторе (или `displayMode: "primary"` при внешнем основном) — чёрная пилюля по центру сверху, не меньше 200×24.
3. **Hover (AC-3..6)**: медленно навести — раскрытие через ~0.15 с; «чиркнуть» курсором поперёк — не раскрывается; увести — сворачивание через ~0.3 с; увести и сразу вернуть посреди сворачивания — панель плавно разворачивается обратно без скачка.
4. **Reduce Motion**: Системные настройки → Универсальный доступ → Дисплей → «Уменьшить движение» — вместо пружины короткое затухание.
5. **Фокус (AC-10)**: печатать в TextEdit, водить мышью по чёлке, раскрыть, кликнуть по вкладкам — ввод в TextEdit не прерывается, курсор TextEdit не теряется; Cmd+Tab и Mission Control не показывают окно чёлки.
6. **Spaces/fullscreen (AC-11)**: переключиться на другой рабочий стол и в полноэкранный Safari — hover работает, панель поверх выезжающего меню-бара.
7. **Мониторы (AC-12)**: подключить/отключить внешний монитор, сменить масштабирование встроенного экрана (Дисплеи → «Больше места») — чёлка за ~1 с на месте и в размер.
8. **Меню-бар (AC-1 клики)**: при свёрнутой чёлке кликнуть по пунктам меню-бара и иконкам статус-бара рядом с чёлкой — клики проходят.
9. **Плавность**: Instruments → «Animation Hitches» во время 10 открытий/закрытий — без hitches; на ProMotion визуально 120 Гц.
10. **Энергия (НФТ)**: по ADR-005, раздел «Как проверяем».

## Риски и trade-offs
- **Синхронизация frame окна и SwiftUI-анимации** (ADR-001) — возможное однокадровое мерцание при «ужатии»; митигировано тем, что ужатие происходит только после завершения анимации и при совпадении цели. Проверка — пункт 9 выше.
- **Level окна** `mainMenu + 3` — эмпирика; при проблемах поднимаем (одна строка).
- **Tracking area при изменении frame под неподвижным курсором** — разовая сверка `NSEvent.mouseLocation` после `setFrame`.
- **Hosted unit-тесты + Hardened Runtime** — возможный отказ загрузки тест-бандла; fallback — отключить Hardened Runtime только в Debug.
- **Часы всегда активны** → peek с часами виден по умолчанию; collapsed-проверки делаются с выключенными часами.
- **`Identifiable` убран из протокола** в пользу `nonisolated var id` (ADR-003) — отклонение от исходного наброска, обосновано Swift 6.

---

## Отклонения при реализации (2026-10-12)
Окружение: Xcode 26.6, Swift 6.3.3, SDK macOS 26.5, deployment target 14.0.

1. **Падение AppKit при смене frame (критично, исправлено).** Когда `NotchHostingView` был `contentView` панели, SwiftUI подгонял окно под размер контента (232 → 237 pt) прямо в display cycle, и AppKit бросал `NSGenericException: ... more Update Constraints in Window passes than there are views in the window`, так что приложение падало при первом раскрытии. Решение: hosting view кладётся в обычный контейнерный `NSView` через autoresizing (`NotchWindowController`), плюс `sizingOptions = []` и `safeAreaRegions = []`. Регрессионный тест `NotchWindowIntegrationTests` гоняет реальное окно по циклам открытия/закрытия (во время `make test` панель ненадолго видна на экране).
2. **`isolated deinit`** (Swift 6.2, back-deploy на macOS 14 через `_deinitOnExecutorMainActorBackDeploy`) в `NotificationObservation`, `SystemEventsSubscription`. Обычный `deinit` не изолирован и не может трогать non-Sendable токен наблюдателя; `isolated deinit` позволяет обойтись без `nonisolated(unsafe)` (ADR-003 п.8).
3. **`DisplayMode`** объявлен в `Core/Config/AppConfig.swift`, а не в `Window/Screen`: он часть формата конфига, Core не должен зависеть от Window.
4. **`ConfigStore.init(paths:defaultWidgetOrder:saveDelay:now:)`**: дефолтный порядок передаётся параметром (в `AppEnvironment` это `WidgetCatalog.defaultOrder`), чтобы Config не зависел от каталога и тестировался с любыми id. `now` нужен для детерминированных имён бэкапов.
5. **`ConfigDocument`**: неизвестные ключи корня лежат в `extra` (как в `general`/элементах), а не в полном `raw`; семантика та же.
6. **`ConfigLoadIssue.unreadable`** (новый кейс): файл не читается и его не удаётся переименовать. Тогда работаем только в памяти и **никогда** не перезаписываем файл (иначе потеряли бы данные, которые не смогли прочитать). Если не удался бэкап при `schemaVersion > 1`, запись тоже пропускается (`.writeFailed`).
7. **`OneShotScheduler.schedule(at:relativeTo:tolerance:_:)`**: добавлен параметр `relativeTo` (по умолчанию `Date()`), чтобы виджет считал задержку по своим (инжектируемым) часам.
8. **`ObservationLoop<Value: Equatable & Sendable>`**: Swift 6 требует `Sendable` для значения, которое пересекает `Task`.
9. **Часы в `.hidden` не тикают вообще** (в плане минутная граница для `.hidden/.compact`). При переходе в `.compact/.expanded` время сразу обновляется. Это строже по ADR-005; на AC-19 не влияет: в peek/expanded поведение то же.
10. **`NotchViewModel`**: `init(registry:reduceMotion:)` сам вычисляет `hasPeek` из реестра; `selectedTabID` стал `private(set)`, смена вкладки идёт через `selectTab(_:)` (анимация + `updateVisibility`); добавлен `peekWidgetID` (последний победитель, держится до конца fade-out при уходе peek → collapsed).
11. **`WidgetRegistry`**: добавлены `widget(id:)`, `resolvedTabID(_:)` (fallback на первую включённую вкладку), `activateEnabledWidgets()`, `deactivateAll()`.
12. **`AppEnvironment.stop()` / `NotchWindowController.close()`**: нужны интеграционному тесту.
13. **Info.plist**: добавлено `CFBundleLocalizations = [en, ru]`, иначе при единственном `ru.lproj` английская система могла бы выбрать ru.
14. **Hardened Runtime в Debug не отключался**: тест-бандл грузится (Xcode сам пишет «Disabling hardened runtime with ad-hoc codesigning» для Debug).
15. `MenuBarContent` пока без параметров: пункт «Settings…» неактивен до TASK-002.

### Изменения после ревью, итерация 1
16. **`JSONValue.intValue`** через `Int(exactly:)`: прежняя проверка пропускала 2^63, и `Int(value)` падал по trap (например, при `"schemaVersion": 9223372036854775808` приложение падало на каждом старте).
17. **`AtomicFile`** уходит от ADR-002 «`Data.write(.atomic)`», семантика атомарности та же:
    - запись идёт во временный файл, созданный `open(O_CREAT|O_EXCL, 0600)`, затем `fsync` и `rename`;
    - каталоги создаются с `0700`; если старый каталог шире, права ужесточаются;
    - чтение через `open(O_NOFOLLOW|O_NONBLOCK)` + `fstat`: только обычный файл, не больше 4 МБ (`AtomicFile.defaultMaxSize`); иначе ошибка, а `ConfigStore` применяет к файлу политику broken.
18. **`NotchViewModel`**:
    - `sleep` инжектируется (тесты используют `ManualSleeper`);
    - `transitionGeneration` открыт на чтение;
    - при смене экрана `windowFrame` обнуляется до `.screenChanged`, чтобы frame не охватывал оба дисплея.
19. **`AppEnvironment.notchWindow`** открыт на чтение: интеграционный тест проверяет итоговый frame панели.

### Изменения после QA
20. **`JSONValue.integer(Int64)`** (уходит от ADR-002 «числа как Double»):
    - целые, которые помещаются в Int64, хранятся точно; остальные числа остаются `.number(Double)`;
    - равенство между двумя видами чисел работает только при точном совпадении значения;
    - `schemaVersion` пишется как integer.
    Иначе целые > 2^53 в неизвестных полях и `settings` портились при сохранении (AC-16).

### Изменения после ручной проверки
21. **Неподвижный «холст» для SwiftUI-контента** (уточняет ADR-001, раздел «Поправка по итогам ручной проверки»; заменяет autoresizing hosting view из п.1). При hover peek → expanded правая часть формы прыгала влево, а панель expanded выезжала сверху: hosting view растягивался вместе с окном и SwiftUI внутри анимации перецентрировал чёлку по новой ширине, а `.frame(width:height:)` без alignment центрировал контент по вертикали. Решение: `NotchGeometry.canvasRect` (объединение collapsed/peek/expanded); hosting view с `autoresizingMask = []` всегда стоит на frame холста в координатах окна (выставляется в `NotchWindowController.apply(_:)` до `panel.setFrame`); контейнер `clipsToBounds = true`; в `NotchRootView` — `.frame(width:height:alignment: .top)`. Стратегия «grow → animate → shrink» не изменилась.
