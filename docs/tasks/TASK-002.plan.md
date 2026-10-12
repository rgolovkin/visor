# План реализации TASK-002: окно настроек

Спецификация: `docs/tasks/TASK-002.md`. Базовый план: `TASK-001.plan.md` (структура, правила, тесты).
ADR: ADR-006 (окно настроек и activation policy), ADR-003 (точка расширения `makeSettingsView`, `deactivationWarning`), ADR-002 (сброс, flush).

## Архитектурное решение
```
MenuBarContent «Настройки…» (⌘,) ─► SettingsWindowController.show() ─► NSWindow + NSHostingController(SettingsRootView)
SettingsRootView (NavigationSplitView)
 ├─ General  ─► GeneralSettingsModel ─► LaunchAtLoginService (SMAppService.mainApp) ; ScreenManager.screens ; ConfigStore.general
 ├─ Widgets  ─► WidgetRegistry (items, setEnabled, move, moveUp/Down)    ← только через registry
 │    └─ <widget page> = widget.makeSettingsView()  (только если не nil)
 └─ About    ─► AppPaths (Показать в Finder), ConfigStore.resetToDefaults → registry.resetToDefaults
```
Окно — только представление: никаких записей в файлы напрямую (НФТ). Все изменения → `WidgetRegistry`/`ConfigStore` → debounce-сохранение.

Почему AppKit-контроллер, а не SwiftUI `Settings`/`Window` scene (как предлагает спецификация): нужен надёжный хук закрытия для возврата `.accessory` и гарантия, что окно не покажется при старте агента на macOS 14 — подробно в ADR-006.

## Изменения в файлах данных
- `general.displayMode`, `general.displayId` — по спецификации TASK-001; добавляется `general.displayName` (строка | null, только для подписи «(не подключён)», аддитивно).
- `general.launchAtLogin` — справочное: пишется после успешного register/unregister, никогда не читается как источник истины (AC-9).

## Контракты (новые типы)
```swift
// Settings/
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    init(environment: AppEnvironment)
    func show()
}
struct SettingsRootView: View { let environment: AppEnvironment }
enum SettingsSection: Hashable { case general, widgets, widget(String), about }

@MainActor @Observable final class GeneralSettingsModel {
    var launchAtLogin: Bool { get }          // всегда из LaunchAtLoginService.status
    var launchError: LaunchAtLoginError?
    func setLaunchAtLogin(_ on: Bool)
    var displayOptions: [DisplayOption]      // auto, primary, notch, + screens (+ «(не подключён)» для сохранённого)
    var selectedDisplay: DisplayOption
    func select(_ option: DisplayOption)     // → ConfigStore.update + ScreenManager.apply (немедленно, AC-11)
    func refresh()                           // вызывается в onAppear окна
}
enum DisplayOption: Hashable { case auto, primary, notch, display(id: String, name: String, connected: Bool) }

// Core/Launch/LaunchAtLoginService.swift
@MainActor final class LaunchAtLoginService {
    enum Status { case enabled, disabled, requiresApproval, notFound }
    var status: Status                       // SMAppService.mainApp.status
    func setEnabled(_ on: Bool) throws       // register()/unregister()
    func openSystemSettings()                // SMAppService.openSystemSettingsLoginItems()
}
```
Изменения в существующих типах:
- `AppEnvironment`: + `settings: SettingsWindowController`, + `launchAtLogin: LaunchAtLoginService`.
- `MenuBarContent`: «Настройки…» активен → `environment.settings.show()`.
- `EmptyStateView` (TASK-001): «Открыть настройки» → `environment.settings.show()` (AC-8).
- `WidgetContext.openSettings` подключён к тому же вызову.
- `WidgetRegistry.resetToDefaults()`: применяет дефолтный порядок/включённость (диф → `activate(.userEnabled)`/`deactivate`), затем `reloadSettings()` всем виджетам.

## UI-детали
- `NavigationSplitView`: sidebar с секциями; под «Виджеты» — дочерние пункты только для виджетов, у которых `makeSettingsView() != nil` (AC-14). Минимальный размер окна 640×420, `setFrameAutosaveName`.
- **Список виджетов** (`WidgetsSettingsView`): `List { ForEach(registry.items, id: \.widget.id) { row } .onMove(perform: registry.move) }` — на macOS `onMove` в `List` даёт drag-and-drop строк (AC-7). Строка: `Image(systemName: widget.symbolName)`, `title`, `Toggle` (VoiceOver: `accessibilityLabel("Включить «\(title)»")`). Альтернатива перетаскиванию (доступность): `.contextMenu { Button("Выше"); Button("Ниже") }` + `.accessibilityAction(named: "Выше/Ниже")`.
- **Выключение с предупреждением**: если `widget.deactivationWarning != nil` (таймер с идущим отсчётом, TASK-004 AC-13) → `.confirmationDialog`; отмена возвращает тумблер.
- **Запуск при входе**: `Toggle` с `Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })`. Ошибка/`requiresApproval` → тумблер отражает фактический статус, под ним `Text` с объяснением + кнопка «Открыть Системные настройки → Объекты входа» (AC-10). `SMAppService.status` перечитывается в `onAppear` и при `NSApplication.didBecomeActiveNotification` пока окно открыто (покрывает «убрали вручную»).
- **Экран**: `Picker` из `displayOptions`. Если сохранённый `display` не подключён — пункт `"\(name) (не подключён)"` (AC-12).
- **О приложении**: версия (`CFBundleShortVersionString` + build), «Показать в Finder» → `NSWorkspace.shared.activateFileViewerSelecting([paths.config])`, «Сбросить настройки» → `.confirmationDialog` → `ConfigStore.resetToDefaults()` + `registry.resetToDefaults()` + `ScreenManager.apply(.auto, nil)` (AC-15; `data/` не трогаем). Блок «Приватность»: локальные данные; «Погода» отправляет координаты выбранного города в Open-Meteo; атрибуция «Weather data by Open-Meteo.com (CC BY 4.0)» ссылкой.

## Шаги реализации
1. **`LaunchAtLoginService`** (Core/Launch/) + маппинг статусов. Тест: маппинг `SMAppService.Status` → `Status` (чистая функция `map(_:)`); реальный register в unit-тестах не вызываем.
   Проверка: `make build`.
2. **`SettingsWindowController` + пустой `SettingsRootView` с секциями** (Settings/), подключение к меню-бару и `EmptyStateView`.
   Проверка вручную: AC-1, AC-2, AC-3 (Dock-иконка появляется при открытии и исчезает при закрытии; повторное «Настройки…» не плодит окон).
3. **Раздел «Виджеты»**: список, тумблеры, `onMove`, контекстное меню «Выше/Ниже», подтверждение по `deactivationWarning`, дочерние страницы виджетов.
   Тесты (`Tests/Settings/`, FakeWidget с/без `makeSettingsView`): `registry.moveUp/moveDown` на границах — без изменений; move на ту же позицию — без изменений; список страниц настроек содержит только виджеты с настройками (AC-14); неизвестный id из config не попадает в `registry.items`, но остаётся в документе (граничный случай).
   Проверка вручную: AC-4, AC-5 (≤ 300 мс исчезает из expanded/peek), AC-6, AC-7, AC-8, AC-17 (FakeWidget в DEBUG-каталоге не нужен — достаточно теста на `WidgetCatalog`).
4. **Раздел «Общие»**: автозапуск, выбор экрана.
   Тесты: `GeneralSettingsModel.displayOptions` при отключённом сохранённом экране содержит `connected: false`; `select(.display)` пишет `displayMode = display`, `displayId`, `displayName`.
   Проверка вручную: AC-9, AC-10, AC-11, AC-12 (см. ниже).
5. **Раздел «О приложении»** и сброс.
   Тест: после `resetToDefaults` документ = `ConfigDefaults`, файлы в `data/` (создать фиктивные в temp) существуют (AC-15).
6. **Flush при выходе** — проверить, что `applicationWillTerminate` уже вызывает `flushAll` (TASK-001); тест: `ConfigStore.update` + немедленный `flush()` → файл содержит изменение (AC-16).
7. **Доступность и темы**: клавиатурная навигация (Tab по контролам sidebar/списка), VoiceOver-метки, проверка светлой/тёмной темы.

## Соответствие AC → шаг
AC-1/2/3 → 2; AC-4/5/6/7/8/13/14/17 → 3 (AC-13 — через `WidgetSettingsHandle.save`, проверяется на первом виджете с настройками в TASK-005); AC-9/10/11/12 → 4; AC-15 → 5; AC-16 → 6.

## Что проверить глазами
1. Меню-бар → «Настройки…»: окно поверх всех, с фокусом (можно сразу нажимать Tab). Снова «Настройки…» — то же окно.
2. Закрыть окно — Dock-иконка исчезла; Cmd+Tab не показывает приложение.
3. Выключить «Часы» — исчезли из expanded и peek сразу; включить — вернулись на своё место. Перетащить строку — порядок вкладок в expanded поменялся; перезапуск — порядок сохранён.
4. Выключить все виджеты → в expanded «Нет включённых виджетов» и ссылка открывает настройки.
5. Автозапуск: **из Debug-сборки** ожидаемо может быть ошибка/`requiresApproval` — должно быть понятное сообщение и кнопка в Системные настройки, без падения. Полную проверку делать на копии в `/Applications` (скопировать `build/Build/Products/Debug/NotchApp.app`), затем перелогиниться.
6. Экран: выбрать внешний монитор → чёлка переехала сразу; отключить монитор → чёлка на основном, в настройках «Имя (не подключён)»; подключить → вернулась.
7. «Сбросить настройки» → подтверждение → порядок/включённость дефолтные, `~/Library/Application Support/NotchApp/data/` не тронута.
8. VoiceOver (⌘F5): тумблеры читаются как «Включить „Часы“».

## Риски и trade-offs
- `SMAppService` из не-`/Applications` сборки ведёт себя непредсказуемо — обрабатываем любые ошибки как «фактический статус + сообщение».
- `List.onMove` на macOS иногда конфликтует с `Toggle` при начале перетаскивания по тумблеру — перетаскивание за всю строку, тумблер остаётся кликабельным; альтернатива — контекстное меню.
- Смена activation policy на `.regular` кратко показывает Dock-иконку — ожидаемо по спецификации.
