# ADR-006: Окно настроек и жизненный цикл приложения-агента

Статус: принято (архитектор), 2026-10-12
Связано: TASK-001 (п.11, AC-20, AC-21), TASK-002 (AC-1..3, AC-16, НФТ «0% CPU при закрытом окне»)

## Контекст
Приложение — агент (`LSUIElement = YES`): нет Dock-иконки, оно почти никогда не активно. Окно настроек — обычное окно, которое должно получать фокус (ввод, клавиатурная навигация), существовать в одном экземпляре, а при закрытии — освобождать view-модели и возвращать режим без Dock-иконки.

## Варианты
A. SwiftUI `Settings` scene + `SettingsLink`/`openSettings` (macOS 14). Нет хука «окно закрыто» для возврата activation policy; при неактивном агенте окно открывается позади других окон; поведение `openSettings` из `MenuBarExtra` нестабильно между минорными версиями macOS 14/15.
B. SwiftUI `Window(id:)` + `openWindow`. Одиночность из коробки, но в агенте `Window`-scene может быть показана при запуске (`defaultLaunchBehavior(.suppressed)` есть только с macOS 15), закрытие ловится только через `onDisappear` (срабатывает и при сворачивании).
C. **AppKit `SettingsWindowController`: `NSWindow` + `NSHostingController(rootView: SettingsRootView)`, создаётся по требованию и уничтожается при закрытии. Выбрано.**

## Решение
- `SettingsWindowController` (`@MainActor final class`, Settings/), владеет `NSWindow?`, реализует `NSWindowDelegate`.
  - `show()`: если окно есть — `makeKeyAndOrderFront` + `NSApp.activate()` (AC-2); иначе создаёт `NSWindow(contentViewController: NSHostingController(rootView:))`, `styleMask [.titled, .closable, .miniaturizable, .resizable]`, `minSize`, `setFrameAutosaveName("Settings")`, `isReleasedWhenClosed = false`; затем `NSApp.setActivationPolicy(.regular)` → `makeKeyAndOrderFront(nil)` → `NSApp.activate()` (AC-1).
  - `windowWillClose`: `window = nil` (освобождает hosting controller и view-модели → нет подписок, TASK-002 НФТ), `NSApp.setActivationPolicy(.accessory)` (AC-3).
  - Почему `.regular` на время показа: агент с `.accessory` может показать окно, но macOS не всегда отдаёт ему фокус и окно не попадает в Cmd+Tab; временный `.regular` — общепринятый приём для настроек агентов.
  - `NSApp.activate()` без аргументов (macOS 14); `activate(ignoringOtherApps:)` deprecated → warning → ошибка сборки.
- `NotchApp` (`@main`, SwiftUI `App`) остаётся точкой входа: `@NSApplicationDelegateAdaptor(AppDelegate.self)` + `MenuBarExtra` (уже есть в скелете). Пункт «Настройки…» `.keyboardShortcut(",")` вызывает `appDelegate.environment.settings.show()`; «Выйти» `.keyboardShortcut("q")` → `NSApp.terminate(nil)`.
- `AppDelegate` (`@MainActor`, `NSApplicationDelegate`) — владелец `AppEnvironment` (composition root): `ConfigStore`, `WidgetRegistry`, `ScreenManager`, `NotchWindowController`, `SettingsWindowController`, `SystemEvents`.
  - `applicationWillFinishLaunching`: проверка второго экземпляра (AC-21): `NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)` без текущего `processIdentifier` непусто → `NSApp.terminate(nil)` до создания окон.
  - `applicationDidFinishLaunching`: если процесс запущен под XCTest (`ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`) — **не** создавать окна/виджеты (unit-тесты хостятся в приложении, см. план TASK-001 шаг 0). Иначе: загрузить config → registry → активировать включённые виджеты (`.launch`) → показать NotchWindow.
  - `applicationWillTerminate`: `environment.flushAll()` (ADR-002).
  - `applicationShouldTerminateAfterLastWindowClosed` → `false`.

## Последствия
- (+) Одно окно, детерминированный фокус и возврат в режим агента; закрытое окно не держит ресурсов.
- (−) Немного AppKit-кода вместо декларативной scene (≈ 60 строк).
- (−) Пока окно настроек открыто, у приложения есть Dock-иконка — ожидаемо и описано в спецификации.
