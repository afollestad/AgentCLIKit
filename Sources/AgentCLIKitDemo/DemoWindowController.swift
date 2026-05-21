import AppKit
import SwiftUI

@MainActor
final class DemoWindowController: NSWindowController {
    let model = DemoModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentCLIKit Demo"
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.center()
        super.init(window: window)

        window.contentViewController = NSHostingController(rootView: DemoShellView(model: model))
        window.minSize = NSSize(width: 860, height: 560)
        window.setContentSize(NSSize(width: 1120, height: 760))
    }

    deinit {
        Task { @MainActor [model] in
            model.cancelPendingWork()
        }
    }

    @objc func newSession(_ sender: Any?) {
        model.addSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
