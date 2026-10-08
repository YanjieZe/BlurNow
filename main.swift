import Cocoa

// 点开即全屏模糊；任意键盘 / 鼠标 / 触控板操作即退出。
// 用 NSVisualEffectView 的 behindWindow 模糊，不需要屏幕录制权限。

let gracePeriod: TimeInterval = 0.8   // 启动后忽略输入的时间，避免启动那一下点击/抖动直接退出
let mouseThreshold: CGFloat = 6       // 鼠标移动超过这个距离（pt）才算“动了”

final class BlurWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private let startTime = Date()
    private var anchorMouse = NSEvent.mouseLocation
    private var exiting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        for screen in NSScreen.screens {
            let w = BlurWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            w.contentView = blur

            w.alphaValue = 0
            w.orderFrontRegardless()
            windows.append(w)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.hide()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            windows.forEach { $0.animator().alphaValue = 1 }
        }

        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .mouseMoved,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .scrollWheel, .magnify, .swipe]
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.handle(e)
            return nil
        }) { monitors.append(m) }
        // 全局 monitor 兜底（鼠标类事件不需要辅助功能权限）
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.handle(e)
        }) { monitors.append(m) }

        // 轮询鼠标位置：不依赖事件分发，多屏时也可靠
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkMouse()
        }
    }

    private var inGrace: Bool { Date().timeIntervalSince(startTime) < gracePeriod }

    private func handle(_ event: NSEvent) {
        if inGrace {
            anchorMouse = NSEvent.mouseLocation
            return
        }
        if event.type == .mouseMoved || event.type == .leftMouseDragged {
            checkMouse()
        } else {
            dismiss()
        }
    }

    private func checkMouse() {
        let p = NSEvent.mouseLocation
        if inGrace { anchorMouse = p; return }
        if hypot(p.x - anchorMouse.x, p.y - anchorMouse.y) > mouseThreshold { dismiss() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if !inGrace { dismiss() }
    }

    private func dismiss() {
        guard !exiting else { return }
        exiting = true
        pollTimer?.invalidate()
        NSCursor.unhide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            NSApp.terminate(nil)
        })
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
