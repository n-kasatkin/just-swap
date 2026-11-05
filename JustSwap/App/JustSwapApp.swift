import AppKit
import JustSwapCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()
    private var previewWindow: NSWindow?
    private var reopenWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        model.start()
        if model.options.previewWindow {
            showPreviewWindow()
        } else if !UserDefaults.standard.bool(forKey: "loginItemDefaultApplied") {
            // Launch at login is on by default; applied once so turning it off sticks.
            model.launchAtLogin = true
            UserDefaults.standard.set(true, forKey: "loginItemDefaultApplied")
        }
    }

    /// Development: the popover content in an ordinary, capturable window;
    /// prints its window number for `screencapture -l`.
    @MainActor private func showPreviewWindow() {
        let w = Self.popoverWindow(model: model)
        w.title = "just swap"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true }
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Once the first core reads have landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.fit(w) }
        previewWindow = w
        print("PREVIEW_WINDOW_ID=\(w.windowNumber)")
        fflush(stdout)
    }

    /// `kill`, logout and Ctrl-C quit through `terminate`, so the auto loop
    /// is stopped as on a normal quit. A no-op handler rather than SIG_IGN:
    /// an ignored disposition would be inherited by the spawned core.
    @MainActor private func installTerminationSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig) { _ in }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// With the status item hidden, reopening the app (Applications, Spotlight,
    /// `open`) shows the popover content in a small window: with no status
    /// item there is nothing else to click.
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: MenuBarPrefs.hidden) { showReopenWindow() }
        return true
    }

    @MainActor private func showReopenWindow() {
        if reopenWindow == nil {
            let w = Self.popoverWindow(model: model)
            w.title = "just swap"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            reopenWindow = w
        }
        NSApp.activate()
        reopenWindow?.makeKeyAndOrderFront(nil)
        if let w = reopenWindow { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.fit(w) } }
    }

    /// A window holding the popover content. The hosting view sits inside a
    /// plain container, so SwiftUI never sizes the window itself (its min-size
    /// pass looped with the popover's layout); the window takes the content's
    /// height on every `fit` call and whenever that height changes (a row
    /// opens, a page swaps). The content is sized from its ideal height
    /// (`PopoverView`), so the resize cannot change it again.
    @MainActor private static func popoverWindow(model: AppModel) -> NSWindow {
        let measured = MeasuredHeight()
        // The height goes to a plain object: reading it never invalidates the view.
        let host = NSHostingView(rootView: AnyView(PopoverView(model: model)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured.height = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.background)))
        host.sizingOptions = []
        host.safeAreaRegions = []
        let size = NSSize(width: Theme.popoverWidth, height: 560)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.contentView = container
        measuredHeights[ObjectIdentifier(w)] = measured
        measured.onChange = { [weak w] in
            // After the layout pass that reported it, never inside it.
            DispatchQueue.main.async { if let w { fit(w) } }
        }
        return w
    }

    @MainActor private static var measuredHeights: [ObjectIdentifier: MeasuredHeight] = [:]

    /// Resizes a popover window to its content's height, keeping the top edge.
    @MainActor private static func fit(_ w: NSWindow) {
        guard let h = measuredHeights[ObjectIdentifier(w)]?.height, h > 0 else { return }
        // A full-size content view runs under the transparent title bar.
        let height = w.styleMask.contains(.fullSizeContentView)
            ? h : w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: h)).height
        guard abs(w.frame.height - height) > 0.5 else { return }
        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - height, width: w.frame.width, height: height), display: true)
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

/// The popover content's last laid-out height, for sizing its window.
@MainActor
final class MeasuredHeight {
    var height: CGFloat = 0 {
        didSet { if abs(height - oldValue) > 0.5 { onChange?() } }
    }
    var onChange: (() -> Void)?
}

@main
struct JustSwapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(MenuBarPrefs.hidden) private var iconHidden = false

    private var iconShown: Binding<Bool> {
        Binding(get: { !iconHidden }, set: { iconHidden = !$0 })
    }

    var body: some Scene {
        MenuBarExtra(isInserted: iconShown) {
            PopoverView(model: delegate.model)
        } label: {
            StatusLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Status item: the logo and the parts picked in Settings > Menu bar.
struct StatusLabel: View {
    let model: AppModel
    @AppStorage(MenuBarPrefs.logo) private var logo = true
    @AppStorage(MenuBarPrefs.account) private var account = false
    @AppStorage(MenuBarPrefs.organization) private var organization = false
    @AppStorage(MenuBarPrefs.fiveHour) private var fiveHour = false
    @AppStorage(MenuBarPrefs.sevenDay) private var sevenDay = false
    @AppStorage(MenuBarPrefs.separator) private var separator = TitleSeparator.standard
    @AppStorage(MenuBarPrefs.customSeparator) private var customSeparator = ""
    private static let glyph = LogoArt.templateImage()

    var body: some View {
        let t = title
        HStack(spacing: 4) {
            if t.logo { Image(nsImage: Self.glyph) }
            if let text = t.text { Text(text) }
        }
    }

    private var title: StatusTitle {
        let items = MenuBarItems(logo: logo, account: account, organization: organization,
                                 fiveHour: fiveHour, sevenDay: sevenDay)
        let row = model.activeAccount
        return StatusTitle.compose(items, account: row.map(model.shortName), organization: row.flatMap(model.organization),
                                   usage: row?.displayUsage, hasActive: row != nil,
                                   separator: TitleSeparator.resolve(choice: separator, custom: customSeparator))
    }
}
