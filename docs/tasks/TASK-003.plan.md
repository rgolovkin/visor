# План реализации TASK-003: виджет «Календарь» (EventKit)

Спецификация: `docs/tasks/TASK-003.md`. Базовый план: `TASK-001.plan.md`. ADR: ADR-003 (actor вокруг `EKEventStore`, Sendable DTO, ленивые разрешения через `ActivationReason`/`visibilityDidChange`), ADR-005 (таймер на ближайший значимый момент).
Рекомендуемая очередь: 5-я задача.

## Архитектурное решение
```
CalendarWidget (@MainActor @Observable)
  ├─ access: CalendarAccess (.notDetermined/.granted/.denied/.restricted/.error)
  ├─ CalendarService (actor; единственный владелец EKEventStore — он не Sendable)
  │     events(in:calendarIDs:showDeclined:) -> [EventDTO] ; calendars() -> [CalendarDTO] ; requestAccess() -> Bool
  ├─ CalendarPeekPlanner (чистая): (events, now, settings) -> (activeEvent?, nextWake: Date?, needsMinuteTick)
  ├─ OneShotScheduler — один таймер на nextWake; минутный тик только пока событие в окне peek
  ├─ NotificationObservation(.EKEventStoreChanged) ; SystemEvents {wake, dayChanged, timeZoneChanged, clockChanged}
  └─ views: CalendarCompactView, CalendarExpandedView (MonthGridView + DayEventListView), CalendarSettingsView, access-состояния через WidgetMessageView
```
Почему actor: `EKEventStore` не `Sendable` и запросы событий могут занимать десятки мс на больших календарях; актор гарантирует, что store используется последовательно и **не на main thread** (НФТ спецификации), а наружу уходят только `Sendable`-структуры.

## Файлы
```
Widgets/Calendar/CalendarWidget.swift        — id "calendar", priority 70, symbolName "calendar"
Widgets/Calendar/CalendarService.swift       — actor
Widgets/Calendar/CalendarModels.swift        — EventDTO, CalendarDTO, RGBAColor, CalendarAccess
Widgets/Calendar/CalendarPeekPlanner.swift   — чистая логика peek и следующего пробуждения
Widgets/Calendar/MonthGrid.swift             — чистая генерация сетки месяца (firstWeekday, 6×7)
Widgets/Calendar/CalendarSettings.swift      — Codable
Widgets/Calendar/CalendarLinks.swift         — URL открытия события в Calendar.app и System Settings
Widgets/Calendar/CalendarViews.swift         — compact, expanded, settings
project.yml                                  — info.properties: NSCalendarsFullAccessUsageDescription
Resources/InfoPlist.xcstrings                — ru/en перевод описания доступа
Tests/Widgets/Calendar/CalendarPeekPlannerTests.swift, MonthGridTests.swift, EventSortingTests.swift, CalendarSettingsTests.swift
```

## Типы и сигнатуры
```swift
struct RGBAColor: Codable, Equatable, Sendable { let r, g, b, a: Double }
struct CalendarDTO: Equatable, Sendable { let id: String; let title: String; let color: RGBAColor }   // EKCalendar.calendarIdentifier
struct EventDTO: Equatable, Sendable, Identifiable {
    let id: String                 // eventIdentifier + startDate (у повторяющихся событий eventIdentifier общий)
    let eventIdentifier: String?
    let title: String              // "" → UI «Без названия» (AC-13)
    let location: String?
    let start: Date; let end: Date
    let isAllDay: Bool
    let calendarID: String; let color: RGBAColor
    let isDeclined: Bool           // attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
}
enum CalendarAccess: Equatable, Sendable { case notDetermined, granted, denied, restricted, error }

actor CalendarService {
    static func currentAccess() -> CalendarAccess                     // EKEventStore.authorizationStatus(for: .event): .fullAccess → granted, .writeOnly → denied
    func requestAccess() async throws -> Bool                          // store.requestFullAccessToEvents()
    func calendars() -> [CalendarDTO]
    func events(in interval: DateInterval, calendarIDs: Set<String>?, showDeclined: Bool) -> [EventDTO]   // predicateForEvents + events(matching:)
    func reset()                                                       // store.reset() после EKEventStoreChanged
}

struct CalendarPeekPlan: Equatable, Sendable { let active: EventDTO?; let nextWake: Date?; let minuteTick: Bool }
enum CalendarPeekPlanner {
    static func plan(events: [EventDTO], now: Date, leadMinutes: Int, showAllDay: Bool, calendar: Calendar) -> CalendarPeekPlan
}
enum MonthGrid { static func days(for month: Date, firstWeekday: Int, calendar: Calendar) -> [GridDay] }   // 42 ячейки
enum EventSorting { static func dayList(_ events: [EventDTO], day: Date, calendar: Calendar) -> [EventDTO] } // allDay сверху, затем start (AC-3); многодневные попадают в каждый день

struct CalendarSettings: Codable, Equatable, Sendable {
    var peekLeadMinutes = 15            // 5/10/15/30
    var calendars: [String]? = nil      // nil = все (AC-9); удалённые id игнорируются
    var showAllDay = false
    var firstWeekday: String = "system" // "system" | "monday" | "sunday"
    var showDeclined = false
}
```

### Правила `CalendarPeekPlanner` (основа тестов)
- Кандидат: не allDay (если `!showAllDay`), не declined (если `!showDeclined`), и `start - lead <= now < min(start + 5 мин, end)`.
- Из кандидатов — с наименьшим `start` (идущее раньше предстоящего, AC-6).
- `nextWake` = минимальное из будущих моментов: `start - lead`, `start`, `start + 5 мин`, `end` (по всем событиям в горизонте) и ближайшая полночь.
- `minuteTick = active != nil && now < active.start` (текст «через N мин» меняется раз в минуту; в «идёт» тика не нужно).
- Событие короче 5 мин → гаснет по `end` (AC-5).

### Обновление (без опроса)
- Диапазон запроса: видимый месяц ± 7 дней (НФТ) + отдельно «сегодня..+1 день» для peek, если видимый месяц не текущий.
- Триггеры перезапроса: `EKEventStoreChanged` (через `NotificationObservation`, коалесцирование 500 мс → ≤ 2 с, AC-7), `SystemEvents.wake/dayChanged/timeZoneChanged/clockChanged` (AC-10, AC-11), смена настроек, навигация по месяцам.
- После каждого перезапроса — `plan` → `isActive = plan.active != nil` → `scheduler.schedule(at: plan.nextWake, tolerance: .seconds(1))`. Минутный тик — `OneShotScheduler` на следующую границу минуты, только при `minuteTick`.
- `deactivate()`: отмена scheduler, снятие всех observations, `service = nil` (AC-12).

### Разрешения (ленивые, AC-1)
- `activate(.launch)`: если `currentAccess() == .granted` — загрузка; если `.notDetermined` — **ничего не запрашиваем**, вкладка покажет карточку «Нужен доступ».
- `activate(.userEnabled)` или `visibilityDidChange(.expanded)` при `.notDetermined` → `requestAccess()` (один раз за сессию, флаг).
- `.denied/.restricted` → `WidgetMessageView` + кнопка `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)` (AC-8). Отзыв доступа во время работы — на `EKEventStoreChanged` перепроверяем статус.
- В `project.yml` → `info.properties`: `NSCalendarsFullAccessUsageDescription: "NotchApp показывает ваши ближайшие события в чёлке. Данные не покидают Mac."` (en-исходник + ru в `InfoPlist.xcstrings`). Только Full Access (Q5); hardened runtime: для EventKit вне sandbox entitlement `com.apple.security.personal-information.calendars` **требуется при включённом Hardened Runtime** — добавить в `entitlements.properties` в project.yml.

### UI
- Expanded 520×200: слева месячная сетка (заголовок 20 pt + дни недели 14 pt + 6 строк × 22 pt = 166 pt ≤ 200 − отступы), ширина ~230 pt; справа список дня (`ScrollView`, лимит 200 элементов + «и ещё N»). Расчёт показывает, что сетка помещается — недельная полоса (fallback из Q1) **не реализуется**, если ручная проверка подтвердит читаемость; иначе — отдельный шаг 6b.
- Навигация ‹ › / «Сегодня», подсветка сегодня, точки у дней с событиями (не более 1 точки на день), идущее событие подсвечено.
- Compact: `CompactSplit` — слева цветная точка + название (`lineLimit(1)`), справа «через N мин» / «идёт». Expanded: название `lineLimit(2)`.
- Клик по событию: `CalendarLinks.eventURL(eventIdentifier)` = `ical://ekevent/<eventIdentifier>?method=show&options=more` → `NSWorkspace.shared.open`; если `open` вернул false или id нет → открыть Calendar.app (`NSWorkspace.shared.openApplication(at:configuration:)` по bundle id `com.apple.iCal`) (AC-14).

## Шаги реализации
1. Модели, `CalendarSettings`, `MonthGrid`, `EventSorting` + тесты (firstWeekday пн/вс/системный, 6 строк, многодневные события в каждом дне, all-day сверху). → AC-2, AC-3 (логика).
2. `CalendarPeekPlanner` + тесты (окно lead; «идёт» 5 мин; короткое событие; пересекающиеся; nextWake включает полночь; declined/allDay фильтры). → AC-4, AC-5, AC-6.
3. Info.plist-ключ, entitlement, `InfoPlist.xcstrings`; `CalendarService` actor. Проверка: `make build`, `plutil -p build/Build/Products/Debug/NotchApp.app/Contents/Info.plist | grep Calendars`.
4. `CalendarWidget`: права, загрузка, observers, scheduler, регистрация в каталоге. Тест: `deactivate` → нет observation/scheduler (AC-12); `activate(.launch)` при notDetermined не вызывает `requestAccess` (через протокол-шов `CalendarAccessProviding`, фейк в тестах) (AC-1).
5. Views (compact, expanded, состояния доступа, settings со списком календарей-чекбоксов). → AC-8, AC-9, AC-13, AC-14.
6. Ручная проверка + CPU.

## Соответствие AC → шаг
AC-1 → 4 + 6; AC-2, AC-3 → 1 + 5; AC-4, AC-5, AC-6 → 2; AC-7, AC-10, AC-11 → 4 + 6; AC-8 → 5; AC-9 → 1 + 5; AC-12 → 4; AC-13, AC-14 → 5.

## Что проверить глазами
1. Сбросить разрешение: `tccutil reset Calendar dev.visor.NotchApp`. Запустить — диалога **нет**. Открыть вкладку «Календарь» — системный диалог.
2. Отказать → инструкция + кнопка открывает «Конфиденциальность → Календари».
3. Создать в Calendar.app событие через 10 мин → ≤ 2 с peek «через 10 мин», меняется раз в минуту; при начале — «идёт», через 5 мин гаснет.
4. Сетка: сегодня выделен, точки у дней с событиями; ‹ › и «Сегодня»; сетка читаема в 520×200 (если нет — сообщить, включим недельную полосу).
5. Клик по событию → Calendar.app открылся на нём (или хотя бы открылся).
6. Сменить часовой пояс в Системных настройках → список и «сегодня» пересчитались.
7. CPU в простое ~0%.

## Риски и trade-offs
- `ical://ekevent/...` — недокументированная схема; при отказе открываем Calendar.app **без перехода на дату** (переход на дату требует AppleScript и разрешения Automation — новое разрешение, не вводим). Отклонение от AC-14 «или на дате» — частичное, зафиксировано.
- Entitlement календаря при Hardened Runtime: без него запрос доступа молча вернёт отказ — проверка в шаге 3/6.
- Отзыв доступа во время работы: macOS может перезапустить процесс — это ок, состояние восстанавливается при старте.
