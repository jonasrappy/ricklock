import AppKit

final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--arm"]
        let application = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/RickLock.app")
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    let alert = NSAlert(); alert.messageText = "RickLock could not be opened"; alert.informativeText = error.localizedDescription; alert.runModal()
                }
                NSApp.terminate(nil)
            }
        }
    }
}
let app = NSApplication.shared
let delegate = LauncherDelegate()
app.delegate = delegate
app.run()
