# План реализации TASK-008: виджет «Системный монитор» (CPU / RAM / сеть / диск)

Спецификация: `docs/tasks/TASK-008.md`. Базовый план: `TASK-001.plan.md`. ADR: ADR-005 (сэмплирование только при видимости — критично), ADR-003 (actor для сэмплера, глобальные C-переменные в Swift 6).
Рекомендуемая очередь: 7-я задача.

## Архитектурное решение
```
visibilityDidChange(.expanded) ─┐
peekMode == onThreshold ────────┼─► SysmonWidget (@MainActor @Observable) ── samplingTask (единственный цикл) ──► SystemSampler (actor)
SystemEvents.wake → discardNext ┘        режим: .foreground(refreshSeconds, metrics) | .background(5 с, [cpu, memory]) | .off
                                          │ публикует SystemSnapshot (Sendable) → RingBuffer(60) для CPU и сети
                                          └ ThresholdDetector (чистая) → isActive
```
- **Нет видимости и `peekMode == never` → `.off`: нет задачи, нет сэмплов** (AC-1). Переключение режимов при каждом `visibilityDidChange` и смене настроек; старая задача отменяется до запуска новой → нет утечки таймеров при быстрых переключениях вкладок.
- Почему `actor` для сэмплера: Mach/sysctl-вызовы синхронные, хранят предыдущие счётчики (состояние для дельт) — актор держит это состояние изолированно и уводит работу с main thread; на `@MainActor` публикуются только готовые значения (AC-13).

## Файлы
```
Widgets/SystemMonitor/SysmonWidget.swift        — id "sysmon", priority 30, symbolName "gauge.with.dots.needle.33percent"
Widgets/SystemMonitor/SystemSampler.swift       — actor, дельты и базовые линии
Widgets/SystemMonitor/MachStats.swift           — обёртки host_statistics/host_statistics64/sysctl (nonisolated функции)
Widgets/SystemMonitor/NetworkCounters.swift     — sysctl NET_RT_IFLIST2 → if_data64 по интерфейсам
Widgets/SystemMonitor/DiskStats.swift           — URLResourceValues системного тома
Widgets/SystemMonitor/SysmonMath.swift          — чистые: cpuPercent(from:to:), byteRate(prev:cur:dt:), memoryUsed(...)
Widgets/SystemMonitor/RingBuffer.swift          — generic, capacity 60
Widgets/SystemMonitor/ThresholdDetector.swift   — чистый: 10 с подряд ≥ порога, гистерезис 5 п.п.
Widgets/SystemMonitor/SysmonSettings.swift      — Codable
Widgets/SystemMonitor/SysmonViews.swift         — 4 карточки, мини-графики (Path), compact, settings
Tests/Widgets/SystemMonitor/SysmonMathTests.swift, RingBufferTests.swift, ThresholdDetectorTests.swift, InterfaceFilterTests.swift, SysmonModeTests.swift
```

## Типы и сигнатуры
```swift
enum SysmonMetric: String, Codable, CaseIterable, Sendable { case cpu, memory, network, disk }
struct CPUTicks: Sendable, Equatable { let user, system, idle, nice: UInt64 }
struct NetCounters: Sendable, Equatable { let rx, tx: UInt64; let at: Double /* монотонные секунды */ }
struct MemoryStats: Sendable, Equatable { let usedBytes, totalBytes, swapUsedBytes: UInt64; let pressure: MemoryPressure? }
enum MemoryPressure: Sendable { case normal, warning, critical }
struct DiskStats: Sendable, Equatable { let totalBytes, availableBytes: Int64 }
struct SystemSnapshot: Sendable, Equatable {
    let cpuPercent: Double?; let memory: MemoryStats?; let netRxPerSec: Double?; let netTxPerSec: Double?; let disk: DiskStats?
}  // nil у метрики → «—» на карточке (AC-10)

actor SystemSampler {
    func sample(_ metrics: Set<SysmonMetric>, includeDisk: Bool) -> SystemSnapshot
    func primeBaseline(_ metrics: Set<SysmonMetric>)       // снять счётчики без публикации
    func invalidateBaseline()                              // после сна (AC-12)
    var baselineAge: Double? { get }
}
enum SysmonMath {
    static func cpuPercent(from: CPUTicks, to: CPUTicks) -> Double?          // nil, если дельта total == 0
    static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double   // current < previous → 0 (сброс/переполнение, AC-5)
    static func memoryUsed(internal: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64) -> UInt64
}
enum InterfaceFilter { static func isCounted(name: String, flags: UInt32) -> Bool }
struct RingBuffer<Element: Sendable>: Sendable { init(capacity: Int); mutating func append(_:); var elements: [Element]; mutating func removeAll() }
struct ThresholdDetector: Sendable { init(threshold: Double, hysteresis: Double = 5, requiredSeconds: Double = 10); mutating func feed(value: Double, at: Double) -> Bool }

struct SysmonSettings: Codable, Equatable, Sendable {
    var refreshSeconds = 2               // 1/2/5
    var show: [SysmonMetric] = SysmonMetric.allCases
    var peekMode = "never"               // "never" | "onThreshold"
    var cpuThresholdPercent = 90
    var networkUnit = "bytes"            // "bytes" | "bits"
}
```

### Источники метрик (только публичные API, без внешних процессов)
- **CPU (сумма)**: `host_statistics(host, HOST_CPU_LOAD_INFO, ...)` → `host_cpu_load_info` (тики user/system/idle/nice); процент = (Δuser+Δsystem+Δnice)/Δtotal. Не требует `vm_deallocate`. P/E-ядра суммируются автоматически.
  Per-core (опционально по спецификации) — `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` требует `vm_deallocate(mach_task_self_, ...)`; `mach_task_self_` — глобальная C-переменная → ошибка Swift 6 concurrency. **В этой итерации per-core не делаем** (опция спецификации), чтобы не вводить `nonisolated(unsafe)`; при согласовании — отдельным шагом.
- **Память**: `host_statistics64(host, HOST_VM_INFO64, ...)` → `vm_statistics64`; «используется» как в Activity Monitor = (internal − purgeable) + wired + compressor, × `UInt64(getpagesize())` (не `vm_kernel_page_size` — глобальная переменная, ошибка Swift 6). Всего — `ProcessInfo.processInfo.physicalMemory`. Давление — `sysctlbyname("kern.memorystatus_vm_pressure_level")` (1/2/4 → normal/warning/critical; иначе nil → только процент). Swap — `sysctlbyname("vm.swapusage")` → `xsw_usage.xsu_used`.
- **Сеть**: `sysctl([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0])` → записи `RTM_IFINFO2` с `if_msghdr2.ifm_data` (`if_data64`, **64-битные счётчики** `ifi_ibytes/ifi_obytes`). Это снимает проблему переполнения 32-битных счётчиков `getifaddrs` (AC-5); отрицательная дельта (сброс интерфейса) → 0.
  Правило интерфейсов (зафиксировано): учитываются только имена `^en[0-9]+$` с флагами `IFF_UP && IFF_RUNNING` и `!IFF_LOOPBACK`. Исключаются `lo*`, `utun*`, `ipsec*`, `awdl*`, `llw*`, `bridge*`, `vmenet*`, `anpi*`, `ap*`, `gif*`, `stf*` — это туннели/виртуальные/служебные, их трафик дублирует физический (VPN поверх Wi-Fi). Сумма по всем подходящим `en*`.
- **Диск**: `URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])` — «доступно» как в Finder (учитывает purgeable). Форматирование `ByteCountFormatter` `.file` (десятичные ГБ, AC-6). Обновление — не чаще раза в 30 с при видимости.
- `mach_host_self()` вызывается один раз в `init` актора и кэшируется (каждый вызов создаёт send right).

### Цикл сэмплирования (SysmonWidget)
```
mode = (visibility == .expanded) ? .foreground : (settings.peekMode == "onThreshold" ? .background : .off)
start(mode):
  samplingTask?.cancel()
  guard mode != .off
  samplingTask = Task { @MainActor in
     if sampler.baselineAge == nil || age > 2×interval { await sampler.primeBaseline(); try await Task.sleep(for: .milliseconds(500)) }  // AC-3: первое значение ≤ 1 с, без «прыжка от нуля»
     while !Task.isCancelled {
        let snap = await sampler.sample(metricsFor(mode), includeDisk: diskDue)
        if discardNext { discardNext = false } else { publish(snap) }      // AC-12
        try await Task.sleep(for: interval, tolerance: interval * 0.2)
     }
  }
```
- Foreground: метрики = включённые карточки `show` (AC-9: выключенные не собираются); интервал `refreshSeconds`.
- Background: только `cpu`(+`memory` для давления), интервал 5 с (AC-8); графики не наполняются.
- Остановка ≤ 1 тика: отмена задачи прерывает `Task.sleep` немедленно (AC-3).
- `deactivate()`: отмена задачи, `buffers.removeAll()`, `sampler` освобождается (AC-4, AC-11).
- Сон: `SystemEvents.wake` → `discardNext = true` + `await sampler.invalidateBaseline()` (AC-12).
- Peek (AC-7): `ThresholdDetector.feed` по CPU (и `pressure == .critical` как отдельное условие «≥ 10 с подряд») → `isActive`; compact — иконка + «CPU 94%»/«Память: критично».

### UI
- 4 карточки в `Grid` 2×2 (или ряд при меньшем числе) в 520×200; мини-график — `Path` по 60 точкам (без анимации, перерисовка раз в интервал).
- Единицы сети: `bytes` → КБ/с–МБ/с (`ByteCountFormatter` `.file` + «/с»), `bits` → ×8, Кбит/с–Мбит/с.

## Шаги реализации
1. `SysmonMath`, `RingBuffer`, `ThresholdDetector`, `InterfaceFilter`, `SysmonSettings` + тесты (дельты CPU; отрицательная дельта сети → 0; кольцевой буфер держит 60 последних; порог: 9 с — нет, 10 с — да, выход только ниже порог − 5; фильтр: en0 да, utun3/awdl0/lo0/bridge100 нет). → AC-4, AC-5, AC-7 (логика).
2. `MachStats`, `NetworkCounters`, `DiskStats`, `SystemSampler` (actor). Тест-интеграция (реальная машина, мягкие проверки): CPU в 0...100, память used ≤ total, disk available ≤ total. → AC-2, AC-6, AC-10.
3. `SysmonWidget`: выбор режима, цикл, wake, регистрация в каталоге. Тесты `SysmonModeTests` (через протокол-шов `SamplerProtocol` с фейковым актором): `.hidden + never` → нет задачи; `.expanded` → задача; переключение вкладок 20 раз подряд → активна ровно одна задача; `deactivate` → буферы пусты. → AC-1, AC-3, AC-9, AC-11, AC-13.
4. Views + settings. → AC-2, AC-6, AC-9.
5. Ручная проверка, **замеры CPU** (ключевые для задачи).

## Соответствие AC → шаг
AC-1 → 3 + 5; AC-2 → 2 + 5; AC-3 → 3; AC-4 → 1 + 3; AC-5 → 1; AC-6 → 2 + 5; AC-7 → 1 + 3; AC-8 → 3 + 5; AC-9 → 3 + 4; AC-10 → 2; AC-11 → 3; AC-12 → 3; AC-13 → 2 + 3.

## Что проверить глазами
1. Виджет включён, панель закрыта, `peekMode=never`: 60 с `top -pid $(pgrep -x NotchApp) -stats pid,cpu,idlew` — CPU ~0, idle wakeups не растут каждые 2 с.
2. Открыть вкладку «Монитор»: значения каждые 2 с; сравнить с Activity Monitor (CPU ±5 п.п., память ±3%). Нагрузить CPU: `yes > /dev/null &` (×N ядер) — растёт; `killall yes`.
3. Скачать большой файл — сеть показывает скорость; включить VPN — скорость не удваивается.
4. Диск — совпадает с Finder (⌘I на «Macintosh HD»), ±1%.
5. Закрыть панель → в `top` CPU сразу падает до ~0.
6. `peekMode=onThreshold`, нагрузить CPU на 15 с → peek; снять нагрузку → гаснет.
7. Сон 1–2 мин → открыть вкладку → на графике нет пика/провала.
8. При открытой вкладке с интервалом 1 с CPU приложения < 2% одного ядра.

## Риски и trade-offs
- Per-core CPU не реализуется в этой итерации (опциональная часть спецификации) — из-за `mach_task_self_` в Swift 6; решение можно пересмотреть отдельной задачей.
- `kern.memorystatus_vm_pressure_level` — sysctl без формальной документации; при отказе — только процент (предусмотрено спецификацией).
- `NET_RT_IFLIST2` — стабильный публичный sysctl (используется `netstat`), но разбор буфера требует аккуратной работы с `UnsafeRawPointer` — обязательное ревью и тест на реальной машине.
