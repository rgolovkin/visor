# План реализации TASK-004: виджет «Таймер» (таймер + Pomodoro)

Спецификация: `docs/tasks/TASK-004.md`. Базовый план: `TASK-001.plan.md`. ADR: ADR-002 (data/timer.json), ADR-004 (ввод длительности через `NotchTextField`), ADR-005 (тик 1 Гц только в running).
Рекомендуемая очередь: 4-я задача. **Здесь впервые выполняется ручная проверка TASK-001 AC-22** (ввод текста в чёлке).

## Архитектурное решение

### Время: монотонные часы в памяти, wall-clock на диске
- Во время работы приложения конец отсчёта хранится как `ContinuousClock.Instant`. `ContinuousClock` на macOS — `mach_continuous_time`: **идёт во время сна** и **не зависит от ручной смены системного времени/NTP**. Это одновременно закрывает AC-4 (сон 10 мин), AC-5 (дрейф), AC-15 (смена времени).
- `ContinuousClock` обнуляется при перезагрузке, поэтому на диск пишем wall-clock `endsAt` (ISO-8601) + `remainingSeconds` для паузы. При восстановлении (AC-11): `remaining = endsAt - Date()`; это единственная возможная точка, где используется wall-clock.
- Для тестируемости движок не зовёт часы сам: все функции принимают `now: Monotonic` (`Double` секунд от произвольной точки) и `wallNow: Date`. Адаптер `TimerClock` (`ContinuousClock.now` → секунды) — тонкий слой в виджете.

```
expanded UI ─intents─► TimerWidget (@MainActor @Observable) ─► CountdownEngine (чистая) + PomodoroCycle (чистая)
                              │  tickTask (1 Гц, только running) ; finishTask (one-shot на endsAt)
                              │  SystemEvents.wake → reconcile()
                              ├─► TimerStateFile (data/timer.json, запись на смену состояния, ADR-002)
                              └─► TimerAlerts: NSSound(named: "Glass"), UNUserNotificationCenter (опционально)
```

## Файлы
```
Widgets/Timer/TimerWidget.swift            — id "timer", priority 90, symbolName "timer"
Widgets/Timer/CountdownEngine.swift        — чистый движок idle/running/paused/finished
Widgets/Timer/PomodoroCycle.swift          — чистая логика фаз и статистики
Widgets/Timer/DurationParser.swift         — разбор "ЧЧ:ММ:СС" / "ММ:СС" / "М"
Widgets/Timer/TimerSettings.swift          — Codable (вложенный pomodoro.*)
Widgets/Timer/TimerStateFile.swift         — DTO timer.json + VersionedJSONFile
Widgets/Timer/TimerAlerts.swift            — звук и уведомления
Widgets/Timer/TimerViews.swift             — compact, expanded (режимы), settings
Window/TextInput/NotchTextField.swift      — используется (создан в TASK-001)
project.yml                                — нет новых ключей Info.plist (UNUserNotificationCenter не требует usage description)
Tests/Widgets/Timer/CountdownEngineTests.swift, PomodoroCycleTests.swift, DurationParserTests.swift, TimerRestoreTests.swift, TimerSettingsTests.swift
```

## Типы и сигнатуры
```swift
typealias Monotonic = Double   // секунды ContinuousClock

struct CountdownEngine: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, running(endsAt: Monotonic), paused(remaining: Double), finished }
    private(set) var phase: Phase
    private(set) var total: Double
    mutating func start(duration: Double, now: Monotonic)
    mutating func pause(now: Monotonic)
    mutating func resume(now: Monotonic)
    mutating func reset()
    mutating func addMinute(now: Monotonic)                    // из finished → running 60 с (AC-3)
    mutating func reconcile(now: Monotonic) -> Bool            // true, если только что перешёл в finished (звук ровно 1 раз)
    func remaining(now: Monotonic) -> Double
    func progress(now: Monotonic) -> Double
}

struct PomodoroCycle: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case work, shortBreak, longBreak }
    private(set) var kind: Kind
    private(set) var completedWorkInCycle: Int            // для ●●○○
    private(set) var todayCompleted: Int
    private(set) var todayDate: String                     // yyyy-MM-dd локальная дата
    mutating func advance(completed: Bool, settings: PomodoroSettings, today: String)   // completed=false при «Пропустить» (AC-8)
    func duration(settings: PomodoroSettings) -> Double    // снапшот длительности берётся при старте фазы (AC-9)
}

enum DurationParser { static func parse(_ text: String) -> Result<Int, DurationError> }  // 1...359_999 с (99:59:59), иначе .outOfRange/.invalid (AC-12)

struct TimerSettings: Codable, Equatable, Sendable {
    var pomodoro = PomodoroSettings()     // workMinutes 25, shortBreakMinutes 5, longBreakMinutes 15, sessionsBeforeLongBreak 4, autoStartNext false
    var sound: String? = "Glass"          // nil → выкл
    var notifyOnFinish = false
    var lastTimerSeconds = 300
}

struct TimerStateDTO: Codable, Sendable {           // data/timer.json
    var schemaVersion = 1
    var mode: String                                  // "timer" | "pomodoro"
    var status: String                                // "idle" | "running" | "paused" | "finished"
    var endsAt: Date?                                 // ISO-8601, при running
    var remainingSeconds: Double?                     // при paused
    var totalSeconds: Double
    var finishedAt: Date?                             // при finished
    var pomodoro: PomodoroDTO?                        // kind, completedWorkInCycle, todayCompleted, todayDate
}

@MainActor @Observable final class TimerWidget: NotchWidget {
    enum Mode: String, Sendable { case timer, pomodoro }
    private(set) var mode: Mode
    private(set) var engine: CountdownEngine
    private(set) var cycle: PomodoroCycle
    private(set) var displayRemaining: Int           // обновляется тиком, читают view
    var pendingModeSwitch: Mode?                      // для InlineConfirmView (AC-10)
    var isActive: Bool { engine.phase != .idle }      // running/paused/finished
    var deactivationWarning: String? { isActive ? String(localized: "Остановить текущий отсчёт?") : nil }  // TASK-001/002, AC-13
    func startTimer(seconds: Int); func pause(); func resume(); func reset(); func addMinute(); func acknowledge()
    func startPomodoro(); func skipPhase()
    func requestModeSwitch(_ mode: Mode)
}
```

### Правила (основа тестов)
- Тик: `tickTask` — цикл `Task.sleep(until: следующая граница целой секунды остатка, tolerance: .milliseconds(100))`, обновляет `displayRemaining`; существует **только** в `running` (AC-13, ADR-005). В `paused/finished/idle` задач нет.
- Окончание: `finishTask` — `Task.sleep` до `endsAt` (независимо от тика; срабатывает и в collapsed). На `SystemEvents.wake` → `reconcile` → если просрочено, ровно один `finished` + один звук (AC-4).
- Pomodoro: по окончании фазы → звук, `cycle.advance(completed: true)`; если `autoStartNext` — сразу `start` следующей фазы, иначе `idle` с подготовленной фазой (кнопка «Старт»). Длинный перерыв после `sessionsBeforeLongBreak` рабочих; после длинного `completedWorkInCycle = 0` (AC-6, AC-7). Статистика: `todayCompleted` сбрасывается при смене `todayDate`.
- Одновременно один отсчёт: старт другого режима при `isActive` → `pendingModeSwitch` → `InlineConfirmView` «Остановить текущий?» (AC-10).
- Восстановление (AC-11), функция `TimerRestore.restore(dto:wallNow:monotonicNow:) -> (engine, mode, cycle, playSound: Bool)`: running и `endsAt > now` → running с `remaining = endsAt - now`; просрочено ≤ 5 мин → finished + звук один раз; > 5 мин → idle без звука; paused → paused; битый/новее schemaVersion файл → idle (ADR-002).
- Запись `timer.json`: синхронно (через `AtomicFile`) на каждый переход состояния, не на тик (НФТ). `flush()` — повторная запись текущего состояния (Quit).
- Выключение во время отсчёта: настройки показывают подтверждение по `deactivationWarning`; `deactivate()` → `reset()`, запись idle, отмена задач (AC-13).
- Уведомления (AC-14): при включении `notifyOnFinish` в настройках → `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`; отказ → опция возвращается в false, под ней текст-пояснение. Отправка — `UNNotificationRequest` с `trigger: nil` в момент finished. Звук и уведомления подчиняются Focus/DND системно.
- Ввод длительности: `NotchTextField` (ADR-004) с плейсхолдером «ЧЧ:ММ:СС»; невалидно → подсказка, «Старт» `.disabled` (AC-12). Пресеты — кнопки 1/5/10/15/30 мин.
- Кольцо прогресса: `Circle().trim(from: 0, to: progress)` с `.animation(.linear(duration: 1), value: displayRemaining)` — анимация между тиками, без 60-fps таймера (НФТ).

## Шаги реализации
1. `DurationParser` + тесты (0, отрицательное, 100:00:00, буквы, «5», «5:00», «1:00:00»). → AC-12.
2. `CountdownEngine` + тесты (start/pause/resume/reset; `reconcile` возвращает true ровно один раз; дрейф: 600 «тиков» с jitter → remaining по `endsAt`; addMinute). → AC-2, AC-3, AC-4, AC-5, AC-15 (логика).
3. `PomodoroCycle` + `TimerSettings` + тесты (4 сессии → long; skip не засчитан; смена настроек посреди фазы не меняет её длительность; смена дня сбрасывает счётчик). → AC-6..9.
4. `TimerStateFile` + `TimerRestore` + тесты (все ветки AC-11, битый файл → idle). → AC-11.
5. `TimerWidget` (без UI): задачи тика/окончания, wake, запись файла, регистрация в каталоге. Тесты: после `startTimer` есть tickTask; после `pause` — нет; `deactivate` → нет задач, файл idle (AC-13).
6. `TimerAlerts` + views (compact: `CompactSplit` — слева иконка `timer`/томат 🍅 как SF Symbol `leaf`/кастом, справа `мм:сс` + мини-кольцо; paused — приглушённо; finished — акцентный цвет и «Готово»; expanded: сегмент «Таймер/Pomodoro», пресеты, поле, кнопки, кольцо, ●●○○; settings: длительности `Stepper`, звук `Picker` из `NSSound` системных имён + «Выкл», `notifyOnFinish`). → AC-1, AC-3, AC-14.
7. Ручная проверка, включая **AC-22 из TASK-001**, замер CPU при идущем таймере (< 1%) и в idle.

## Соответствие AC → шаг
AC-1 → 6; AC-2, AC-3, AC-5 → 2 + 7; AC-4 → 2 + 7; AC-6..9 → 3; AC-10 → 5–6; AC-11 → 4; AC-12 → 1 + 6; AC-13 → 5 + TASK-002 подтверждение; AC-14 → 6; AC-15 → 2 (монотонные часы) + 7.

## Что проверить глазами
1. 5:00 → «Старт»: в peek сразу остаток, уменьшается каждую секунду; кольцо плавно.
2. Пауза/Старт/Сброс — peek гаснет после «Сброс».
3. Таймер 0:05 → звук «Glass», peek «Готово», висит до «Готово»/«+1 мин».
4. Запустить 3 мин, закрыть крышку на 5 мин → при открытии сразу «Готово», звук один раз.
5. Запустить таймер, Quit, запустить снова → остаток корректен.
6. Во время отсчёта сменить системное время на +1 час вручную → остаток не прыгает.
7. **AC-22 (TASK-001) и ввод**: навести на чёлку, кликнуть в поле длительности, ввести «1:30» — символы появляются; увести курсор — панель **не** закрывается; кликнуть в другое приложение — поле теряет фокус, панель сворачивается через ~0.3 с; фокус клавиатуры у того приложения. ⌘A/⌘C/⌘V в поле работают. Во время hover без клика в поле печать в другом приложении не прерывается.
8. Pomodoro: на время теста выставить работу 1 мин/перерыв 1 мин → переходы фаз, ●●○○, «Пропустить».
9. CPU: при идущем таймере < 1%, в idle ~0% (ADR-005).

## Риски и trade-offs
- `UNUserNotificationCenter` у ad-hoc подписанной Debug-сборки может не показывать уведомления — проверять с подписанной сборкой; на остальную функциональность не влияет.
- Восстановление после перезагрузки опирается на wall-clock (`ContinuousClock` не переживает reboot) — ручная смена времени между запуском и перезапуском даст сдвиг; принято.
- Иконка «томат» — SF Symbols не содержит томата; используем нейтральный символ (`leaf.fill`/`flame`) — продуктовое решение на ревью UI.
