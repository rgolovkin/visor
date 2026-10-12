# ADR-004: Ввод текста в non-key NSPanel (заметки, ввод длительности таймера, поиск города)

Статус: принято (архитектор), 2026-10-12
Связано: TASK-001 (п.1, п.5, AC-10, AC-22), TASK-006 (AC-2), TASK-004 (ручной ввод ЧЧ:ММ:СС), TASK-007 (поиск города в expanded)

## Контекст
NotchWindow не должен становиться key/main и не должен активировать приложение (AC-10). Но клавиатурный ввод в macOS получает только key-окно. Спецификация (TASK-001 Q9, TASK-006 Q1): окно становится key **только** по клику в текстовое поле; пока поле в фокусе (включая IME-композицию) автосворачивание отключено; после потери фокуса/клика вне — обычные правила. Временная активация приложения допустима.

## Варианты
A. SwiftUI `TextField`/`TextEditor` + `@FocusState`. В не-key borderless-панели фокус SwiftUI не устанавливается; узнать о «клике в поле» до того, как окно стало key, невозможно; нет доступа к `hasMarkedText()` (IME). Отпадает.
B. `NSPanel.becomesKeyOnlyIfNeeded = true` + `canBecomeKey = true`. Нативный механизм «key только при клике во view, которому нужен ввод». Но `NSHostingView` — один NSView на весь SwiftUI-контент, и его `needsPanelToBecomeKey` не различает кнопку и поле → риск, что любой клик по кнопке виджета сделает окно key. Не управляемо.
C. **Явный флаг: `NotchPanel.canBecomeKey` возвращает `isTextInputActive`; флаг выставляют только наши AppKit-поля (`NSTextField`/`NSTextView`-подклассы, завёрнутые в `NSViewRepresentable`) в `mouseDown` до вызова `super`. Выбрано.**

## Решение

### Компоненты (Window/TextInput/)
- `TextInputCoordinator` (`@MainActor final class`, один на NotchWindow): `begin(from view: NSView)`, `end()`, `var isActive: Bool`, `onChange: (Bool) -> Void` → `NotchViewModel.send(.textInputBegan/.textInputEnded)`.
  - `begin`: `panel.isTextInputActive = true` → `panel.makeKey()` → `panel.makeFirstResponder(view)`; ставит глобальный монитор `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` (клик в другом приложении) и локальный `addLocalMonitorForEvents(matching: .keyDown)` для Esc.
  - `end`: `panel.makeFirstResponder(nil)` → `panel.isTextInputActive = false` → `panel.resignKey()`; снимает мониторы. Вызывается из: `resignFirstResponder` поля, `NSWindow.didResignKeyNotification`, глобального клика, Esc, перехода в collapsed/peek, смены экрана.
- `NotchTextField` (`NSViewRepresentable` над подклассом `NSTextField`) — однострочный (таймер, поиск города).
- `NotchTextEditor` (`NSViewRepresentable` над `NSScrollView` + подклассом `NSTextView`) — многострочный (заметки; добавляется в TASK-006). Настройки: `isRichText = false`, `importsGraphics = false`, `allowsUndo = true`, `usesFindBar = false`, `isAutomaticQuoteSubstitutionEnabled = false` (plain text, вставка форматированного текста приводится к plain).
- Оба подкласса: `acceptsFirstMouse → true`; `mouseDown` → `coordinator.begin(self)` затем `super.mouseDown`.

### Почему `.nonactivatingPanel` решает «не активировать приложение»
Панель со стилем `.nonactivatingPanel` может стать key, **не активируя** приложение: фронтальное приложение и его меню-бар остаются, а клавиатурные события идут в нашу панель (так работают Spotlight-подобные панели). Поэтому `NSApp.activate()` по умолчанию **не** вызываем.

### Стандартные шорткаты (⌘C/⌘V/⌘X/⌘A/⌘Z/⇧⌘Z)
В Cocoa они работают через пункты меню Edit главного меню. У агента (`LSUIElement`) главное меню не показывается и может не получить key equivalent, пока приложение неактивно. Поэтому подклассы поля/редактора переопределяют `performKeyEquivalent(with:)` и сами маршрутизируют эти сочетания: `NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)` и т.д., ⌘Z/⇧⌘Z — `undoManager?.undo()/redo()`. Это обход ограничения macOS — в коде помечается комментарием.

### IME
Пока поле — first responder, панель не сворачивается — IME-композиция покрыта автоматически. Дополнительно `end()` по Esc игнорируется, если `textView.hasMarkedText()` (Esc в IME отменяет композицию, а не ввод).

### Автосворачивание
Машина состояний (ADR-001) получает `textInputBegan` → запоминает `textInputActive = true` и не выполняет `scheduleClose`; на `textInputEnded` — если курсор вне панели, ставит `scheduleClose(300 мс)` (AC-22). Переход в collapsed/peek всегда сначала вызывает `TextInputCoordinator.end()` и `registry.flushAll()` для видимого виджета.

### Правило для разработчиков виджетов
В контенте NotchWindow **запрещены** SwiftUI `TextField`/`TextEditor`/`SecureField` — только `NotchTextField`/`NotchTextEditor`. В окне настроек (обычное окно) SwiftUI-поля разрешены. Нарушение — блокирующее замечание на ревью.

## Fallback (если ручная проверка выявит проблему)
Если на какой-то версии macOS в non-activating key-панель не приходит ввод или ломается IME: в `begin` запоминаем `NSWorkspace.shared.frontmostApplication`, вызываем `NSApp.activate()`; в `end` — `previousApp?.activate()`. Спецификация это разрешает («временная передача фокуса приложению допустима»). Переключение — одна ветка в `TextInputCoordinator`, остальной код не меняется.

## Последствия
- (+) Окно становится key ровно тогда, когда нужно; кнопки и hover не трогают фокус.
- (+) Полный контроль над IME, plain text, лимитом 1 МБ (`textView(_:shouldChangeTextIn:replacementString:)`).
- (−) Своё `NSViewRepresentable` вместо SwiftUI-полей: больше кода (≈ 150–200 строк на оба), нужна аккуратная синхронизация текста (не перезаписывать `string` во время редактирования).
- (−) Ручная маршрутизация шорткатов — обход; если Apple изменит поведение, проверяется ручным тестом из плана TASK-006.
- Ручная проверка AC-22 возможна только с первым виджетом с полем ввода (TASK-004, затем TASK-006); в TASK-001 логика покрывается unit-тестами машины состояний.
