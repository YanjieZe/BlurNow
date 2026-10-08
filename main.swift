import Cocoa
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

// 按全局快捷键遮挡屏幕；任意键盘 / 鼠标 / 触控板操作即退出。点开 app 打开设置。
// 模糊用 NSVisualEffectView 的 behindWindow 模式，快捷键用 Carbon RegisterEventHotKey，
// 都不需要屏幕录制或辅助功能权限。

let gracePeriod: TimeInterval = 0.8   // 遮挡后忽略输入的时间，避免触发它的那一下直接退出
let mouseThreshold: CGFloat = 6       // 鼠标移动超过这个距离（pt）才算“动了”

// MARK: - Preferences

enum CoverMode: String, CaseIterable, Identifiable {
    case blur, wallpaper, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blur: "Blur"
        case .wallpaper: "Wallpaper"
        case .image: "Image"
        }
    }
}

enum BlurStyle: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Pref {
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"   // Carbon modifier mask
    static let hotKeyDisplay = "hotKeyDisplay"
    static let mode = "mode"
    static let style = "style"
    static let strength = "strength"                 // 0...0.95，叠加层不透明度
    static let imagePath = "imagePath"
    static let hideCursor = "hideCursor"
    static let exitOnMouseMove = "exitOnMouseMove"
    static let didSetupLoginItem = "didSetupLoginItem"

    static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            hotKeyCode: kVK_ANSI_B,
            hotKeyModifiers: controlKey | optionKey | cmdKey,
            hotKeyDisplay: "⌃⌥⌘B",
            mode: CoverMode.blur.rawValue,
            style: BlurStyle.auto.rawValue,
            strength: 0.0,
            imagePath: "",
            hideCursor: true,
            exitOnMouseMove: true,
        ])
    }
}

func carbonModifiers(_ f: NSEvent.ModifierFlags) -> Int {
    var m = 0
    if f.contains(.command) { m |= cmdKey }
    if f.contains(.option) { m |= optionKey }
    if f.contains(.control) { m |= controlKey }
    if f.contains(.shift) { m |= shiftKey }
    return m
}

func shortcutDisplay(_ f: NSEvent.ModifierFlags, keyCode: Int, chars: String?) -> String {
    var s = ""
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option) { s += "⌥" }
    if f.contains(.shift) { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    return s + (special[keyCode] ?? (chars ?? "?").uppercased())
}

// MARK: - App

final class BlurWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false
    private var previousApp: NSRunningApplication?
    private var blurStart = Date.distantPast
    private var anchorMouse = NSPoint.zero
    private var lastFlags: NSEvent.ModifierFlags = []
    private var cursorHidden = false
    private var dismissing = false

    private var isBlurred: Bool { !windows.isEmpty }
    private var inGrace: Bool { Date().timeIntervalSince(blurStart) < gracePeriod }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        installMainMenu()
        registerHotKey()
        installMonitors()
        setupLoginItemOnFirstRun()
        if isUserLaunch() { showSettings() }
    }

    // 已在后台运行时再次点击 Dock 图标 / Spotlight 打开
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // blurnow://blur | unblur | toggle | settings
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "blurnow" {
            switch url.host {
            case "blur": blur()
            case "unblur": dismiss()
            case "toggle": toggle()
            case "settings": showSettings()
            default: break
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if isBlurred && !inGrace { dismiss() }
    }

    func toggle() {
        isBlurred ? dismiss() : blur()
    }

    // MARK: Settings window

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "BlurNow"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit BlurNow",
                                 action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(withTitle: "Close",
                                    action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(appItem)
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: Blur

    func blur() {
        guard !isBlurred else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        for screen in NSScreen.screens {
            let w = BlurWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.contentView = makeCover(for: screen)
            w.alphaValue = 0
            w.orderFrontRegardless()
            windows.append(w)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        if Pref.d.bool(forKey: Pref.hideCursor) && !cursorHidden { NSCursor.hide(); cursorHidden = true }

        blurStart = Date()
        anchorMouse = NSEvent.mouseLocation
        lastFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            windows.forEach { $0.animator().alphaValue = 1 }
        }
        // 轮询鼠标位置：不依赖事件分发，多屏时也可靠
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkMouse()
        }
    }

    func dismiss() {
        guard isBlurred, !dismissing else { return }
        dismissing = true
        pollTimer?.invalidate()
        pollTimer = nil
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        NSApp.presentationOptions = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [self] in
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
            dismissing = false
            // 把焦点还给之前的 app；从设置里预览时 previousApp 为 nil，留在设置窗口
            if let previousApp { previousApp.activate(options: []) }
            else if settingsWindow?.isVisible != true { NSApp.hide(nil) }
            previousApp = nil
        })
    }

    private func makeCover(for screen: NSScreen) -> NSView {
        let frame = NSRect(origin: .zero, size: screen.frame.size)
        let mode = CoverMode(rawValue: Pref.d.string(forKey: Pref.mode) ?? "") ?? .blur

        var image: NSImage?
        switch mode {
        case .wallpaper:
            image = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        case .image:
            image = NSImage(contentsOfFile: Pref.d.string(forKey: Pref.imagePath) ?? "")
        case .blur:
            break
        }
        if let image {
            let v = NSView(frame: frame)
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.cgColor
            v.layer?.contents = image
            v.layer?.contentsGravity = .resizeAspectFill
            v.layer?.masksToBounds = true
            return v
        }

        // 图片加载失败时也回退到模糊
        let style = BlurStyle(rawValue: Pref.d.string(forKey: Pref.style) ?? "") ?? .auto
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        switch style {
        case .light: blur.appearance = NSAppearance(named: .aqua)
        case .dark: blur.appearance = NSAppearance(named: .darkAqua)
        case .auto: break
        }
        let dark = style == .dark ||
            (style == .auto && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let overlay = NSView(frame: frame)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white)
            .withAlphaComponent(Pref.d.double(forKey: Pref.strength)).cgColor
        blur.addSubview(overlay)
        return blur
    }

    // MARK: Input

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .mouseMoved,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .scrollWheel, .magnify, .swipe]
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            guard let self, self.isBlurred else { return e }
            self.handle(e)
            return nil
        }
        // 全局 monitor 兜底（鼠标类事件不需要辅助功能权限）
        NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            guard let self, self.isBlurred else { return }
            self.handle(e)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged:
            checkMouse()
        case .flagsChanged:
            // 只在“按下”修饰键时退出；松开快捷键的修饰键不算
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let pressed = !flags.isSubset(of: lastFlags)
            lastFlags = flags
            if pressed && !inGrace { dismiss() }
        default:
            if !inGrace { dismiss() }
        }
    }

    private func checkMouse() {
        let p = NSEvent.mouseLocation
        if inGrace { anchorMouse = p; return }
        guard Pref.d.bool(forKey: Pref.exitOnMouseMove) else { return }
        if hypot(p.x - anchorMouse.x, p.y - anchorMouse.y) > mouseThreshold { dismiss() }
    }

    // MARK: Hotkey

    @discardableResult
    func registerHotKey() -> Bool {
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { delegate.toggle() }
                return noErr
            }, 1, &spec, nil, nil)
            hotKeyHandlerInstalled = true
        }
        unregisterHotKey()
        let id = EventHotKeyID(signature: OSType(0x424C5552) /* 'BLUR' */, id: 1)
        let status = RegisterEventHotKey(UInt32(Pref.d.integer(forKey: Pref.hotKeyCode)),
                                         UInt32(Pref.d.integer(forKey: Pref.hotKeyModifiers)),
                                         id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            NSLog("BlurNow: failed to register hotkey (\(status))")
            return false
        }
        return true
    }

    func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// 保存新快捷键；注册失败（被其他 app 占用）时恢复旧的
    func setHotKey(code: Int, modifiers: NSEvent.ModifierFlags, chars: String?) {
        let d = Pref.d
        let old = (d.integer(forKey: Pref.hotKeyCode), d.integer(forKey: Pref.hotKeyModifiers),
                   d.string(forKey: Pref.hotKeyDisplay))
        d.set(code, forKey: Pref.hotKeyCode)
        d.set(carbonModifiers(modifiers), forKey: Pref.hotKeyModifiers)
        d.set(shortcutDisplay(modifiers, keyCode: code, chars: chars), forKey: Pref.hotKeyDisplay)
        if !registerHotKey() {
            d.set(old.0, forKey: Pref.hotKeyCode)
            d.set(old.1, forKey: Pref.hotKeyModifiers)
            d.set(old.2, forKey: Pref.hotKeyDisplay)
            registerHotKey()
            NSSound.beep()
        }
    }

    // MARK: Launch

    private func setupLoginItemOnFirstRun() {
        guard !Pref.d.bool(forKey: Pref.didSetupLoginItem),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        Pref.d.set(true, forKey: Pref.didSetupLoginItem)
        do { try SMAppService.mainApp.register() }
        catch { NSLog("BlurNow: failed to register login item (\(error))") }
    }

    /// 用户手动打开时显示设置；登录项启动或 URL 启动时保持静默
    private func isUserLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return true }
        guard event.eventID == kAEOpenApplication else { return false }
        if event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return false
        }
        return ProcessInfo.processInfo.systemUptime > 120
    }
}

// MARK: - Settings UI

struct HotKeyRecorder: View {
    @AppStorage(Pref.hotKeyDisplay) private var display = "⌃⌥⌘B"
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type shortcut…" : display) { recording ? stop() : start() }
            .frame(minWidth: 120)
    }

    private func start() {
        recording = true
        delegate.unregisterHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == kVK_Escape { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods.isDisjoint(with: [.command, .option, .control]) { NSSound.beep(); return nil }
            delegate.setHotKey(code: Int(e.keyCode), modifiers: mods, chars: e.charactersIgnoringModifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        delegate.registerHotKey()
    }
}

struct SettingsView: View {
    @AppStorage(Pref.mode) private var mode = CoverMode.blur.rawValue
    @AppStorage(Pref.style) private var style = BlurStyle.auto.rawValue
    @AppStorage(Pref.strength) private var strength = 0.0
    @AppStorage(Pref.imagePath) private var imagePath = ""
    @AppStorage(Pref.hideCursor) private var hideCursor = true
    @AppStorage(Pref.exitOnMouseMove) private var exitOnMouseMove = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") { HotKeyRecorder() }
            } footer: {
                Text("Press it anywhere to cover the screen. Any key, click or mouse movement brings it back.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Cover") {
                Picker("Show", selection: $mode) {
                    ForEach(CoverMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)

                switch CoverMode(rawValue: mode) ?? .blur {
                case .blur:
                    Picker("Style", selection: $style) {
                        ForEach(BlurStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    LabeledContent("Strength") {
                        Slider(value: $strength, in: 0...0.95) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "circle.dotted")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                    }
                case .wallpaper:
                    Text("Shows your desktop picture, so the screen looks like an empty desktop.")
                        .font(.callout).foregroundStyle(.secondary)
                case .image:
                    LabeledContent("Image") {
                        HStack {
                            Text(imagePath.isEmpty ? "None" : URL(fileURLWithPath: imagePath).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…", action: chooseImage)
                        }
                    }
                }
            }

            Section("Behavior") {
                Toggle("Hide cursor", isOn: $hideCursor)
                Toggle("Dismiss when the mouse moves", isOn: $exitOnMouseMove)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                HStack {
                    Button("Preview") { delegate.blur() }
                    Spacer()
                    Button("Quit BlurNow") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 500)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { imagePath = url.path }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
