# План реализации TASK-005: виджет «Батарея» (IOKit)

Спецификация: `docs/tasks/TASK-005.md`. Базовый план: `TASK-001.plan.md`. ADR: ADR-003 (C-колбэки IOKit, concurrency), ADR-005 (без опроса).
Рекомендуемая очередь: 3-я задача (после 001, 002).

## Архитектурное решение
```
IOKit Power Sources ──(run-loop source на main run loop)──► PowerSourceMonitor (@MainActor) ──debounce 300 мс──► readSnapshot()
NSProcessInfoPowerStateDidChange, NSWorkspace.didWake ─────────────────────────────────────────────────────────┘
                                   ▼
                       BatterySnapshot (Sendable struct)
                                   ▼
          BatteryPeekPolicy (чистая struct, тесты) ── OneShotScheduler (конец 5-сек peek)
                                   ▼
          BatteryWidget (@MainActor @Observable): snapshot, peekReason, isActive
                                   ▼
          BatteryCompactView / BatteryExpandedView / BatterySettingsView
AppleSmartBattery (IORegistry) ── читается только при visibility == .expanded ──► BatteryHealth?
```

## Файлы
```
Widgets/Battery/BatteryWidget.swift          — NotchWidget, id "battery", priority 80, symbolName "battery.75percent"
Widgets/Battery/BatterySettings.swift        — Codable, толерантный init(from:)
Widgets/Battery/BatterySnapshot.swift        — Sendable DTO + PowerSourceReader (чтение IOPS)
Widgets/Battery/PowerSourceMonitor.swift     — run-loop source, start/stop
Widgets/Battery/BatteryHealthReader.swift    — IORegistry AppleSmartBattery
Widgets/Battery/BatteryPeekPolicy.swift      — чистая логика peek
Widgets/Battery/BatteryViews.swift           — compact, expanded, settings
Core/Widgets/WidgetCatalog.swift             — + дескриптор battery (defaultEnabled: true)
Tests/Widgets/Battery/BatteryPeekPolicyTests.swift, BatterySnapshotParsingTests.swift, BatterySettingsTests.swift
```

## Типы и сигнатуры
```swift
struct BatterySnapshot: Equatable, Sendable {
    enum Source: Sendable { case ac, battery, unknown }
    enum Charge: Sendable { case charging, charged, notCharging, discharging }
    let hasBattery: Bool
    let percent: Int?                 // nil → «—»
    let source: Source
    let charge: Charge
    let optimizedChargingEngaged: Bool  // если ключ доступен, иначе false
    let minutesRemaining: Int?        // nil при kIOPSTimeRemainingUnknown/-1/0 → «Вычисляется…»/скрыто (AC-8)
    let lowPowerMode: Bool
}
enum PowerSourceReader {
    static func read() -> BatterySnapshot                       // IOPSCopyPowerSourcesInfo/List/GetPowerSourceDescription
    static func parse(descriptions: [[String: Any]], lowPowerMode: Bool) -> BatterySnapshot  // чистая, для тестов
}
struct BatteryHealth: Sendable, Equatable { let cycleCount: Int?; let maxCapacityPercent: Int? }
enum BatteryHealthReader { static func read() -> BatteryHealth? }   // IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")), IORegistryEntryCreateCFProperty: "CycleCount", "AppleRawMaxCapacity"/"NominalChargeCapacity", "DesignCapacity"

@MainActor final class PowerSourceMonitor {
    init(onChange: @escaping @MainActor () -> Void)
    func start()   // IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque()); CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    func stop()    // CFRunLoopRemoveSource + CFRunLoopSourceInvalidate; source = nil (AC-10)
}

struct BatteryPeekPolicy: Equatable, Sendable {
    enum Reason: Equatable, Sendable { case plugged, unplugged, full, low, critical }
    private(set) var reason: Reason?
    private(set) var transientUntil: Date?
    mutating func update(previous: BatterySnapshot?, current: BatterySnapshot, settings: BatterySettings, now: Date)
    mutating func dismissLow()                 // «скрыть»
    mutating func transientExpired(now: Date)
    var isActive: Bool { reason != nil }
}
struct BatterySettings: Codable, Equatable, Sendable {
    var lowThresholdPercent = 20      // 10/15/20/30
    var showPercentInPeekOnPlug = true
    var peekOnFull = true
    var showHealthDetails = true
}
```

### Правила `BatteryPeekPolicy` (основа тестов)
- Смена `source` (ac↔battery) → `reason = .plugged/.unplugged`, `transientUntil = now + 5 с` (AC-2, AC-3). При `showPercentInPeekOnPlug == false` compact показывает только иконку.
- `percent == 100 && source == .ac && peekOnFull && !fullShownLatch` → `.full` на 5 с, `fullShownLatch = true`; latch сбрасывается при `percent < 95` (AC-6).
- `source == .battery && percent <= threshold && !lowDismissed` → `.low` (или `.critical` при ≤ 10) **без** таймаута (AC-4, AC-5). Low/critical имеет приоритет над transient-причинами.
- Выход из low: `source == .ac` **или** `percent > threshold + 2` → `reason = nil`, `lowDismissed = false` (гистерезис, AC-4).
- `dismissLow()` → `lowDismissed = true`, `reason = nil`; повторное появление — только после «выхода из low» и нового падения, **или** первого пересечения ≤ 10 после скрытия (`criticalShownAfterDismiss` latch) (AC-13).
- Изменение `lowThresholdPercent` → немедленный пересчёт (`update` с тем же snapshot) (AC-12).
- Состояние «скрыто» — только в памяти (не персистится).
- Нет батареи → `reason = nil` всегда (AC-7).

### Обновления и энергия
- Колбэк IOKit: C-функция `@convention(c) (UnsafeMutableRawPointer?) -> Void`; внутри `MainActor.assumeIsolated { Unmanaged<PowerSourceMonitor>.fromOpaque(ctx!).takeUnretainedValue().handle() }` — source добавлен в **main** run loop, поэтому мы на main thread (ADR-003, п.5; пометить комментарием).
- `handle()` → коалесцирование 300 мс через `OneShotScheduler` (граничный случай «быстрые подключения-отключения»), затем `PowerSourceReader.read()` и `policy.update`.
- Дополнительно: `NotificationObservation(.NSProcessInfoPowerStateDidChange)` (Low Power Mode), `SystemEvents.wake` → перечитать.
- Таймер только один — конец transient-peek (`OneShotScheduler.schedule(at: transientUntil)`). Периодических нет (AC-9).
- `BatteryHealthReader.read()` — только на `visibilityDidChange(.expanded)` и только если `showHealthDetails`.
- `activate`: `monitor.start()`, первичное чтение (без transient-peek на первом snapshot: `previous == nil` → только low-логика). `deactivate`: `monitor.stop()`, отмена scheduler, снятие observers.

### Разбор Power Sources (правило для нескольких источников)
`IOPSCopyPowerSourcesList` → для каждого описания берём только `kIOPSTypeKey == kIOPSInternalBatteryType` (AC-11: AirPods/ИБП игнорируются). Нет такого → `hasBattery = false`. Источник питания — `IOPSGetProvidingPowerSourceType(nil)` (`kIOPSACPowerValue`/`kIOPSBatteryPowerValue`/`kIOPSUPSPowerValue`→ac). `percent = current * 100 / max` из `kIOPSCurrentCapacityKey`/`kIOPSMaxCapacityKey`. `charge`: `kIOPSIsChargingKey` → `.charging`; `kIOPSIsChargedKey` или percent == 100 на AC → `.charged`; AC и не заряжается → `.notCharging` (+ «(оптимизация)», если в описании присутствует ключ оптимизированной зарядки — ключ необязателен, отсутствие не ошибка); иначе `.discharging`. Время: `IOPSGetTimeRemainingEstimate()` на батарее, `kIOPSTimeToFullChargeKey` при зарядке; значения ≤ 0 → nil.
`import IOKit.ps` — фреймворк автолинкуется, правка project.yml не нужна.

## Шаги реализации
1. `BatterySnapshot` + `PowerSourceReader.parse` + тесты парсинга (только внутренняя батарея из нескольких источников; нет батареи; `-1` времени → nil; AC + не заряжается → notCharging). → AC-7, AC-8, AC-11.
2. `BatteryPeekPolicy` + `BatterySettings` + тесты всех правил (plug/unplug 5 с; low постоянный; гистерезис +2; dismiss до нового падения; повтор при критическом после dismiss; full с latch < 95; смена порога). → AC-2..6, AC-12, AC-13.
3. `PowerSourceMonitor` + `BatteryHealthReader` (без UI), `BatteryWidget` с `activate/deactivate`, регистрация в каталоге. Тест: `deactivate` → `monitor.isRunning == false`, scheduler пуст (AC-10).
4. Views: compact (`CompactSplit`: слева иконка батареи с заливкой/молнией, справа процент; цвет — `.orange` low, `.red` critical; крестик «скрыть» — `Button` внутри compact, не открывает expanded, т.к. кнопка перехватывает tap раньше контейнера), expanded (крупный индикатор, источник, время, статус, Low Power Mode, здоровье мелким шрифтом), settings (`Picker` порога 10/15/20/30, три `Toggle`). → AC-1, AC-13.
5. Ручная проверка + замер CPU по ADR-005.

## Соответствие AC → шаг
AC-1 → 4 (вручную); AC-2, AC-3, AC-4, AC-5, AC-6, AC-12, AC-13 → 2 (unit) + 5 (вручную); AC-7, AC-8, AC-11 → 1; AC-9, AC-10 → 3 + 5; TASK-002 AC-13 (настройки виджета на лету) — проверяется здесь впервые.

## Что проверить глазами
1. Процент в expanded совпадает с меню-баром macOS (±1%).
2. Вставить/вынуть кабель → в течение ~1 с peek с молнией/процентом на ~5 с; быстро дёргать кабель 3–4 раза — peek не мигает.
3. Low: выставить порог 30% при заряде ниже 30% на батарее — оранжевый peek висит постоянно; «×» скрывает и **не** открывает панель; подключить и отключить питание — снова появится.
4. Если есть Mac без батареи — «Батарея не обнаружена».
5. Включить «Режим энергосбережения» в Системных настройках — отражается в expanded.
6. CPU в простое ~0% (ADR-005), в `top` нет регулярных пробуждений от процесса.

## Риски и trade-offs
- Ключи AppleSmartBattery (`CycleCount`, `AppleRawMaxCapacity`, `DesignCapacity`) не документированы как стабильный контракт — читаются через публичный IORegistry API; отсутствие → поле скрыто. Это не приватный API, но значения могут меняться между моделями.
- Ключ «оптимизированная зарядка» может отсутствовать → статус просто «Не заряжается».
- Приоритет 80 < таймер 90: при идущем таймере low-peek не виден (принято в TASK-001).
