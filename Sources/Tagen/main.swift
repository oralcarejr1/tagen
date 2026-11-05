#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let c = AppController()
            controller = c
            c.start()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let code = await UIRender.run(dir: dir)
        exit(code)
    }
    app.run()
} else if CommandLine.arguments.contains("--self-test") {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let code = await SelfTest.run()
        exit(code)
    }
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
#else
print("Tagen is a macOS application. On other platforms use tagen-cli.")
#endif
