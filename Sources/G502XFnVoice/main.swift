import AppKit
import ApplicationServices
import CoreGraphics
import CoreHID
import Foundation
import G502XFnHIDCore
import G502XFnVoiceCore
import IOKit
import IOKit.hid
import IOKit.hidsystem
import OSLog
import ServiceManagement

private let logitechVendorID = 0x046d
private let g502XProductID = 0xc099
private let buttonUsagePage: UInt32 = 0x09
private let g6Usage: UInt32 = 5

private enum MouseSignal: Sendable {
    case g6(Bool)
    case deviceRemoved
    case devicesChanged
}

private enum BridgeCommand: @unchecked Sendable {
    case g6(Bool)
    case setEnabled(Bool)
    case settlementExpired(UInt64)
    case forceUp(String, CheckedContinuation<Void, Never>)
    case shutdown(CheckedContinuation<Void, Never>)
}

private final class VoiceHIDDelegate: HIDVirtualDeviceDelegate, @unchecked Sendable {
    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedSetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        data: Data
    ) async throws {}

    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedGetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        maxSize: Int
    ) async throws -> Data {
        Data(repeating: 0, count: min(maxSize, AppleFnKeyboard.reportLength))
    }
}

private struct G6ElementKey: Hashable {
    let deviceRegistryID: UInt64
    let cookie: UInt32
}

private final class MouseInputContext: @unchecked Sendable {
    private let lock = NSLock()
    private var elementStates: [G6ElementKey: Bool] = [:]
    private var aggregateIsDown = false
    let continuation: AsyncStream<MouseSignal>.Continuation

    init(continuation: AsyncStream<MouseSignal>.Continuation) {
        self.continuation = continuation
    }

    func receive(deviceRegistryID: UInt64, cookie: UInt32, isDown: Bool) {
        let transition: Bool?

        lock.lock()
        let key = G6ElementKey(deviceRegistryID: deviceRegistryID, cookie: cookie)
        if elementStates[key] == isDown {
            transition = nil
        } else {
            elementStates[key] = isDown
            let newAggregate = elementStates.values.contains(true)
            if newAggregate == aggregateIsDown {
                transition = nil
            } else {
                aggregateIsDown = newAggregate
                transition = newAggregate
            }
        }
        lock.unlock()

        if let transition {
            continuation.yield(.g6(transition))
        }
    }

    func removeDevice(registryID: UInt64) {
        lock.lock()
        elementStates.removeAll()
        aggregateIsDown = false
        lock.unlock()

        // Lifecycle cleanup uses deviceRemoved -> forceFnUpNow. Do not forge a
        // physical G6-up here, because only a real button release may send the
        // focused-text stop click.
        continuation.yield(.deviceRemoved)
        continuation.yield(.devicesChanged)
    }

    func reset() {
        lock.lock()
        elementStates.removeAll()
        aggregateIsDown = false
        lock.unlock()
    }
}

private func registryID(for device: IOHIDDevice) -> UInt64 {
    var value: UInt64 = 0
    let result = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &value)
    return result == KERN_SUCCESS ? value : 0
}

private func g6InputValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == buttonUsagePage,
          IOHIDElementGetUsage(element) == g6Usage else {
        return
    }

    let device = IOHIDElementGetDevice(element)
    let inputContext = Unmanaged<MouseInputContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    inputContext.receive(
        deviceRegistryID: registryID(for: device),
        cookie: UInt32(IOHIDElementGetCookie(element)),
        isDown: IOHIDValueGetIntegerValue(value) != 0
    )
}

private func mouseDeviceMatchedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    let inputContext = Unmanaged<MouseInputContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    inputContext.continuation.yield(.devicesChanged)
}

private func mouseDeviceRemovedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    let inputContext = Unmanaged<MouseInputContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    inputContext.removeDevice(registryID: registryID(for: device))
}

private struct FocusedTextInputIdentity {
    let element: AXUIElement
    let pid: pid_t
}

@MainActor
private func focusedTextInputIdentity(
    requiringCollapsedSelection: Bool = true
) -> FocusedTextInputIdentity? {
    guard AXIsProcessTrusted() else { return nil }

    var focusedValue: CFTypeRef?
    var focusedResult = AXUIElementCopyAttributeValue(
        AXUIElementCreateSystemWide(),
        kAXFocusedUIElementAttribute as CFString,
        &focusedValue
    )
    if focusedResult != .success,
       let frontmostApplication = NSWorkspace.shared.frontmostApplication {
        focusedValue = nil
        focusedResult = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(frontmostApplication.processIdentifier),
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
    }
    guard focusedResult == .success,
          let focusedValue,
          CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
        return nil
    }
    let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
    var focusedPID: pid_t = 0
    guard AXUIElementGetPid(focusedElement, &focusedPID) == .success,
          focusedPID > 0,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == focusedPID else {
        return nil
    }

    var roleValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        focusedElement,
        kAXRoleAttribute as CFString,
        &roleValue
    ) == .success,
    let role = roleValue as? String,
    role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) else {
        return nil
    }

    if requiringCollapsedSelection {
        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
        let selectedRangeValue,
        CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return nil
        }
        let selectedRangeAXValue = unsafeDowncast(selectedRangeValue, to: AXValue.self)
        var selectedRange = CFRange()
        guard AXValueGetType(selectedRangeAXValue) == .cfRange,
              AXValueGetValue(selectedRangeAXValue, .cfRange, &selectedRange),
              selectedRange.location >= 0,
              selectedRange.length == 0 else {
            return nil
        }
    }

    return FocusedTextInputIdentity(element: focusedElement, pid: focusedPID)
}

@MainActor
private final class StopClickCatcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class StopClickCatcherView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

@MainActor
private final class StopClickCatcher {
    enum Result: Equatable {
        case delivered
        case sentUnconfirmed(String)
        case notSent(String)
    }

    private let panel: StopClickCatcherPanel
    private let catcherView: StopClickCatcherView

    init() {
        panel = StopClickCatcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        catcherView = StopClickCatcherView(frame: panel.contentView?.bounds ?? .zero)
        catcherView.autoresizingMask = [.width, .height]
        catcherView.wantsLayer = true
        catcherView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.001).cgColor
        panel.contentView = catcherView
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 1
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    func cancel() {
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    func sendStopClick(
        expectedTextInput: FocusedTextInputIdentity,
        shouldAbort: @MainActor () -> Bool
    ) async -> Result {
        guard !shouldAbort() else {
            return .notSent("停止流程已被系统清理请求取消")
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            return .notSent("辅助功能或输入事件权限不可用")
        }
        guard !CGEventSource.buttonState(.hidSystemState, button: .left) else {
            return .notSent("实体左键正在按下")
        }
        guard let originalPointer = CGEvent(source: nil)?.location else {
            return .notSent("无法读取当前指针位置")
        }
        guard let initialScreen = screen(containingQuartzPoint: originalPointer) else {
            return .notSent("当前指针不在可用屏幕上")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedTextInput.pid else {
            return .notSent("前台应用已经改变")
        }
        var releaseFocusMatches = false
        for attempt in 0..<3 {
            if let currentTextInput = focusedTextInputIdentity(
                requiringCollapsedSelection: false
            ), currentTextInput.pid == expectedTextInput.pid,
            CFEqual(currentTextInput.element, expectedTextInput.element) {
                releaseFocusMatches = true
                break
            }
            guard attempt < 2 else { break }
            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return .notSent("等待输入焦点稳定时被取消")
            }
        }
        guard releaseFocusMatches else {
            return .notSent("输入焦点已经改变")
        }

        let expectedFrontmostPID = expectedTextInput.pid
        let token = Int64.random(in: 1...Int64.max)

        positionPanel(overQuartzPoint: originalPointer, on: initialScreen)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        defer { cancel() }

        var panelReady = false
        for _ in 0..<10 {
            guard !shouldAbort() else {
                return .notSent("停止流程已被系统清理请求取消")
            }
            if panelOwnsTopmostWindow(at: originalPointer) {
                panelReady = true
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return .notSent("透明停止层等待被取消")
            }
        }
        guard panelReady else {
            return .notSent("透明停止层未能安全置顶")
        }

        let source = CGEventSource(stateID: .hidSystemState)
        var stopClickWasSent = false
        for attempt in 0..<4 {
            guard !shouldAbort() else {
                return .notSent("停止流程已被系统清理请求取消")
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFrontmostPID else {
                return .notSent("点击前的前台应用已经改变")
            }
            if let latestTextInput = focusedTextInputIdentity(
                requiringCollapsedSelection: false
            ), latestTextInput.pid == expectedTextInput.pid,
            CFEqual(latestTextInput.element, expectedTextInput.element) {
                // The same text control is still active. Its selected range may
                // temporarily be unavailable while Doubao updates marked text.
            } else {
                panel.ignoresMouseEvents = true
                guard attempt < 3 else {
                    return .notSent("点击前的输入焦点已经改变")
                }
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return .notSent("等待点击前输入焦点稳定时被取消")
                }
                continue
            }
            guard !CGEventSource.buttonState(.hidSystemState, button: .left) else {
                return .notSent("点击前检测到实体左键正在按下")
            }
            guard let latestPointer = CGEvent(source: nil)?.location else {
                return .notSent("点击前无法读取当前指针位置")
            }

            if !panelOwnsTopmostWindow(at: latestPointer) {
                panel.ignoresMouseEvents = true
                guard attempt < 3 else {
                    return .notSent("指针持续移出透明停止层")
                }
                guard let latestScreen = screen(containingQuartzPoint: latestPointer) else {
                    return .notSent("移动后的指针不在可用屏幕上")
                }
                positionPanel(overQuartzPoint: latestPointer, on: latestScreen)
                panel.orderFrontRegardless()
                panel.displayIfNeeded()
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return .notSent("透明停止层跟随指针时被取消")
                }
                continue
            }

            panel.ignoresMouseEvents = false
            do {
                try await Task.sleep(for: .milliseconds(6))
            } catch {
                return .notSent("透明停止层启用被取消")
            }

            guard !shouldAbort() else {
                return .notSent("停止流程已被系统清理请求取消")
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFrontmostPID else {
                return .notSent("发送前的前台应用已经改变")
            }
            if let readyTextInput = focusedTextInputIdentity(
                requiringCollapsedSelection: false
            ), readyTextInput.pid == expectedTextInput.pid,
            CFEqual(readyTextInput.element, expectedTextInput.element) {
                // The same text control is still active.
            } else {
                panel.ignoresMouseEvents = true
                guard attempt < 3 else {
                    return .notSent("发送前的输入焦点已经改变")
                }
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return .notSent("等待发送前输入焦点稳定时被取消")
                }
                continue
            }
            guard !CGEventSource.buttonState(.hidSystemState, button: .left) else {
                return .notSent("发送前检测到实体左键正在按下")
            }
            guard let postingPointer = CGEvent(source: nil)?.location else {
                return .notSent("发送前无法读取当前指针位置")
            }
            guard panelOwnsTopmostWindow(at: postingPointer) else {
                panel.ignoresMouseEvents = true
                guard attempt < 3 else {
                    return .notSent("指针持续移出透明停止层")
                }
                continue
            }

            guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: postingPointer,
                mouseButton: .left
            ), let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: postingPointer,
                mouseButton: .left
            ) else {
                return .notSent("无法创建停止点击事件")
            }

            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: token)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
            }

            // Re-read the real pointer immediately before posting. If it moved
            // within the catcher, send at that current point; if it left the
            // catcher, re-arm instead of posting at a stale coordinate.
            guard !shouldAbort() else {
                return .notSent("发送前收到系统清理请求")
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFrontmostPID else {
                return .notSent("发送前的前台应用已经改变")
            }
            guard !CGEventSource.buttonState(.hidSystemState, button: .left) else {
                return .notSent("发送前检测到实体左键正在按下")
            }
            guard let finalPointer = CGEvent(source: nil)?.location else {
                return .notSent("发送前无法读取最终指针位置")
            }
            guard panelOwnsTopmostWindow(at: finalPointer) else {
                panel.ignoresMouseEvents = true
                guard attempt < 3 else {
                    return .notSent("指针持续移出透明停止层")
                }
                continue
            }
            down.location = finalPointer
            up.location = finalPointer

            down.post(tap: .cghidEventTap)
            do {
                try await Task.sleep(for: .milliseconds(12))
            } catch {
                // A matching mouse-up must still be posted after every mouse-down.
            }
            if let currentPointer = CGEvent(source: nil)?.location {
                up.location = currentPointer
            }
            up.post(tap: .cghidEventTap)

            // The click has already been posted. Stop intercepting real mouse
            // input immediately; AppKit receipt is not part of correctness.
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            stopClickWasSent = true
            break
        }
        guard stopClickWasSent else {
            return .notSent("透明停止层无法跟随当前指针")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFrontmostPID,
              let finalTextInput = focusedTextInputIdentity(
                requiringCollapsedSelection: false
              ),
              finalTextInput.pid == expectedTextInput.pid,
              CFEqual(finalTextInput.element, expectedTextInput.element) else {
            return .sentUnconfirmed("停止点击后无法确认输入焦点保持不变")
        }
        return .delivered
    }

    private func screen(containingQuartzPoint point: CGPoint) -> NSScreen? {
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let cocoaPoint = CGPoint(x: point.x, y: mainScreen.frame.maxY - point.y)
        return NSScreen.screens.first { $0.frame.contains(cocoaPoint) }
    }

    private func positionPanel(overQuartzPoint point: CGPoint, on screen: NSScreen) {
        guard let mainScreen = NSScreen.screens.first else { return }
        let cocoaPoint = CGPoint(x: point.x, y: mainScreen.frame.maxY - point.y)
        let size = CGSize(width: 64, height: 64)
        let origin = CGPoint(
            x: min(max(cocoaPoint.x - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width),
            y: min(max(cocoaPoint.y - size.height / 2, screen.frame.minY), screen.frame.maxY - size.height)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func panelOwnsTopmostWindow(at point: CGPoint) -> Bool {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            CGWindowID(kCGNullWindowID)
        ) as? [[String: Any]] else {
            return false
        }
        for window in windowInfo {
            guard let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue > 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(point) else {
                continue
            }
            let windowNumber = (window[kCGWindowNumber as String] as? NSNumber)?.intValue
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            return windowNumber == panel.windowNumber
                && ownerPID == ProcessInfo.processInfo.processIdentifier
        }
        return false
    }
}

@MainActor
private final class VoiceAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = Logger(
        subsystem: "com.handev.g502x-fn-voice",
        category: "bridge"
    )
    private let hidDelegate = VoiceHIDDelegate()
    private let stopClickCatcher = StopClickCatcher()
    private let defaults = UserDefaults.standard

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem!
    private var enabledMenuItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!
    private var inputMonitoringMenuItem: NSMenuItem!
    private var accessibilityMenuItem: NSMenuItem!

    private var virtualKeyboard: HIDVirtualDevice?
    private var manager: IOHIDManager?
    private var managerRunLoop: CFRunLoop?
    private var inputContext: MouseInputContext?
    private var eventTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<BridgeCommand>.Continuation!
    private var commandTask: Task<Void, Never>?
    private var settlementTask: Task<Void, Never>?

    private var mappingEnabled = true
    private var listening = false
    private var deviceCount = 0
    private var fnIsDown = false
    private var voiceState = VoiceReleaseStateMachine()
    private var pendingTextInput: FocusedTextInputIdentity?
    private var lastError: String?
    private var virtualKeyboardGeneration: UInt64 = 0
    private var isSystemSleeping = false
    private var preparingToTerminate = false
    private var cleanupRequested = false
    private var terminationCleanupStarted = false
    private var allowTermination = false

    private let mappingEnabledKey = "mappingEnabled"
    private let launchAtLoginDesiredKey = "launchAtLoginDesired"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else {
            allowTermination = true
            NSApp.terminate(nil)
            return
        }

        loadDefaults()
        makeStatusMenu()
        startCommandProcessor()
        observeWorkspaceLifecycle()
        configureLaunchAtLoginIfNeeded()

        Task { @MainActor [weak self] in
            await self?.prepareBridge()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTermination { return .terminateNow }
        if !preparingToTerminate {
            preparingToTerminate = true
            cleanupRequested = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.prepareForTermination(reason: "user-quit")
                self.allowTermination = true
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuUI()
    }

    private func ensureSingleInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .allSatisfy { $0.processIdentifier == ownPID }
    }

    private func loadDefaults() {
        if defaults.object(forKey: mappingEnabledKey) == nil {
            defaults.set(true, forKey: mappingEnabledKey)
        }
        if defaults.object(forKey: launchAtLoginDesiredKey) == nil {
            defaults.set(true, forKey: launchAtLoginDesiredKey)
        }
        mappingEnabled = defaults.bool(forKey: mappingEnabledKey)
    }

    private func makeStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "G502 X 豆包语音"

        menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "正在启动……", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        enabledMenuItem = NSMenuItem(
            title: "启用 G6 → Fn",
            action: #selector(toggleMapping),
            keyEquivalent: ""
        )
        enabledMenuItem.target = self
        menu.addItem(enabledMenuItem)

        loginMenuItem = NSMenuItem(
            title: "开机自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)

        inputMonitoringMenuItem = NSMenuItem(
            title: "授予/重新检查输入监控权限……",
            action: #selector(requestInputMonitoring),
            keyEquivalent: ""
        )
        inputMonitoringMenuItem.target = self
        menu.addItem(inputMonitoringMenuItem)

        accessibilityMenuItem = NSMenuItem(
            title: "授予/重新检查辅助功能权限……",
            action: #selector(requestAccessibility),
            keyEquivalent: ""
        )
        accessibilityMenuItem.target = self
        menu.addItem(accessibilityMenuItem)

        let reconnectItem = NSMenuItem(
            title: "重新连接 G502 X",
            action: #selector(reconnectMouse),
            keyEquivalent: "r"
        )
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(.separator())
        let scopeItem = NSMenuItem(
            title: "仅监听 G502 X 的 G6（其他按键不变）",
            action: nil,
            keyEquivalent: ""
        )
        scopeItem.isEnabled = false
        menu.addItem(scopeItem)

        let quitItem = NSMenuItem(
            title: "退出 G502 X 豆包语音",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuUI()
    }

    private func observeWorkspaceLifecycle() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func startCommandProcessor() {
        var continuation: AsyncStream<BridgeCommand>.Continuation!
        let stream = AsyncStream<BridgeCommand> { continuation = $0 }
        commandContinuation = continuation
        commandTask = Task { @MainActor [weak self] in
            for await command in stream {
                guard let self else { return }
                if await self.processBridgeCommand(command) {
                    return
                }
            }
        }
    }

    private func processBridgeCommand(_ command: BridgeCommand) async -> Bool {
        switch command {
        case .g6(let isDown):
            await processG6(isDown: isDown)
            return false

        case .setEnabled(let enabled):
            mappingEnabled = enabled
            if enabled {
                cleanupRequested = false
                lastError = nil
                if !(await activateVirtualKeyboardIfNeeded()) {
                    mappingEnabled = false
                    defaults.set(false, forKey: mappingEnabledKey)
                }
            } else {
                await forceFnUpNow(reason: "mapping-disabled")
            }
            updateMenuUI()
            return false

        case .settlementExpired(let token):
            settlementTask = nil
            await applyVoiceEffects(
                voiceState.handle(.settlementExpired(token: token))
            )
            updateMenuUI()
            return false

        case .forceUp(let reason, let continuation):
            await forceFnUpNow(reason: reason)
            continuation.resume()
            return false

        case .shutdown(let continuation):
            mappingEnabled = false
            await forceFnUpNow(reason: "shutdown")
            try? await Task.sleep(for: .milliseconds(300))
            cancelAndDropVirtualKeyboard()
            continuation.resume()
            return true
        }
    }

    private func enqueueForceUp(reason: String) async {
        guard commandContinuation != nil else { return }
        await withCheckedContinuation { continuation in
            commandContinuation.yield(.forceUp(reason, continuation))
        }
    }

    private func enqueueShutdown() async {
        guard commandContinuation != nil else { return }
        await withCheckedContinuation { continuation in
            commandContinuation.yield(.shutdown(continuation))
        }
        commandContinuation.finish()
    }

    private func configureLaunchAtLoginIfNeeded() {
        guard defaults.bool(forKey: launchAtLoginDesiredKey),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            logger.notice("Login launch skipped outside /Applications or disabled")
            updateMenuUI()
            return
        }

        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            logger.notice("Login launch status: enabled")
            updateMenuUI()
            return
        case .requiresApproval:
            logger.notice("Login launch status: requires approval")
            updateMenuUI()
            return
        case .notFound:
            logger.notice("Login launch status: service not found; attempting registration")
        case .notRegistered:
            break
        @unknown default:
            logger.error("Login launch status: unknown")
            updateMenuUI()
            return
        }

        do {
            try service.register()
            logger.notice(
                "Login launch registered; new status=\(String(describing: service.status), privacy: .public)"
            )
        } catch {
            logger.error("Login launch registration failed: \(error.localizedDescription, privacy: .public)")
        }
        updateMenuUI()
    }

    private func makeVirtualKeyboard() -> HIDVirtualDevice? {
        virtualKeyboardGeneration &+= 1
        let properties = HIDVirtualDevice.Properties(
            descriptor: AppleFnKeyboard.reportDescriptor,
            vendorID: 1,
            productID: 1,
            transport: .virtual,
            product: "G502 X Fn Voice Keyboard",
            manufacturer: "Local G502 X Fn Voice",
            uniqueID: "local.g502x-fn-voice.keyboard.\(virtualKeyboardGeneration)",
            extraProperties: [
                "Built-In": NSNumber(value: true),
                "AppleVendorSupported": NSNumber(value: true),
                "HIDDefaultBehavior": NSNumber(value: true),
                // Match this Mac's built-in keyboard type. Without this,
                // IOHIDKeyboardFilter classifies the virtual keyboard as the
                // generic ANSI type (3), while physical Fn events use 91.
                kIOHIDAltHandlerIdKey as String: NSNumber(value: 91),
            ]
        )
        return HIDVirtualDevice(properties: properties)
    }

    private func prepareBridge() async {
        lastError = nil

        guard Bundle.main.bundleIdentifier != nil else {
            lastError = "应用缺少 Bundle ID"
            updateMenuUI()
            return
        }

        guard await activateVirtualKeyboardIfNeeded() else { return }

        guard !preparingToTerminate else { return }
        await enqueueForceUp(reason: "startup")
        guard !preparingToTerminate else { return }
        requestInputMonitoringIfUnknown()
        requestAccessibilityIfNeeded()
        startMouseListening()
    }

    private func activateVirtualKeyboardIfNeeded() async -> Bool {
        if virtualKeyboard != nil { return true }

        guard let device = makeVirtualKeyboard() else {
            lastError = "无法创建临时 Fn 键盘"
            updateMenuUI()
            return false
        }

        virtualKeyboard = device
        await device.activate(delegate: hidDelegate)
        try? await Task.sleep(for: .milliseconds(350))
        return true
    }

    private func requestInputMonitoringIfUnknown() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        logger.notice(
            "Input monitoring status before request: \(String(describing: access), privacy: .public)"
        )
        if access == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    private func hasInputMonitoringAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func hasVoiceInputAccess() -> Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess()
    }

    private func requestAccessibilityIfNeeded() {
        guard !hasVoiceInputAccess() else { return }
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
        logger.notice("Accessibility/PostEvent permission requested")
        updateMenuUI()
    }

    private func startMouseListening() {
        stopMouseListening()

        guard hasInputMonitoringAccess() else {
            lastError = "需要输入监控权限"
            logger.notice("Mouse listener paused: input monitoring not granted")
            updateMenuUI()
            return
        }

        var continuation: AsyncStream<MouseSignal>.Continuation!
        let stream = AsyncStream<MouseSignal> { continuation = $0 }
        let context = MouseInputContext(continuation: continuation)
        inputContext = context

        let hidManager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        let deviceMatching: [String: Any] = [
            kIOHIDVendorIDKey: logitechVendorID,
            kIOHIDProductIDKey: g502XProductID,
        ]
        let inputMatching: [String: Any] = [
            kIOHIDElementUsagePageKey: buttonUsagePage,
            kIOHIDElementUsageKey: g6Usage,
        ]
        IOHIDManagerSetDeviceMatching(hidManager, deviceMatching as CFDictionary)
        IOHIDManagerSetInputValueMatching(hidManager, inputMatching as CFDictionary)

        let opaqueContext = Unmanaged.passUnretained(context).toOpaque()
        IOHIDManagerRegisterInputValueCallback(
            hidManager,
            g6InputValueCallback,
            opaqueContext
        )
        IOHIDManagerRegisterDeviceMatchingCallback(
            hidManager,
            mouseDeviceMatchedCallback,
            opaqueContext
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            hidManager,
            mouseDeviceRemovedCallback,
            opaqueContext
        )

        guard let runLoop = CFRunLoopGetMain() else {
            lastError = "无法访问应用运行循环"
            discardManager(hidManager, runLoop: nil, context: context)
            updateMenuUI()
            return
        }
        IOHIDManagerScheduleWithRunLoop(
            hidManager,
            runLoop,
            CFRunLoopMode.defaultMode.rawValue
        )

        let openResult = IOHIDManagerOpen(
            hidManager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard openResult == kIOReturnSuccess else {
            discardManager(hidManager, runLoop: runLoop, context: context)
            lastError = "无法监听 G502 X（错误 \(openResult)）"
            updateMenuUI()
            return
        }

        manager = hidManager
        managerRunLoop = runLoop
        listening = true
        refreshDeviceCount()
        cleanupRequested = false
        lastError = nil
        logger.notice("Mouse listener ready; services=\(self.deviceCount)")

        eventTask = Task { @MainActor [weak self] in
            for await signal in stream {
                guard let self else { return }
                switch signal {
                case .g6(let isDown):
                    self.commandContinuation.yield(.g6(isDown))
                case .deviceRemoved:
                    self.cleanupRequested = true
                    await self.enqueueForceUp(reason: "device-removed")
                case .devicesChanged:
                    self.refreshDeviceCount()
                }
            }
        }
        updateMenuUI()
    }

    private func processG6(isDown: Bool) async {
        if isDown {
            if voiceState.phase != .idle {
                await applyVoiceEffects(voiceState.handle(.g6Down))
                updateMenuUI()
                return
            }
            guard mappingEnabled,
                  defaults.bool(forKey: mappingEnabledKey),
                  !isSystemSleeping,
                  !preparingToTerminate,
                  virtualKeyboard != nil else {
                if fnIsDown {
                    await forceFnUpNow(reason: "down-rejected")
                }
                return
            }
            guard !fnIsDown else { return }
            guard hasVoiceInputAccess() else {
                logger.notice("G6 down ignored: Accessibility/PostEvent permission missing")
                updateMenuUI()
                return
            }
            guard let textInput = focusedTextInputIdentity() else {
                lastError = "请先把光标放入可识别的文本输入框"
                logger.notice("G6 down ignored: no safe focused text control")
                updateMenuUI()
                return
            }

            cleanupRequested = false
            pendingTextInput = textInput
            await applyVoiceEffects(voiceState.handle(.g6Down))
            updateMenuUI()
            return
        }

        if fnIsDown, virtualKeyboard == nil {
            await forceFnUpNow(reason: "missing-virtual-keyboard-on-release")
            return
        }
        let previousPhase = voiceState.phase
        await applyVoiceEffects(voiceState.handle(.g6Up))
        if previousPhase == .blockedUntilPhysicalUp, voiceState.phase == .idle {
            lastError = nil
        }
        updateMenuUI()
    }

    private func applyVoiceEffects(
        _ effects: [VoiceReleaseStateMachine.Effect]
    ) async {
        for effect in effects {
            switch effect {
            case .sendFnDown:
                guard let device = virtualKeyboard else {
                    await forceFnUpNow(reason: "missing-virtual-keyboard-on-press")
                    return
                }
                do {
                    try await dispatchFn(pressed: true, using: device)
                    fnIsDown = true
                    lastError = nil
                    logger.notice("G6 down -> Fn down; isolated stop click armed")
                } catch {
                    await handleFnDispatchFailure(error)
                    return
                }

            case .sendStopClick(let token):
                guard fnIsDown, let pendingTextInput else {
                    await applyVoiceEffects(
                        voiceState.handle(.clickFinished(token: token, succeeded: false))
                    )
                    return
                }
                let result = await stopClickCatcher.sendStopClick(
                    expectedTextInput: pendingTextInput,
                    shouldAbort: { [weak self] in
                        guard let self else { return true }
                        return self.cleanupRequested
                            || self.preparingToTerminate
                            || self.isSystemSleeping
                            || !self.mappingEnabled
                            || !self.defaults.bool(forKey: self.mappingEnabledKey)
                    }
                )
                switch result {
                case .delivered:
                    logger.notice("G6 up -> isolated stop click delivered; Fn remains down during settlement")
                    await applyVoiceEffects(
                        voiceState.handle(.clickFinished(token: token, succeeded: true))
                    )
                case .sentUnconfirmed(let reason):
                    logger.notice("Isolated stop click was sent without AppKit receipt: \(reason, privacy: .public)")
                    await applyVoiceEffects(
                        voiceState.handle(.clickFinished(token: token, succeeded: true))
                    )
                case .notSent(let reason):
                    logger.error("Isolated stop click was not sent: \(reason, privacy: .public)")
                    await applyVoiceEffects(
                        voiceState.handle(.clickFinished(token: token, succeeded: false))
                    )
                }

            case .scheduleFnCleanup(let token, let milliseconds):
                scheduleFnCleanup(token: token, milliseconds: milliseconds)
                lastError = nil
                logger.notice("Voice settlement scheduled for \(milliseconds) ms")

            case .cancelFnCleanup:
                settlementTask?.cancel()
                settlementTask = nil

            case .sendFnUp:
                guard let device = virtualKeyboard else {
                    fnIsDown = false
                    pendingTextInput = nil
                    continue
                }
                do {
                    try await dispatchFn(pressed: false, using: device)
                    fnIsDown = false
                    pendingTextInput = nil
                    if voiceState.phase == .idle {
                        lastError = nil
                    } else if voiceState.phase == .blockedUntilPhysicalUp {
                        lastError = "请松开 G6，再开始下一段语音"
                    }
                    logger.notice("Settlement complete -> Fn up cleanup")
                } catch {
                    await handleFnDispatchFailure(error)
                    return
                }

            case .rejectG6Press:
                lastError = "上一段正在完成，请松开 G6 后重试"
                logger.notice("G6 press rejected during voice settlement")

            case .reportStopFailure:
                lastError = "安全停止点击失败；请用实体左键停止"
                logger.error("G6 release fell back to Fn up only; no text-control click was sent")
            }
        }
        updateMenuUI()
    }

    private func scheduleFnCleanup(token: UInt64, milliseconds: UInt64) {
        settlementTask?.cancel()
        settlementTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .milliseconds(Int64(clamping: milliseconds))
                )
            } catch {
                return
            }
            self?.commandContinuation.yield(.settlementExpired(token))
        }
    }

    private func handleFnDispatchFailure(_ error: Error) async {
        lastError = "Fn 转换失败"
        logger.error("Fn dispatch failed: \(error.localizedDescription, privacy: .public)")
        mappingEnabled = false
        defaults.set(false, forKey: mappingEnabledKey)
        await forceFnUpNow(reason: "dispatch-error")
    }

    // Only the single command consumer may call this method.
    private func forceFnUpNow(reason: String) async {
        settlementTask?.cancel()
        settlementTask = nil
        stopClickCatcher.cancel()
        _ = voiceState.handle(.forceCleanup)
        if reason != "dispatch-error" {
            lastError = nil
        }
        if let device = virtualKeyboard {
            do {
                try await dispatchFn(pressed: false, using: device)
            } catch {
                cancelAndDropVirtualKeyboard(expected: device)
                fnIsDown = false
                mappingEnabled = false
                defaults.set(false, forKey: mappingEnabledKey)
                lastError = "Fn 释放失败，已安全停用；请重新启用"
                logger.fault(
                    "Fn cleanup failed; virtual keyboard destroyed: \(error.localizedDescription, privacy: .public)"
                )
                updateMenuUI()
                return
            }
        }
        fnIsDown = false
        pendingTextInput = nil
        logger.notice("Fn up cleanup: \(reason, privacy: .public)")
        updateMenuUI()
    }

    private func dispatchFn(pressed: Bool, using device: HIDVirtualDevice) async throws {
        let report = AppleFnKeyboard.inputReport(fnPressed: pressed)
        try await device.dispatchInputReport(data: report, timestamp: .now)
    }

    private func cancelAndDropVirtualKeyboard(expected: HIDVirtualDevice? = nil) {
        guard let device = virtualKeyboard else { return }
        if let expected, expected != device { return }
        if #available(macOS 26.0, *), let hidDevice = device.hidDevice {
            IOHIDUserDeviceCancel(hidDevice)
        }
        virtualKeyboard = nil
    }

    private func refreshDeviceCount() {
        deviceCount = manager.flatMap(IOHIDManagerCopyDevices).map(CFSetGetCount) ?? 0
        updateMenuUI()
    }

    private func stopMouseListening() {
        eventTask?.cancel()
        eventTask = nil
        inputContext?.reset()

        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            if let runLoop = managerRunLoop {
                IOHIDManagerUnscheduleFromRunLoop(
                    manager,
                    runLoop,
                    CFRunLoopMode.defaultMode.rawValue
                )
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        inputContext?.continuation.finish()

        self.manager = nil
        managerRunLoop = nil
        inputContext = nil
        listening = false
        deviceCount = 0
    }

    private func discardManager(
        _ manager: IOHIDManager,
        runLoop: CFRunLoop?,
        context: MouseInputContext
    ) {
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        if let runLoop {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                runLoop,
                CFRunLoopMode.defaultMode.rawValue
            )
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        context.continuation.finish()
        if inputContext === context {
            inputContext = nil
        }
        listening = false
        deviceCount = 0
    }

    private func updateMenuUI() {
        guard statusItem != nil else { return }

        let inputAccessGranted = hasInputMonitoringAccess()
        let clickAccessGranted = hasVoiceInputAccess()
        let statusText: String
        let symbolName: String

        if let lastError {
            statusText = lastError
            symbolName = "exclamationmark.triangle"
        } else if !mappingEnabled {
            statusText = "已停用 G6 → Fn"
            symbolName = "mic.slash"
        } else if !inputAccessGranted {
            statusText = "需要输入监控权限"
            symbolName = "lock.trianglebadge.exclamationmark"
        } else if !clickAccessGranted {
            statusText = "需要辅助功能权限"
            symbolName = "lock.trianglebadge.exclamationmark"
        } else {
            switch voiceState.phase {
            case .held:
                statusText = "正在语音输入（G6 已按住）"
                symbolName = "waveform.circle.fill"
            case .clickPending:
                statusText = "正在安全停止语音……"
                symbolName = "stop.circle.fill"
            case .settling:
                statusText = "正在完成上一段语音……"
                symbolName = "hourglass.circle.fill"
            case .blockedUntilPhysicalUp:
                statusText = "请先松开 G6"
                symbolName = "hand.raised.circle"
            case .idle:
                if listening && deviceCount > 0 {
                    statusText = "G502 X 已连接，G6 可用"
                    symbolName = "mic.circle.fill"
                } else if listening {
                    statusText = "未检测到 G502 X"
                    symbolName = "mic.circle"
                } else {
                    statusText = "正在启动……"
                    symbolName = "ellipsis.circle"
                }
            }
        }

        statusMenuItem?.title = statusText
        enabledMenuItem?.state = mappingEnabled ? .on : .off
        inputMonitoringMenuItem?.isHidden = inputAccessGranted
        accessibilityMenuItem?.isHidden = clickAccessGranted
        updateLoginMenuItem()

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: statusText)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "G502 X 豆包语音：\(statusText)"
    }

    private func updateLoginMenuItem() {
        guard loginMenuItem != nil else { return }
        switch SMAppService.mainApp.status {
        case .enabled:
            loginMenuItem.title = "开机自动启动"
            loginMenuItem.state = .on
        case .requiresApproval:
            loginMenuItem.title = "开机自动启动（需要系统批准）"
            loginMenuItem.state = .mixed
        case .notRegistered, .notFound:
            loginMenuItem.title = "开机自动启动"
            loginMenuItem.state = .off
        @unknown default:
            loginMenuItem.title = "开机自动启动"
            loginMenuItem.state = .off
        }
    }

    @objc private func toggleMapping() {
        let newValue = !defaults.bool(forKey: mappingEnabledKey)
        defaults.set(newValue, forKey: mappingEnabledKey)
        if !newValue {
            cleanupRequested = true
            inputContext?.reset()
        }
        commandContinuation.yield(.setEnabled(newValue))
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                defaults.set(false, forKey: launchAtLoginDesiredKey)
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
                defaults.set(true, forKey: launchAtLoginDesiredKey)
            @unknown default:
                break
            }
        } catch {
            logger.error("Login launch toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        updateMenuUI()
    }

    @objc private func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if !hasInputMonitoringAccess(),
           let settingsURL = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
           ) {
            NSWorkspace.shared.open(settingsURL)
        }
        reconnectMouse()
    }

    @objc private func requestAccessibility() {
        requestAccessibilityIfNeeded()
        if !hasVoiceInputAccess(),
           let settingsURL = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
           ) {
            NSWorkspace.shared.open(settingsURL)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.updateMenuUI()
        }
    }

    @objc private func reconnectMouse() {
        cleanupRequested = true
        stopMouseListening()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.enqueueForceUp(reason: "manual-reconnect")
            guard await self.activateVirtualKeyboardIfNeeded() else { return }
            self.lastError = nil
            self.startMouseListening()
        }
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        isSystemSleeping = true
        cleanupRequested = true
        stopMouseListening()
        Task { @MainActor [weak self] in
            await self?.enqueueForceUp(reason: "system-sleep")
        }
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        isSystemSleeping = false
        reconnectMouse()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func prepareForTermination(reason: String) async {
        guard !terminationCleanupStarted else { return }
        terminationCleanupStarted = true
        preparingToTerminate = true
        stopMouseListening()
        await enqueueShutdown()
        commandTask?.cancel()
        commandTask = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

@main
private enum G502XFnVoice {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = VoiceAppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
