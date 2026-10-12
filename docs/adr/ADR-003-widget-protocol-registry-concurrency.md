# ADR-003: Протокол NotchWidget, WidgetRegistry и модель concurrency (Swift 6)

Статус: принято (архитектор), 2026-10-12
Связано: TASK-001 (п. 7–8, AC-7..9, AC-18), TASK-002 (AC-4..7, AC-13, AC-14, AC-17), все виджеты TASK-003..008

## Контекст
Исходный набросок проекта задаёт:
```swift
protocol NotchWidget: AnyObject, Identifiable {
    var id: String { get }; var title: String { get }; var priority: Int { get }; var isActive: Bool { get }
    func makeCompactView() -> AnyView; func makeExpandedView() -> AnyView
}
```
Спецификации добавляют: настройки виджета, `activate()/deactivate()`, реактивный `isActive`, ленивые разрешения (не при старте), «собирать метрики только пока видно» (TASK-008), секундный тик только в expanded (TASK-001 п.10), flush данных при выходе.

Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`, warnings = errors) делает несколько мест протокола проблемными.

## Проблемы исходного протокола в Swift 6
1. **Нет изоляции.** Виджеты — `@Observable`-модели, которые читает SwiftUI на main thread. Без `@MainActor` у протокола любые обращения из `View.body` (а `body` в Swift 6 изолирован на `@MainActor`) к не-изолированному классу — ошибки Sendable. Решение: `@MainActor protocol`.
2. **`Identifiable` + `@MainActor`.** Требование `id` у `Identifiable` — неизолированное. Вычисляемое `var id: String { "clock" }` внутри `@MainActor`-класса изолировано на main actor и **не может** удовлетворить неизолированное требование → ошибка компиляции. При этом `Identifiable` нам ничего не даёт: массив `[any NotchWidget]` (экзистенциалы) всё равно не используется в `ForEach` как `Identifiable` — пишем `ForEach(widgets, id: \.id)`.
3. **`AnyView`** — оставляем. Альтернатива `associatedtype Compact: View` делает протокол непригодным для хранения в `[any NotchWidget]` без танцев с type erasure; потеря производительности от `AnyView` на 1–2 view в чёлке несущественна.
4. **`AnyObject`** — оставляем: виджет — долгоживущая модель с состоянием, идентичность важна.

## Решение: минимально отличающийся протокол (Core/Widgets/NotchWidget.swift)
```swift
@MainActor
protocol NotchWidget: AnyObject {
    nonisolated var id: String { get }          // стабильный: clock, calendar, timer, battery, weather, sysmon, notes
    var title: String { get }                   // локализованное
    var symbolName: String { get }              // SF Symbol для вкладки и списка в настройках
    var priority: Int { get }
    var isActive: Bool { get }                  // @Observable-свойство, ядро не опрашивает

    func makeCompactView() -> AnyView
    func makeExpandedView() -> AnyView
    func makeSettingsView() -> AnyView?         // nil → страницы настроек нет (TASK-002 AC-14)

    func activate(reason: ActivationReason)     // .launch | .userEnabled
    func deactivate()
    func visibilityDidChange(_ visibility: WidgetVisibility) // .hidden | .compact | .expanded
    func reloadSettings()                       // после «Сбросить настройки»
    func flush()                                // синхронно сохранить data/ (выход, сворачивание)
    var deactivationWarning: String? { get }    // не nil → настройки спрашивают подтверждение (TASK-004 AC-13)
}
```
`extension NotchWidget` даёт дефолты: `makeSettingsView() → nil`, `visibilityDidChange` / `reloadSettings` / `flush` — пустые, `deactivationWarning → nil`.

Реализация `id` в виджете: `nonisolated var id: String { "clock" }` (литерал, без доступа к состоянию — компилируется без предупреждений). Константы id лежат в `enum WidgetID { static let clock = "clock" ... }` (`nonisolated`/`Sendable` по умолчанию, т.к. `String`).

Отличия от исходного наброска, все аддитивные: `@MainActor`; `Identifiable` → `nonisolated var id`; новые требования с дефолтами. Протокол для существующих сигнатур `makeCompactView/makeExpandedView/priority/isActive/title` не меняется.

### Почему `ActivationReason`
TASK-003 AC-1 / TASK-002 AC-6: системный запрос доступа — при **включении** пользователем или первом показе вкладки, но **не** при старте. При запуске приложения ядро вызывает `activate(reason: .launch)` для включённых виджетов; при переключении тумблера в настройках — `.userEnabled`.

### Почему `visibilityDidChange`
Ядро единственное знает, что видно: `.expanded` — выбранная вкладка в expanded; `.compact` — виджет-победитель в peek; иначе `.hidden`. На этом построены: секундный тик часов только в expanded (TASK-001), сэмплирование монитора только при видимости (TASK-008 AC-1, AC-3), ленивая загрузка заметок (TASK-006), обновление погоды при открытии (TASK-007 AC-5), ленивый запрос доступа к календарю при показе вкладки (TASK-003 AC-1). Виджет получает вызов **только при изменении** значения.

## Контекст виджета (Core/Widgets/WidgetContext.swift)
Виджет создаётся один раз при старте фабрикой и живёт всё время (даже выключенный — чтобы страница настроек работала), но ресурсы держит только между `activate` и `deactivate`.
```swift
@MainActor struct WidgetContext {
    let settings: WidgetSettingsHandle   // чтение/запись widgets[i].settings
    let paths: AppPaths                  // data/ для своих файлов
    let systemEvents: SystemEvents       // подписки на wake/clock/timezone/day change
    let openSettings: @MainActor () -> Void
}

@MainActor final class WidgetSettingsHandle {
    func load<S: Decodable>(_ type: S.Type) -> S?          // nil → виджет берёт дефолт
    func save<S: Encodable>(_ value: S)                     // слияние в raw-объект + ConfigStore.markDirty()
}
```

## Каталог и реестр
- `WidgetCatalog` (Core/Widgets/WidgetCatalog.swift): `static let all: [WidgetDescriptor]` в дефолтном порядке (Часы, Календарь, Таймер, Батарея, Погода, Системный монитор, Заметки). `WidgetDescriptor { id: String; defaultEnabled: Bool; make: @MainActor (WidgetContext) -> any NotchWidget }`. Новый виджет = одна строка здесь (TASK-002 AC-17). На этапе TASK-001 в каталоге только `clock`; виджеты появляются по мере реализации задач. Дефолтный порядок задаётся константой `WidgetCatalog.defaultOrder: [String]` (все 7 id), поэтому AC-13 корректен с первого дня, а id ещё не реализованных виджетов просто сохраняются как «неизвестные».
- `WidgetRegistry` (Core/Widgets/WidgetRegistry.swift) — `@MainActor @Observable final class`:
  - `private(set) var items: [WidgetItem]` — известные виджеты в порядке конфига (`WidgetItem { widget: any NotchWidget; enabled: Bool }`).
  - `var enabledWidgets: [any NotchWidget]` (вычисляемое), `var peekWinner: (any NotchWidget)?` (вычисляемое через `PeekResolver`).
  - `func setEnabled(_ id: String, _ enabled: Bool)`, `func move(fromOffsets: IndexSet, toOffset: Int)`, `func moveUp(_ id:)`, `func moveDown(_ id:)`, `func resetToDefaults()`, `func flushAll()`, `func updateVisibility(state: NotchState, selectedTabID: String?)`.
  - Идемпотентность активации: `private var activatedIDs: Set<String>`; `activate` вызывается, только если id нет в множестве, `deactivate` — только если есть. Всё синхронно на main actor → быстрые переключения тумблера не дают гонок (TASK-002 «граничные случаи»).
- `PeekResolver.winner(candidates: [PeekCandidate]) -> String?` — чистая функция: среди `enabled && isActive` максимум `priority`, при равенстве — меньший индекс в порядке (AC-7). Тестируется отдельно.

Реактивность `isActive`: SwiftUI-view автоматически отслеживает чтение `registry.peekWinner` (Observation отслеживает доступ к `@Observable`-свойствам виджетов внутри вычисления). Для AppKit-части (смена frame окна) используется `ObservationLoop` (Core/Observation/ObservationLoop.swift) — обёртка над `withObservationTracking`, которая после каждого изменения перерегистрируется и вызывает колбэк на main actor. Это не опрос: колбэк срабатывает только на запись в отслеживаемые свойства.

## Модель concurrency — правила для всего проекта
1. **Всё UI и все модели виджетов — `@MainActor`.** Так проще и безопаснее: SwiftUI всё равно читает их на main; большинство обновлений редкие.
2. **Тяжёлое/блокирующее — в `actor`** с Sendable-DTO на выходе: `CalendarService` (EventKit, `EKEventStore` не Sendable — живёт только внутри актора), `SystemSampler` (Mach/sysctl), сетевой клиент погоды — `struct WeatherClient: Sendable` с `async`-методами (`URLSession` сам уходит с main).
3. **DTO между акторами — `struct ...: Sendable`** из примитивов (цвет календаря — `RGBAColor`, а не `CGColor`/`NSColor`).
4. **Notification observers**: `NotificationObservation` (Core/System/) — регистрирует `addObserver(forName:object:queue: .main)` и внутри вызывает `MainActor.assumeIsolated { handler() }`. `queue: .main` гарантирует main thread, `assumeIsolated` сообщает это компилятору. В handler **не передаём** `Notification` (не Sendable) — только факт события или извлечённые примитивы. Снятие подписки — в `cancel()`/`deinit` (токен хранится в виджете между activate/deactivate).
5. **C-колбэки (IOKit)**: run-loop source добавляется в **main** run loop, контекст — `Unmanaged.passUnretained(self).toOpaque()`, в колбэке `MainActor.assumeIsolated { ... }`. Источник обязательно снимается в `deactivate()` до освобождения объекта.
6. **Таймеры**: только `Task { try await Task.sleep(for:/until:, tolerance:) }` на main actor, хранятся в свойстве и отменяются (`task?.cancel()`) в `deactivate`/при перепланировании. `Timer.scheduledTimer` не используем (closure-API в Swift 6 требует `@Sendable` и лишних прыжков). Повторяющихся таймеров в ядре нет (ADR-005).
7. **Глобальные C-переменные** (`vm_kernel_page_size`, `mach_task_self_`) в Swift 6 дают ошибку «not concurrency-safe». Используем функции: `getpagesize()`, `mach_host_self()` (кэшируется один раз в акторе — каждый вызов создаёт send right).
8. `@unchecked Sendable` и `nonisolated(unsafe)` — только с комментарием-обоснованием и только после согласования на ревью.

## Последствия
- (+) Протокол совместим с духом исходного наброска и компилируется под Swift 6 complete без предупреждений.
- (+) Окно настроек и чёлка работают с любым виджетом без знания деталей (TASK-002 AC-17).
- (−) Требований стало больше; все новые имеют дефолты — простой виджет (часы) реализует 6–7 членов.
- (−) Виджеты создаются при старте даже выключенными (по одному объекту, без ресурсов). Цена — килобайты памяти; выигрыш — работающая страница настроек выключенного виджета.
