# ADR-001: NotchWindow, состояния и механизм hover

Статус: принято (архитектор), 2026-10-12; поправка по итогам ручной проверки — 2026-10-12 (см. раздел «Поправка по итогам ручной проверки»)
Связано: TASK-001, TASK-006 (ввод текста — ADR-004), ADR-005 (энергопотребление)

## Контекст
Нужна «чёлка», которая:
- рисуется поверх меню-бара на всех Spaces и поверх полноэкранных приложений;
- не крадёт фокус и не становится key/main (кроме ввода текста, ADR-004);
- раскрывается по hover (150 мс) и сворачивается по уходу (300 мс) без опроса мыши;
- анимируется spring-ом, прерываемо;
- не перехватывает клики в меню-бар вне своей видимой формы.

SwiftUI сам по себе не умеет окно без рамки над меню-баром, на всех Spaces, не активирующее приложение — поэтому окно делаем на AppKit, а контент внутри — на SwiftUI (`NSHostingView`). AppKit отвечает за «где и как живёт окно», SwiftUI — за «что и как анимируется внутри».

## Варианты

### Окно
A. SwiftUI `Window` scene + модификаторы. Нельзя задать уровень окна, collectionBehavior, nonactivating — отпадает.
B. `NSPanel` (подкласс `NotchPanel`) + `NSHostingView` с SwiftUI-контентом. Полный контроль. **Выбрано.**

### Размер окна
A. Окно фиксированного максимального размера (размер expanded), форма чёлки анимируется внутри. Плюс: нет изменений frame. Минус: прозрачный прямоугольник 520×~230 pt постоянно висит поверх меню-бара и съедает клики по пунктам меню/иконкам статус-бара рядом с чёлкой; обход через `ignoresMouseEvents` требует глобального монитора на каждое движение мыши — постоянная работа.
B. Анимировать `NSWindow.setFrame(_:display:animate:)` синхронно с SwiftUI. Две независимые анимации (AppKit и SwiftUI) рассинхронизируются — дёрганье, ровно то, что запрещено.
C. **Frame окна = объединение «откуда» и «куда» на время перехода; в покое = точная форма текущего состояния. Выбрано.**
   - Раскрытие: сначала мгновенно (без анимации) увеличиваем frame до прямоугольника expanded, затем SwiftUI анимирует форму. Само по себе выравнивание контента по верху не гарантирует, что смена frame ничего не сдвинет (это предположение не подтвердилось на реальном Mac): SwiftUI-контент не должен видеть смену размера окна вообще. Поэтому hosting view имеет фиксированный размер и фиксированное положение на экране («холст» `NotchGeometry.canvasRect`), а меняется только окно вокруг него — см. «Поправка по итогам ручной проверки».
   - Сворачивание: SwiftUI анимирует форму вниз; по завершении анимации (completion `withAnimation(_:completionCriteria:_:completion:)`, macOS 14) — если целевое состояние не поменялось — ужимаем frame до формы collapsed/peek.
   - Итог: в покое окно не шире видимой формы → клики в меню-бар вне чёлки не блокируются (граничный случай TASK-001).

### Hover
A. Опрос `NSEvent.mouseLocation` по таймеру — запрещено (правила проекта, 0% CPU).
B. `NSEvent.addGlobalMonitorForEvents(.mouseMoved)` — вызывается на каждое движение мыши по всей системе; не опрос, но лишняя работа.
C. **`NSTrackingArea` на корневом view окна с опциями `[.mouseEnteredAndExited, .activeAlways, .inVisibleRect]`. Выбрано.** `.activeAlways` обязателен: наше приложение почти никогда не активно, а без этой опции tracking area работает только в активном приложении. Поскольку frame окна в покое = форма чёлки, область трекинга = зона наведения.
   - После каждого изменения frame AppKit может не прислать `mouseEntered/Exited`, если курсор неподвижен. Поэтому после `setFrame` делаем **одну** проверку `frame.contains(NSEvent.mouseLocation)` и синтезируем событие в машину состояний (это не опрос — разовая проверка на событие).
   - Глобальный монитор `.leftMouseDown` ставится только на время ввода текста (ADR-004), чтобы ловить «клик вне панели».

## Решение

### NotchPanel (Window/NotchPanel.swift)
- `NSPanel(contentRect:styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)`. `.nonactivatingPanel` задаётся только в init (известный баг AppKit при смене после создания).
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `isMovable = false`, `isReleasedWhenClosed = false`, `animationBehavior = .none`.
- `hidesOnDeactivate = false` — **у NSPanel по умолчанию true**; без этого чёлка пропадёт, например, после закрытия окна настроек (приложение деактивируется).
- `level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)` — выше меню-бара, в т.ч. когда он выезжает в полноэкранном режиме. `.statusBar` (25) лишь на 1 выше `.mainMenu` (24) и на практике проигрывает выезжающему меню в fullscreen; так делают Boring Notch/NotchDrop.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]` — `.ignoresCycle` добавлен, чтобы окно не участвовало в циклах окон (AC-10).
- `canBecomeKey` → `isTextInputActive` (динамический флаг, ADR-004); `canBecomeMain` → `false`.
- `constrainFrameRect(_:to:)` → возвращает rect без изменений (AppKit иначе может «подвинуть» окно ниже меню-бара).

### NotchHostingView (Window/NotchHostingView.swift)
Подкласс `NSHostingView<NotchRootView>`:
- `acceptsFirstMouse(for:) -> true` — первый клик в не-key окне сразу нажимает кнопку, а не «активирует окно».
- `updateTrackingAreas()` пересоздаёт одну tracking area; `mouseEntered/mouseExited` → `NotchViewModel.send(.pointerEntered/.pointerExited)`.

### Состояния — чистая машина состояний (Window/NotchStateMachine.swift)
`struct NotchStateMachine` без AppKit/таймеров: `mutating func handle(_ event: NotchEvent) -> [NotchEffect]`.
- Состояния: `enum NotchState { case collapsed, peek, expanded }`.
- Входы: `pointerEntered`, `pointerExited`, `openDelayElapsed(token)`, `closeDelayElapsed(token)`, `clicked`, `peekAvailabilityChanged(Bool)`, `textInputBegan`, `textInputEnded`, `screenChanged`.
- Эффекты: `.scheduleOpen(after: .milliseconds(150), token)`, `.scheduleClose(after: .milliseconds(300), token)`, `.cancelPending`, `.transition(to:)`.
- Токены (монотонный счётчик) защищают от «устаревшего» срабатывания отложенного действия после смены направления (AC-5, AC-6).
- Правила: свернуть можно только если `!textInputActive` (AC-22); целевое свёрнутое состояние = `peek` если есть победитель, иначе `collapsed` (AC-4, AC-9).

Почему отдельная чистая структура: её можно покрыть unit-тестами без окна и времени (эффекты возвращаются, а не исполняются), а исполнение задержек — тонкий слой в `NotchViewModel` (`Task.sleep` + проверка токена).

### Анимации
- `NotchShape: Shape` с `animatableData` (ширина/высота/радиусы) — форма анимируется как одно целое, без отдельных анимаций кусков.
- Spring: `.spring(response: 0.42, dampingFraction: 0.82)` (значения — стартовые, тюнинг вручную). SwiftUI spring при перенацеливании сохраняет скорость → разворот из текущего положения без скачка (AC-6).
- Reduce Motion: `@Environment(\.accessibilityReduceMotion)` → `.easeInOut(duration: 0.15)` + `.transition(.opacity)` вместо изменения формы со spring.
- Контент expanded создаётся только в состоянии expanded (`if state == .expanded`), compact — только в peek. Невидимые view не живут в иерархии → не тикают (ADR-005).

### Геометрия (Window/Screen/)
- Экран с чёлкой: `safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil`. Прямоугольник чёлки: `x = frame.minX + auxiliaryTopLeftArea.width`, `width = frame.width - left.width - right.width`, `height = safeAreaInsets.top`, прижат к `frame.maxY`.
- Без чёлки: пилюля по центру сверху, ширина 200 pt, высота = высота меню-бара (`frame.maxY - visibleFrame.maxY`, если > 0), но не меньше 24 pt (AC-2).
- Peek: прямоугольник чёлки, расширенный на `sideWidth` (стартово 96 pt) влево и вправо; compact-вид ограничивается этой шириной (обрезается).
- Expanded: ширина 520 pt, высота = высота чёлки + 200 pt, по центру чёлки.
- Холст: `NotchGeometry.canvasRect` = объединение collapsed/peek/expanded (все центрированы по оси чёлки и прижаты к верху экрана). Это неподвижная область, в которой раскладывается SwiftUI-контент (см. поправку ниже).
- «Главный экран» = `NSScreen.screens.first` (экран с меню-баром), **не** `NSScreen.main` (это экран key-окна, у агента он «плавает»).
- Стабильный id экрана: `CGDisplayCreateUUIDFromDisplayID(displayID)` → строка UUID (`CGDirectDisplayID` меняется между перезагрузками).
- Реакция на `NSApplication.didChangeScreenParametersNotification`: коалесцирование 200 мс (за одно подключение монитора приходит серия уведомлений) → пересчёт → `setFrame` (AC-12, ≤ 1 с).
- Выбор экрана и расчёт прямоугольников — чистые функции над value-типом `ScreenInfo` (тестируемы без реальных мониторов).

## Поправка по итогам ручной проверки
Исходное утверждение «контент выровнен по верхнему центру, поэтому изменение frame визуально ничего не сдвигает» оказалось неверным: на реальном Mac при hover peek → expanded правая часть формы «прыгала» влево, а панель expanded выезжала сверху. Причина первого — hosting view растягивался вместе с окном (`autoresizingMask`), SwiftUI заново центрировал чёлку по новой ширине окна, и этот сдвиг к новому центру попадал внутрь `withAnimation`, хотя origin окна уже мгновенно переместился. Причина второго — `.frame(width:height:)` без `alignment` центрирует содержимое по вертикали, поэтому `ExpandedPanelView` (520×232), пока форма ещё маленькая, стоял посередине и «съезжал» на место. Решение: hosting view имеет `autoresizingMask = []` и всегда стоит на неподвижном холсте `NotchGeometry.canvasRect` (переведённом в координаты окна; frame hosting view выставляется в `NotchWindowController.apply(_:)` до `panel.setFrame`), контейнер обрезает всё, что вне окна (`clipsToBounds = true`), а в `NotchRootView` используется `.frame(width:height:alignment: .top)`. В итоге SwiftUI вообще не видит смены размера окна — меняется только «окошко» вокруг неподвижного холста, а стратегия «grow → animate → shrink» сохраняется без изменений.

## Последствия
- (+) В покое окно точно по форме → меню-бар не блокируется, 0% CPU (только события tracking area).
- (+) Логика состояний полностью покрыта unit-тестами.
- (−) Переходы требуют аккуратной последовательности «расширить frame → анимировать» и «анимировать → ужать frame»; ошибка даст 1-кадровое мерцание. Проверяется глазами (см. план TASK-001).
- (−) SwiftUI-контент не должен зависеть от размера окна: всё позиционирование — относительно холста `canvasRect` (выравнивание `.top`, центр по оси чёлки). Если кто-то вернёт autoresizing hosting view или центрирование по окну, «прыжок» формы вернётся.
- (−) Level `mainMenu + 3` — эмпирика; если в какой-то версии macOS окно окажется под меню — поднимаем до `.screenSaver - 1`, это одна строка.
