# План реализации TASK-007: виджет «Погода» (Open-Meteo)

Спецификация: `docs/tasks/TASK-007.md`. Базовый план: `TASK-001.plan.md`. ADR: ADR-002 (weather-cache.json), ADR-003 (`Sendable`-клиент, сеть вне main), ADR-004 (поиск города в expanded через `NotchTextField`), ADR-005 (без фонового опроса при `peekMode=never`).
Рекомендуемая очередь: 8-я (последняя) задача.

## Архитектурное решение
```
WeatherWidget (@MainActor @Observable)
  ├─ state: .noLocation | .loading(cached?) | .loaded(WeatherData, age) | .offline(cached?) | .failed(cached?)
  ├─ WeatherClient (struct, Sendable; единственное место знания об Open-Meteo — замена провайдера не трогает UI)
  │     search(name:language:) async throws -> [GeoPlace]
  │     forecast(for: WeatherLocation, units: WeatherUnits, days: Int) async throws -> WeatherData
  ├─ WeatherCacheFile (data/weather-cache.json, ADR-002)
  ├─ WeatherRefreshPolicy (чистая): shouldFetch / nextRefreshDate / backoff
  ├─ OneShotScheduler — только при peekMode ≠ never (момент устаревания)
  ├─ NetworkReachability (NWPathMonitor) — только при peekMode ≠ never
  └─ SystemEvents.wake → refreshIfStale
```
Почему `struct WeatherClient: Sendable` с `async`-методами, а не актор: у клиента нет изменяемого состояния; `URLSession.data(for:)` сам выполняется вне main actor, декодирование — в том же `nonisolated async`-контексте; на `@MainActor` возвращается готовый `Sendable` `WeatherData`.

## Файлы
```
Widgets/Weather/WeatherWidget.swift          — id "weather", priority 20, symbolName "cloud.sun"
Widgets/Weather/WeatherClient.swift          — URL-построение, URLSession, DTO Open-Meteo, маппинг в WeatherData
Widgets/Weather/WeatherModels.swift          — WeatherLocation, WeatherUnits, WeatherData, HourPoint, DayPoint, GeoPlace
Widgets/Weather/WMOCode.swift                — код → (локализованный текст, SF Symbol день/ночь); неизвестный → «—» + "questionmark" нейтрально
Widgets/Weather/WeatherRefreshPolicy.swift   — чистая логика
Widgets/Weather/WeatherCacheFile.swift       — формат кеша
Widgets/Weather/NetworkReachability.swift    — обёртка NWPathMonitor
Widgets/Weather/WeatherSettings.swift        — Codable
Widgets/Weather/WeatherViews.swift           — поиск, текущая, почасовая полоса, дни, атрибуция, compact, settings
Tests/Widgets/Weather/WeatherClientURLTests.swift, WeatherDecodingTests.swift (фикстуры JSON), WMOCodeTests.swift, WeatherRefreshPolicyTests.swift, WeatherCacheTests.swift, WeatherSettingsTests.swift
Tests/Fixtures/openmeteo-forecast.json, openmeteo-geocoding.json, openmeteo-partial.json
```

## Типы и сигнатуры
```swift
struct WeatherLocation: Codable, Equatable, Sendable { var name, country: String; var admin1: String?; var latitude, longitude: Double; var timezone: String
    var cacheKey: String { String(format: "%.4f,%.4f", latitude, longitude) } }
struct WeatherUnits: Codable, Equatable, Sendable { var temperature: String /* "celsius"|"fahrenheit" */; var wind: String /* "kmh"|"ms"|"mph" */ }
struct WeatherData: Codable, Equatable, Sendable {
    var current: Current?; var hourly: [HourPoint]; var daily: [DayPoint]; var timezone: String; var utcOffsetSeconds: Int
    struct Current: Codable, Equatable, Sendable { var temperature, apparent: Double?; var humidity: Double?; var windSpeed: Double?; var code: Int?; var isDay: Bool? }
}  // все поля опциональны → частичный ответ показывается частично (AC-11)
struct GeoPlace: Equatable, Sendable, Identifiable { let id: Int; let name: String; let admin1: String?; let country: String?; let latitude, longitude: Double; let timezone: String? }

struct WeatherClient: Sendable {
    static let forecastHost = "api.open-meteo.com"
    static let geocodingHost = "geocoding-api.open-meteo.com"
    init(session: URLSession = .weather)     // ephemeral, urlCache = nil, timeoutIntervalForRequest = 10 (AC-6), без cookies
    func search(name: String, language: String) async throws -> [GeoPlace]
    func forecast(for: WeatherLocation, units: WeatherUnits, days: Int) async throws -> WeatherData
    static func forecastURL(_ loc: WeatherLocation, units: WeatherUnits, days: Int) -> URL   // чистая, тестируемая (AC-14)
    static func searchURL(name: String, language: String) -> URL
}
enum WeatherError: Error, Sendable { case offline, timeout, rateLimited, server(Int), decoding, notFound }

struct WeatherRefreshPolicy: Equatable, Sendable {
    var fetchedAt: Date?; var backoffUntil: Date?; var backoffStep: Int
    func shouldFetch(now: Date, refreshMinutes: Int, force: Bool) -> Bool   // кеш моложе → false (AC-5); в backoff → false даже при force (AC-7)
    func nextRefresh(refreshMinutes: Int) -> Date?
    mutating func recordSuccess(at: Date)
    mutating func recordFailure(_ error: WeatherError, at: Date)            // 429/5xx/decoding: 5 → 10 → 20 → 30 мин (cap); offline: без backoff, ждём NWPath
}

struct WeatherSettings: Codable, Equatable, Sendable {
    var location: WeatherLocation? = nil
    var units: String = "system"         // "system" | "metric" | "imperial"; system → Locale.current.measurementSystem == .us ? imperial : metric (Q3)
    var windUnit: String = "kmh"         // "kmh" | "ms" (для metric); imperial → mph
    var peekMode: String = "never"       // "never" | "onChange" | "always"
    var refreshMinutes = 30              // 15/30/60
    var forecastDays = 5                 // 3/5/7
}
struct WeatherCacheDTO: Codable, Sendable { var schemaVersion = 1; var locationKey: String; var units: WeatherUnits; var fetchedAt: Date; var data: WeatherData }
```

### Запросы (AC-14: только HTTPS и два домена, только координаты/строка поиска)
- Forecast: `https://api.open-meteo.com/v1/forecast?latitude=..&longitude=..&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day&hourly=temperature_2m,weather_code,is_day&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=N&forecast_hours=24&timezone=auto&temperature_unit=..&wind_speed_unit=..`
- Geocoding: `https://geocoding-api.open-meteo.com/v1/search?name=..&count=10&language=<ru|en>&format=json`
- URL строится через `URLComponents` с фиксированными `scheme`/`host`; никаких User-Agent-идентификаторов, cookies (`httpShouldSetCookies = false`), без URLCache (кешируем сами, НФТ).
- Время: ответ даёт локальные строки без смещения (`"2026-10-12T10:00"`) + `utc_offset_seconds`; парсим `DateFormatter` с `TimeZone(identifier: timezone)` (fallback `secondsFromGMT: utc_offset_seconds`) и показываем в часовом поясе города (AC-13).
- Не-JSON ответ (captive portal) → `.decoding` (граничный случай).

### Политика обновления
- `visibilityDidChange(.expanded)` → показать кеш сразу (с «обновлено HH:mm»/возрастом) → `shouldFetch` → запрос (AC-5).
- «Обновить» → `force: true` (уважает backoff).
- `peekMode == never` (по умолчанию): **нет** scheduler, **нет** NWPathMonitor; после закрытия панели — ноль фоновой активности (AC-8).
- `peekMode ≠ never`: `scheduler.schedule(at: nextRefresh)`, `NWPathMonitor` (на собственной serial `DispatchQueue`, `pathUpdateHandler` → `Task { @MainActor in ... }`) — при переходе в `.satisfied` и устаревшем кеше → запрос (граничный случай «просыпание без сети»). `isActive`: `always` → есть данные; `onChange` → 5 с при смене группы погоды (ясно → осадки/гроза и т.п., группы WMO: 0–3, 45–48, 51–67, 71–77, 80–82, 85–86, 95–99).
- Смена города (AC-10): `cacheKey` не совпадает → кеш удаляется, `state = .loading(nil)`, запрос.
- `deactivate()`: отмена текущей `Task` запроса (`URLSession` отменяется через cancellation), scheduler, `NWPathMonitor.cancel()` (AC-12).

### UI
- Нет локации → поиск: `NotchTextField` (ADR-004), debounce 400 мс (`Task.sleep` с отменой предыдущей), запрос при ≥ 2 символах, список «Город, регион, страна» (AC-1, AC-2). То же — в странице настроек (там обычный SwiftUI `TextField`, окно настроек — обычное).
- Expanded: слева текущая (иконка, температура, «ощущается», описание, ветер, влажность, мин/макс), справа почасовая полоса (`ScrollView(.horizontal)`, 24 точки) и дни (N строк); внизу «обновлено HH:mm» + «Обновить» + ссылка «Weather data by Open-Meteo.com» → `https://open-meteo.com/` (AC-15).
- Состояния: офлайн + кеш → баннер «Нет подключения»; без кеша → `WidgetMessageView` с «Повторить» (AC-6); ошибка API → «Не удалось обновить» поверх кеша (AC-7); «Ничего не найдено».
- Длинные названия городов — `lineLimit(1)`, `.truncationMode(.tail)`.

## Шаги реализации
1. Модели, `WMOCode`, `WeatherSettings` + тесты (все документированные коды → не «—»; неизвестный 1234 → «—»; день/ночь; units system на `en_US` → imperial, на `ru_RU` → metric). → AC-4, AC-11 (часть).
2. `WeatherClient` (URL + декодирование) + тесты на фикстурах: URL содержит только разрешённый host и https; полный ответ → все поля; частичный (без `daily`, без `current.weather_code`) → без падения; HTML вместо JSON → `.decoding`; время в часовом поясе города. Сеть в unit-тестах **не** используется (через `URLProtocol`-заглушку в `URLSessionConfiguration.protocolClasses`). → AC-3, AC-11, AC-13, AC-14.
3. `WeatherRefreshPolicy` + `WeatherCacheFile` + тесты (кеш моложе → нет запроса; 429 → следующий не раньше 5 мин, затем 10…30; успех сбрасывает; смена cacheKey → кеш невалиден; битый кеш → игнор). → AC-5, AC-7, AC-10.
4. `NetworkReachability` + `WeatherWidget` (режимы peek, scheduler, wake), регистрация в каталоге. Тесты (фейковый клиент через протокол-шов `WeatherFetching`): `peekMode=never` после `.hidden` → нет scheduler и монитора; `deactivate` отменяет in-flight задачу (AC-8, AC-12); `always` → `isActive` при наличии данных (AC-9).
5. Views (поиск, expanded, состояния, атрибуция, compact, settings). → AC-1, AC-2, AC-6, AC-15.
6. Обновить текст приватности в «О приложении» (TASK-002) при необходимости, ручная проверка, замер CPU и сетевой активности.

## Соответствие AC → шаг
AC-1, AC-2 → 5; AC-3 → 2 + 5; AC-4 → 1 + 2; AC-5 → 3 + 4; AC-6 → 2 (таймаут) + 5; AC-7 → 3; AC-8 → 4 + 6; AC-9 → 4; AC-10 → 3 + 4; AC-11 → 1 + 2; AC-12 → 4; AC-13 → 2; AC-14 → 2; AC-15 → 5.

## Что проверить глазами
1. Включить виджет → вкладка показывает поиск, никаких системных диалогов.
2. Ввести «Мос» → через ~0.4 с список с регионами/странами (несколько «Москва» различимы); выбрать → погода.
3. Переключить units на imperial → °F, mph.
4. Закрыть и открыть панель в течение 30 мин → **нет** нового запроса (проверить в Little Snitch/`nettop -p $(pgrep -x NotchApp)` или по неизменному «обновлено HH:mm»).
5. Выключить Wi-Fi, перезапустить → кеш с возрастом и «Нет подключения»; включить Wi-Fi → «Обновить» работает.
6. `peekMode=never`: свернуть панель, 5 мин — `nettop` не показывает соединений от NotchApp, CPU ~0.
7. Сменить город → старые данные не мелькают.
8. Атрибуция внизу кликабельна, открывает open-meteo.com.

## Риски и trade-offs
- **Лицензия Open-Meteo** (отложено осознанно, решение человека до публичного релиза): весь доступ изолирован в `WeatherClient` — замена провайдера/плана не затронет UI и кеш (кеш хранит наш нормализованный формат, WMO-коды числом).
- Backoff 5→10→20→30 мин — интерпретация «экспоненциальная пауза, не чаще 1 раза в 5 мин».
- `NWPathMonitor` запускается только при `peekMode ≠ never`; при `never` отсутствие сети обнаруживается ошибкой запроса при открытии — достаточно для AC-6 и честнее к 0% CPU.
- `forecast_hours` — параметр Open-Meteo; если недоступен, берём 24 точки `hourly` начиная с текущего часа города (запасной путь в маппинге).
