import AppKit
import SwiftUI
import ServiceManagement
import WidgetKit

// MARK: - Widget catalogue

enum WidgetKind: String, CaseIterable {
    case cpu, memory, network, processes, disk, system

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .processes: return "Top Processes"
        case .disk: return "Disk"
        case .system: return "System"
        }
    }

    static let unit: CGFloat = 170
    static let gap: CGFloat = 16
    static let wide = unit * 2 + gap

    var size: NSSize {
        switch self {
        case .disk, .system: return NSSize(width: Self.unit, height: Self.unit)
        default: return NSSize(width: Self.wide, height: Self.unit)
        }
    }

    /// Default spot as (column from the right, row from the top, extra x offset).
    private var slot: (col: CGFloat, row: CGFloat, dx: CGFloat) {
        switch self {
        case .cpu: return (0, 0, 0)
        case .memory: return (0, 1, 0)
        case .network: return (0, 2, 0)
        case .processes: return (1, 0, 0)
        case .disk: return (1, 1, 0)
        case .system: return (1, 1, Self.unit + Self.gap)
        }
    }

    func defaultOrigin(on screen: NSScreen) -> NSPoint {
        let area = screen.visibleFrame
        let margin: CGFloat = 24
        let s = slot
        let x = area.maxX - margin - Self.wide - s.col * (Self.wide + Self.gap) + s.dx
        let y = area.maxY - margin - Self.unit - s.row * (Self.unit + Self.gap)
        return NSPoint(x: x, y: y)
    }

    func view(_ stats: Stats) -> AnyView {
        switch self {
        case .cpu: return AnyView(CPUWidget(stats: stats))
        case .memory: return AnyView(MemoryWidget(stats: stats))
        case .network: return AnyView(NetworkWidget(stats: stats))
        case .processes: return AnyView(ProcessesWidget(stats: stats))
        case .disk: return AnyView(DiskWidget(stats: stats))
        case .system: return AnyView(SystemWidget(stats: stats))
        }
    }

    var hiddenKey: String { "hidden.\(rawValue)" }
    var frameName: String { "widget.\(rawValue)" }
}

// MARK: - Desktop window

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets you drag a widget by grabbing it anywhere.
final class DragHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { true }
}

func makeWidgetWindow(_ kind: WidgetKind, stats: Stats) -> WidgetWindow {
    let w = WidgetWindow(contentRect: NSRect(origin: .zero, size: kind.size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = true
    // Just above the desktop icons, below every normal window.
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    w.isMovableByWindowBackground = true
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .darkAqua)

    let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: kind.size))
    fx.material = .hudWindow
    fx.blendingMode = .behindWindow
    fx.state = .active
    fx.wantsLayer = true
    fx.layer?.cornerRadius = 22
    fx.layer?.cornerCurve = .continuous
    fx.layer?.masksToBounds = true

    let host = DragHostingView(rootView: kind.view(stats))
    host.sizingOptions = []
    host.frame = fx.bounds
    host.autoresizingMask = [.width, .height]
    fx.addSubview(host)
    w.contentView = fx

    if w.setFrameUsingName(kind.frameName) {
        w.setFrame(NSRect(origin: w.frame.origin, size: kind.size), display: false)
    } else if let screen = NSScreen.main {
        w.setFrameOrigin(kind.defaultOrigin(on: screen))
    }
    w.setFrameAutosaveName(kind.frameName)   // remembers where you drag it
    w.invalidateShadow()
    return w
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let stats = Stats()
    private var windows: [WidgetKind: WidgetWindow] = [:]
    private var statusItem: NSStatusItem!
    private let defaults = UserDefaults.standard

    private var interval: TimeInterval {
        let v = defaults.double(forKey: "interval")
        return v > 0 ? v : 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for kind in WidgetKind.allCases {
            let w = makeWidgetWindow(kind, stats: stats)
            windows[kind] = w
            if !defaults.bool(forKey: kind.hiddenKey) { w.orderFront(nil) }
        }
        stats.start(interval: interval)

        // Notification Center widgets refresh on macOS's own schedule; while the app
        // runs, ask for a fresh reading every minute.
        let reload = Timer(timeInterval: 60, repeats: true) { _ in WidgetCenter.shared.reloadAllTimelines() }
        reload.tolerance = 10
        RunLoop.main.add(reload, forMode: .common)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "DeskStats")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for kind in WidgetKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(toggleWidget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = defaults.bool(forKey: kind.hiddenKey) ? .off : .on
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for seconds in [1.0, 2.0, 5.0] {
            let item = NSMenuItem(title: "\(Int(seconds)) second\(seconds == 1 ? "" : "s")",
                                  action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = seconds == interval ? .on : .off
            sub.addItem(item)
        }
        refresh.submenu = sub
        menu.addItem(refresh)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let reset = NSMenuItem(title: "Reset Widget Positions", action: #selector(resetPositions), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let am = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DeskStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = WidgetKind(rawValue: raw),
              let w = windows[kind] else { return }
        let hide = !defaults.bool(forKey: kind.hiddenKey)
        defaults.set(hide, forKey: kind.hiddenKey)
        if hide { w.orderOut(nil) } else { w.orderFront(nil) }
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        defaults.set(seconds, forKey: "interval")
        stats.start(interval: seconds)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func resetPositions() {
        guard let screen = NSScreen.main else { return }
        for (kind, w) in windows { w.setFrameOrigin(kind.defaultOrigin(on: screen)) }
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
