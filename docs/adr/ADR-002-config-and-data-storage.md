# ADR-002: Хранение config.json и data/ (schemaVersion, неизвестные поля, атомарность)

Статус: принято (архитектор), 2026-10-12
Связано: TASK-001 (AC-13..17), TASK-002 (AC-13, AC-15, AC-16), TASK-004, TASK-006 (AC-3, AC-10, AC-11, AC-13), TASK-007

## Контекст
- Формат должен читаться будущим Windows-клиентом: только JSON-примитивы, ISO-8601, без Swift-специфики.
- Неизвестные поля (в корне, в `general`, в элементах `widgets`, внутри `widgets[i].settings`) и неизвестные `id` виджетов **не теряются** при перезаписи.
- `schemaVersion` новее известной: config — не «понижать» и сделать бэкап; notes — режим только чтения.
- Повреждённый файл → `<name>.broken-<timestamp>`, работа с дефолтами.
- Запись атомарная, debounce, flush при выходе.
- Пользовательские данные (`data/`) отделены от настроек и переживают «Сбросить настройки».

## Варианты
A. Строгие `Codable`-структуры. Неизвестные поля молча выбрасываются при `JSONDecoder → JSONEncoder` — нарушает требование.
B. `[String: Any]` через `JSONSerialization`. Не `Sendable`, нет типобезопасности, легко ошибиться — плохо для Swift 6.
C. **Гибрид: «сырое» дерево `JSONValue` (собственный `enum`, `Codable + Sendable + Equatable`) как источник истины для неизвестных полей + типизированные проекции для известных полей. Выбрано.**

## Решение

### JSONValue (Core/JSON/JSONValue.swift)
```swift
enum JSONValue: Sendable, Equatable, Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
}
```
Хелперы: `subscript(key:) -> JSONValue?`, `objectValue`, `func merging(_ other: [String: JSONValue]) -> JSONValue` (поверхностное слияние: известные ключи перезаписываются, остальные сохраняются), `static func encode<T: Encodable>(_:) throws -> JSONValue`, `func decode<T: Decodable>(_:) throws -> T` (через `JSONEncoder/JSONDecoder` с `.iso8601`).
Ограничение: числа хранятся как `Double` (целые > 2^53 теряют точность) — для наших данных несущественно.

### Модель конфига (Core/Config/)
- `ConfigDocument`: `raw: [String: JSONValue]` (всё, что прочитано) + типизированные `general: GeneralConfig`, `widgets: [WidgetConfigEntry]`.
- `WidgetConfigEntry { id: String; enabled: Bool; settings: JSONValue /* object */; extra: [String: JSONValue] }` — `extra` хранит неизвестные ключи элемента.
- `GeneralConfig { launchAtLogin: Bool; displayMode: DisplayMode; displayId: String?; displayName: String?; extra: [String: JSONValue] }`. `displayName` — **дополнительное** поле (только для подписи «(не подключён)» в TASK-002), аддитивно и совместимо.
- `ConfigCodec` (чистые функции, unit-тесты):
  - `decode(_ data: Data) throws -> ConfigDocument` — бросает только при невалидном JSON/корне не-объекте; отдельные кривые поля → дефолт поля (толерантный разбор).
  - `encode(_ doc: ConfigDocument) throws -> Data` — берёт `raw`, поверх кладёт известные ключи, `JSONEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]` (стабильные диффы для ручного чтения).
- Порядок: массив `widgets` в файле — единственный источник порядка, **включая неизвестные id**. Перестановка известных виджетов делается чистой функцией `WidgetOrder.reorder(entries:knownIDs:newKnownOrder:)`: известные записи переставляются, неизвестные остаются на своих индексах-«слотах». Новые (появившиеся в коде) виджеты, которых нет в файле, дописываются в конец с `enabled = descriptor.defaultEnabled`.

### Политики файла
| Ситуация | config.json | data/*.json |
|---|---|---|
| Файла нет | создать дефолт (AC-13) | пустое состояние, файл создаётся при первой записи |
| Невалидный JSON / корень не объект | rename → `config.json.broken-<ts>`, дефолт (AC-14) | rename → `<name>.broken-<ts>`, пустое состояние, флаг `recoveredFromBackup(path)` для UI (notes AC-10) |
| `schemaVersion` > known | читать известное; **перед первой записью** один раз копия `config.json.v<N>-backup-<ts>`; писать, сохраняя `schemaVersion = N` и все неизвестные поля; `Logger.warning` (AC-15) | `readOnly = true`: не писать вообще, UI показывает предупреждение (notes AC-11). Для timer/weather-cache — игнорировать файл (кеш/эфемерное состояние) |
| Запись не удалась (read-only, нет места) | лог `.error`, работа в памяти, повтор при следующем изменении | то же + ошибка в UI для notes |

`<ts>` = `yyyyMMdd-HHmmss` (UTC, без двоеточий — безопасно для файловых систем Windows).

### Атомарность и debounce (Core/Persistence/)
- `AtomicFile`: `read() throws -> Data?`, `write(_:)` через `Data.write(to:options: [.atomic])` (Foundation пишет во временный файл и делает rename — ровно требование AC-17), `moveAside(suffix:)`, `modificationDate()`.
- `DebouncedSaver` (`@MainActor final class`): `markDirty()` перезапускает отложенную задачу (`Task.sleep(for: delay)`), по срабатыванию вызывает `save: @MainActor () -> Void`; `flush()` — синхронно, отменяя отложенную задачу. Задержки: config 300 мс (≤ 500 мс по AC-17), notes 500 мс, timer — без debounce (запись на смену состояния).
- `applicationWillTerminate` → `AppEnvironment.flushAll()`: `ConfigStore.flush()` + `registry.flushAll()` (каждый виджет сбрасывает свои data-файлы синхронно). Это закрывает TASK-002 AC-16 и TASK-006 AC-4.

Почему запись синхронно на main actor, а не в фоновом акторе: файлы маленькие (config — единицы КБ; notes — до единиц МБ, атомарная запись на SSD — миллисекунды), а синхронный `flush()` при выходе обязан выполниться до завершения процесса. Фоновый актор дал бы гонку «асинхронная запись в полёте vs синхронный flush» ради выигрыша, которого не видно. Если профилирование покажет подвисание на notes — выносим только `write(Data)` в последовательную очередь, кодирование оставляем на main.

### Пути (Core/Persistence/AppPaths.swift)
- `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)` + `NotchApp/` (sandbox выключен, путь реальный).
- `config.json`, `data/notes.json`, `data/timer.json`, `data/weather-cache.json`.
- Для тестов `AppPaths(root: URL)` инъецируется (временная папка).

### Настройки виджетов
- Виджет владеет схемой `widgets[i].settings`. Через `WidgetSettingsHandle` (ADR-003) он декодирует свою `Codable`-структуру и сохраняет её **слиянием** в существующий объект → неизвестные ключи внутри `settings` сохраняются.
- Шаблон толерантного декодирования для всех `*Settings`: в `init(from:)` каждое поле `(try? c.decodeIfPresent(T.self, forKey: .x)) ?? Defaults.x` — одно кривое поле не обнуляет остальные.
- Даты — ISO-8601 строки (`JSONEncoder.dateEncodingStrategy = .iso8601`), длительности — числа секунд, enum — строки.

### Сброс настроек (TASK-002 AC-15)
`ConfigStore.resetToDefaults()` заменяет документ на дефолтный (неизвестные поля тоже сбрасываются — это сброс), папку `data/` не трогает.

## Последствия
- (+) Совместимость вперёд/назад и с Windows-клиентом без потерь данных.
- (+) Вся логика — чистые функции, покрывается unit-тестами в temp-папке.
- (−) Поддерживать «двойное представление» (raw + typed) чуть сложнее, чем голый Codable; закрыто тестами round-trip.
- (−) Внешние ручные правки config во время работы перезапишутся при следующем сохранении (принято спецификацией: наблюдение за файлом вне scope).
