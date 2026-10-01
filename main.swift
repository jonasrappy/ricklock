import AppKit
import CryptoKit
import WebKit
import AVFoundation

// This is a local prank overlay, not a security boundary or a macOS lock.
func digest(_ value: String) -> String {
    SHA256.hash(data: Data(("ricklock-v1:" + value).utf8)).map { String(format: "%02x", $0) }.joined()
}

final class UnlockInput {
    enum Result { case pending, rejected, unlocked }
    let expected: String
    private let prefixes: Set<String>
    private var buffer = ""
    private var lastInput = Date.distantPast
    init(password: String) {
        expected = digest(password)
        var prefix = ""
        var hashes: Set<String> = [digest("")]
        for character in password { prefix.append(character); hashes.insert(digest(prefix)) }
        prefixes = hashes
    }
    func accepts(_ value: String) -> Bool { digest(value) == expected }
    func reset() { buffer = ""; lastInput = .distantPast }
    func feed(_ text: String, now: Date = Date()) -> Result {
        if now.timeIntervalSince(lastInput) > 15 { buffer = "" }
        lastInput = now
        guard !text.isEmpty else { reset(); return .rejected }
        for character in text {
            if buffer.isEmpty, character == "/" { buffer = "/"; continue }
            guard buffer.hasPrefix("/") else { reset(); return .rejected }
            if character == "\u{7f}" || character == "\u{8}" { buffer.removeLast(); continue }
            buffer.append(character)
            guard prefixes.contains(digest(String(buffer.dropFirst()))) else { reset(); return .rejected }
        }
        if buffer.hasPrefix("/"), accepts(String(buffer.dropFirst())) { reset(); return .unlocked }
        return .pending
    }
}

final class OverlayWindow: NSWindow {
    var displayID: CGDirectDisplayID?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TransparentOverlayView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
}

struct DisplayLayout: Equatable {
    let id: CGDirectDisplayID
    let frame: NSRect
    static var current: [DisplayLayout] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayLayout(id: id.uint32Value, frame: screen.frame)
        }
    }
}

enum PrankTrigger {
    static func isInteraction(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .smartMagnify:
            return true
        case .scrollWheel, .swipe:
            return event.deltaX != 0 || event.deltaY != 0 || event.deltaZ != 0
        case .magnify:
            return event.magnification != 0
        case .rotate:
            return event.rotation != 0
        case .systemDefined:
            // Media-key presses only; releases and unrelated system events stay quiet.
            return event.subtype.rawValue == 8 && (event.data1 >> 8) & 0xff == 0x0a
        default:
            return false
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, NSMenuItemValidation {
    private var item: NSStatusItem!
    private var windows: [NSWindow] = []
    private var webViews: [WKWebView] = []
    private var monitor: Any?
    private var overlayGuard: Timer?
    private let inputFilter = ExclusiveInput()
    private var pendingReveal: DispatchWorkItem?
    private var revealed = false
    private var isPrankArmed = false
    private var previousPresentation: NSApplication.PresentationOptions = []
    private var screenLayout: [DisplayLayout] = []
    private var pendingArm: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private let camera = BustedCamera()
    private var cameraRun = UUID()
    private var cameraStarted = false
    private var cameraDemo = false
    private var permissionPending = false
    private let photoSaveQueue = DispatchQueue(label: "app.ricklock.RickLock.photo-save", qos: .utility)
    private var pendingPhotoSaves = 0
    private var terminationWaitingForSave = false
    private let maintenance = BackgroundMaintenance()
    private var updateTimer: Timer?
    private var updatePrepared = false
    private var cameraState = ["phase": "idle", "message": "Camera starts when the prank is triggered.", "photo": ""]
    private var unlock: UnlockInput?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "theatermasks.fill", accessibilityDescription: "RickLock")
        item.button?.imagePosition = .imageLeft
        updateStatusIndicator()
        let menu = NSMenu()
        menu.addItem(withTitle: "Activate prank", action: #selector(activatePrank), keyEquivalent: "")
        menu.addItem(withTitle: "Preview prank (camera off)", action: #selector(demo), keyEquivalent: "")
        menu.addItem(withTitle: "Test Busted camera…", action: #selector(testCamera), keyEquivalent: "")
        menu.addItem(withTitle: "Open Busted photos", action: #selector(openPhotos), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "How RickLock works", action: #selector(help), keyEquivalent: "")
        menu.addItem(withTitle: "Quit RickLock", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = menu.copy() as? NSMenu
        mainMenu.addItem(appMenu)
        NSApp.mainMenu = mainMenu
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .swipe, .magnify, .rotate, .smartMagnify, .systemDefined]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restoreOverlays), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restoreOverlays), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        if CommandLine.arguments.contains("--overlay-ui-test") {
            unlock = UnlockInput(password: "test-code")
            arm()
            cameraStarted = true
            cameraState = ["phase": "demo", "message": "PREVIEW — CAMERA OFF", "photo": ""]
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.disarm(); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--camera-demo") {
            testCamera()
        } else if CommandLine.arguments.contains("--demo") {
            demo()
        } else if !CommandLine.arguments.contains("--idle") {
            activatePrank()
        }
        scheduleUpdateCheck(after: 30)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CommandLine.arguments.contains("--overlay-ui-test") { return true }
        if isPrankArmed { restoreOverlays() }
        else if windows.isEmpty { activatePrank() }
        return true
    }

    @objc private func activatePrank() {
        guard !isPrankArmed, windows.isEmpty, pendingArm == nil, !permissionPending else { return }
        guard loadUnlockConfiguration() else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            requestCameraPermission { [weak self] in self?.activatePrank() }
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        item.button?.title = " 3…"
        let task = DispatchWorkItem { [weak self] in
            self?.pendingArm = nil
            self?.arm()
        }
        pendingArm = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    private func arm() {
        item.button?.title = ""
        guard inputFilter.start(handler: { [weak self] event in
            guard let self, self.isPrankArmed else { return }
            if let local = NSEvent(cgEvent: event) { _ = self.handle(local, deferReveal: true) }
        }) else {
            showInputPermissionError()
            return
        }
        revealed = false
        cameraDemo = false
        resetCamera()
        unlock?.reset()
        isPrankArmed = true
        inputFilter.isBlocking = true
        updateStatusIndicator()
        if !CommandLine.arguments.contains("--overlay-ui-test") { camera.prepare() }
        previousPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = [.autoHideDock, .disableProcessSwitching, .disableHideApplication, .disableAppleMenu]
        synchronizeOverlays(with: DisplayLayout.current)
        overlayGuard?.invalidate()
        overlayGuard = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isPrankArmed, !self.windows.isEmpty else { return }
            self.inputFilter.ensureEnabled()
            let hasKeyWindow = self.windows.contains { $0 === NSApp.keyWindow }
            if !NSApp.isActive || !hasKeyWindow || self.windows.contains(where: { !$0.isVisible }) {
                self.restoreOverlays()
            }
        }
        NSLog("RickLock: armed on %ld screen(s)", windows.count)
    }

    private func showInputPermissionError() {
        inputFilter.stop()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "RickLock needs Accessibility access"
        alert.informativeText = "To block keyboard shortcuts, media keys, mouse and scroll input, allow RickLock in System Settings > Privacy & Security > Accessibility, then restart RickLock. The prank has not been armed because its exclusive input filter could not start."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func queueReveal() {
        guard !revealed, pendingReveal == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReveal = nil
            if self.isPrankArmed { self.reveal() }
        }
        pendingReveal = task
        DispatchQueue.main.async(execute: task)
    }

    private func synchronizeOverlays(with layout: [DisplayLayout], present: Bool = true) {
        guard isPrankArmed else { return }
        screenLayout = layout
        let previousWindows = windows
        var activeWindows: [NSWindow] = []
        for display in layout {
            if let window = previousWindows.first(where: { ($0 as? OverlayWindow)?.displayID == display.id }) {
                window.setFrame(display.frame, display: true)
                if present { window.orderFrontRegardless() }
                activeWindows.append(window)
                continue
            }
            let window = OverlayWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.displayID = display.id
            window.title = "RickLock — transparent overlay"
            window.setAccessibilityRole(.window)
            window.setAccessibilitySubrole(.standardWindow)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            let view = TransparentOverlayView(frame: NSRect(origin: .zero, size: display.frame.size))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            if revealed { showPrank(in: window) }
            activeWindows.append(window)
            if present { window.orderFrontRegardless() }
        }
        windows = activeWindows
        // Cover remaining displays before retiring disconnected windows.
        for window in previousWindows where !activeWindows.contains(where: { $0 === window }) {
            if let web = window.contentView as? WKWebView {
                web.stopLoading()
                webViews.removeAll { $0 === web }
            }
            window.delegate = nil
            window.close()
        }
        guard present, !windows.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let target = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.contentView)
    }

    @objc private func screensChanged() {
        let layout = DisplayLayout.current
        guard isPrankArmed, screenLayout != layout else { return }
        synchronizeOverlays(with: layout)
        NSLog("RickLock: display arrangement changed; still armed on %ld screen(s)", windows.count)
    }

    @objc private func restoreOverlays() {
        recoverOverlays(with: DisplayLayout.current)
    }

    private func recoverOverlays(with layout: [DisplayLayout], present: Bool = true) {
        guard isPrankArmed else { return }
        synchronizeOverlays(with: layout, present: present)
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard isPrankArmed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPrankArmed else { return }
            self.restoreOverlays()
        }
    }

    @objc private func spaceChanged() {
        guard isPrankArmed else { return }
        restoreOverlays()
    }

    private func handle(_ event: NSEvent, deferReveal: Bool = false) -> NSEvent? {
        if isPrankArmed {
            let trigger = { if deferReveal { self.queueReveal() } else { self.reveal() } }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.type {
            case .keyUp:
                break
            case .flagsChanged:
                if flags.contains(.command) || flags.contains(.control) { unlock?.reset(); trigger() }
            case .keyDown:
                guard !flags.contains(.command), !flags.contains(.control) else { unlock?.reset(); trigger(); return nil }
                switch unlock?.feed(event.characters ?? "") ?? .rejected {
                case .pending: break
                case .rejected: trigger()
                case .unlocked: disarm()
                }
            default:
                if PrankTrigger.isInteraction(event) { unlock?.reset(); trigger() }
            }
            // Consume all local input while armed, including menu and WebKit events.
            return nil
        }
        guard !windows.isEmpty, let eventWindow = event.window, windows.contains(where: { $0 === eventWindow }) else { return event }
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !isPrankArmed, flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" { quit(); return nil }
            // Characters are consumed only inside our overlay, never logged or forwarded to WebKit.
            if !flags.contains(.command), !flags.contains(.control), unlock?.feed(event.characters ?? "") == .unlocked { disarm() }
            return nil
        }
        if !revealed { reveal(); return nil }
        return event
    }

    private func reveal() {
        guard !revealed else { return }
        revealed = true
        NSLog("RickLock: prank revealed")
        startCameraCapture()
        for window in windows { showPrank(in: window) }
    }

    private func showPrank(in window: NSWindow) {
        window.title = "RickLock — GOTCHA!"
        window.isOpaque = true
        window.backgroundColor = .black
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        window.contentView = web
        webViews.append(web)
        if let page = Bundle.main.url(forResource: "prank", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateCameraView(webView)
    }

    private func startCameraCapture() {
        guard (isPrankArmed || cameraDemo), revealed, !cameraStarted else { return }
        cameraStarted = true
        let run = cameraRun
        cameraState = ["phase": "capturing", "message": "CAMERA ON — TAKING ONE PHOTO", "photo": ""]
        updateCameraViews()
        camera.capture { [weak self] result in
            guard let self, self.cameraRun == run, self.revealed else { return }
            switch result {
            case .success(let data):
                self.showPhotoThenSave(data, run: run)
                return
            case .failure(let error):
                self.cameraState = ["phase": "error", "message": error.localizedDescription, "photo": ""]
            }
            self.updateCameraViews()
        }
    }

    private func updateCameraView(_ web: WKWebView, afterDisplay: (() -> Void)? = nil) {
        web.callAsyncJavaScript("return await window.updateBusted(state)", arguments: ["state": cameraState], in: nil, in: .page) { result in
            if case .success = result { afterDisplay?() }
        }
    }

    private func updateCameraViews(afterDisplay: (() -> Void)? = nil) {
        webViews.forEach { updateCameraView($0, afterDisplay: afterDisplay) }
    }

    private func showPhotoThenSave(_ data: Data, run: UUID) {
        cameraState = ["phase": "saving", "message": "PHOTO CAPTURED · SAVING TO DESKTOP/CAPTURE…", "photo": "data:image/jpeg;base64," + data.base64EncodedString()]
        pendingPhotoSaves += 1
        var saveStarted = false
        let save = { [weak self] in
            guard let self, !saveStarted else { return }
            saveStarted = true
            self.photoSaveQueue.async {
                let result = Result { try PhotoArchive.save(data) }
                DispatchQueue.main.async {
                    self.pendingPhotoSaves -= 1
                    // Finish saving even after unlock, but never update a newer prank's UI.
                    if self.cameraRun == run, self.revealed {
                        switch result {
                        case .success:
                            self.cameraState["phase"] = "saved"
                            self.cameraState["message"] = "SAVED TO DESKTOP/CAPTURE · CAMERA OFF"
                        case .failure(let error):
                            self.cameraState["phase"] = "error"
                            self.cameraState["message"] = "PHOTO SHOWN, BUT NOT SAVED: " + error.localizedDescription
                        }
                        self.updateCameraViews()
                    }
                    if self.terminationWaitingForSave, self.pendingPhotoSaves == 0 {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
            }
        }
        // Wait for the first visible image to decode and paint before scheduling disk I/O.
        updateCameraViews(afterDisplay: save)
        // An unlocked, closed or unresponsive WebView must not prevent preservation of the photo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: save)
    }

    private func resetCamera() {
        camera.cancel()
        cameraRun = UUID()
        cameraStarted = false
        cameraState = ["phase": "idle", "message": "CAMERA STARTING — ONE PHOTO", "photo": ""]
    }

    private func requestCameraPermission(then action: @escaping () -> Void) {
        guard !permissionPending else { return }
        permissionPending = true
        NSApp.activate(ignoringOtherApps: true)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                self?.permissionPending = false
                action()
            }
        }
    }

    @objc private func testCamera() {
        guard !isPrankArmed, windows.isEmpty, pendingArm == nil, !permissionPending else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            requestCameraPermission { [weak self] in self?.testCamera() }
            return
        }
        cameraDemo = true
        demo()
    }

    @objc private func openPhotos() {
        guard !isPrankArmed else { reveal(); return }
        do {
            try PhotoArchive.prepareDirectory()
            NSWorkspace.shared.open(PhotoArchive.directory)
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not open photos"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    private func loadUnlockConfiguration() -> Bool {
        do {
            let password = try RickLockConfiguration.loadPassword()
            unlock = UnlockInput(password: password)
            return true
        } catch {
            unlock = nil
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "RickLock configuration error"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    @objc private func demo() {
        guard !isPrankArmed, windows.isEmpty, pendingArm == nil else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let window = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.delegate = self
        windows = [window]
        isPrankArmed = false
        revealed = false
        resetCamera()
        if !cameraDemo { cameraState = ["phase": "demo", "message": "PREVIEW — CAMERA OFF", "photo": ""] }
        unlock?.reset()
        reveal()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func disarm() {
        NSLog("RickLock: disarmed")
        pendingArm?.cancel(); pendingArm = nil
        pendingReveal?.cancel(); pendingReveal = nil
        inputFilter.stop()
        overlayGuard?.invalidate(); overlayGuard = nil
        resetCamera()
        cameraDemo = false
        item?.button?.title = ""
        let restorePresentation = isPrankArmed
        isPrankArmed = false
        updateStatusIndicator()
        screenLayout.removeAll()
        if restorePresentation { NSApp.presentationOptions = previousPresentation }
        unlock?.reset()
        let closing = windows
        windows.removeAll()
        webViews.forEach { $0.stopLoading() }
        webViews.removeAll()
        closing.forEach { $0.delegate = nil; $0.close() }
        revealed = false
        previousApp?.activate(options: [])
        previousApp = nil
        scheduleUpdateCheck(after: 2)
    }

    private func updateStatusIndicator() {
        item?.button?.attributedTitle = NSAttributedString(
            string: isPrankArmed ? " ●" : "",
            attributes: [.foregroundColor: NSColor.systemGreen, .font: NSFont.systemFont(ofSize: 9)]
        )
        let status = isPrankArmed ? "RickLock — locked" : "RickLock — ready"
        item?.button?.toolTip = status
        item?.button?.setAccessibilityLabel(status)
    }

    private func scheduleUpdateCheck(after delay: TimeInterval) {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.checkForUpdate() }
    }

    private func checkForUpdate() {
        guard !isPrankArmed, windows.isEmpty, pendingArm == nil, pendingPhotoSaves == 0, !permissionPending, !updatePrepared else {
            scheduleUpdateCheck(after: 300); return
        }
        maintenance.check { [weak self] replacement in
            guard let self else { return }
            guard let replacement else { self.scheduleUpdateCheck(after: 3600); return }
            self.installUpdate(replacement)
        }
    }

    private func installUpdate(_ replacement: URL) {
        guard !isPrankArmed, windows.isEmpty, pendingArm == nil, pendingPhotoSaves == 0, !permissionPending else {
            scheduleUpdateCheck(after: 300); return
        }
        guard let bundledHelper = Bundle.main.url(forResource: ".support", withExtension: nil) else { return }
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent(".ricklock-support-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: bundledHelper, to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let process = Process()
            process.executableURL = helper
            process.arguments = [Bundle.main.bundleURL.path, replacement.path, String(ProcessInfo.processInfo.processIdentifier)]
            try process.run()
            updatePrepared = true
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: helper)
            scheduleUpdateCheck(after: 3600)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isPrankArmed }
    func windowWillClose(_ notification: Notification) {
        if isPrankArmed { restoreOverlays() }
        else { disarm() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !isPrankArmed }

    @objc private func help() {
        guard !isPrankArmed else { reveal(); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "RickLock 🎭"
        alert.informativeText = "1. Click the Dock lock or choose Activate prank. No code required.\n2. A transparent overlay blocks input on every display after 3 seconds. Your current apps remain visible.\n3. The first click or scroll reveals Rick and takes one camera photo. BUSTED and the photo appear in the center.\n4. Type / followed by your code to dismiss. No Enter required.\n\nPhotos appear first, then save in the background to Desktop/capture. Use Open Busted photos to view them. Saving continues after unlock. The camera shuts off after each photo and when you unlock. No audio is captured. macOS remembers camera permission between launches.\n\nNormal minimize, ⌘Q and ⌘Tab are blocked during the prank. Preview mode does not use the camera. Your other apps keep running. Disconnecting a monitor and waking from sleep keep the prank active. This is a prank, not a secure macOS lock."
        alert.runModal()
    }

    @objc private func quit() {
        guard !isPrankArmed else { reveal(); return }
        disarm(); NSApp.terminate(nil)
    }

    func testOverlayLifecycle() {
        unlock = UnlockInput(password: "test-code")
        isPrankArmed = true
        let internalDisplay = DisplayLayout(id: 1, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let externalDisplay = DisplayLayout(id: 2, frame: NSRect(x: 800, y: 0, width: 1200, height: 800))
        synchronizeOverlays(with: [internalDisplay, externalDisplay], present: false)
        precondition(windows.count == 2)
        let internalWindow = windows[0]
        precondition(!internalWindow.isOpaque && internalWindow.backgroundColor == .clear)
        precondition(!internalWindow.ignoresMouseEvents)
        precondition(internalWindow.contentView?.hitTest(NSPoint(x: 10, y: 10)) != nil)
        precondition(unlock!.feed("/test-") == .pending)
        synchronizeOverlays(with: [internalDisplay], present: false)
        precondition(isPrankArmed && windows.count == 1 && windows[0] === internalWindow)
        precondition(unlock!.feed("code") == .unlocked)
        cameraStarted = true
        func key(_ text: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
        }
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        func system(_ subtype: Int16, _ data: Int) -> NSEvent {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: subtype, data1: data, data2: 0)!
        }
        let stillScroll = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!)!
        let activeScroll = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
        let quietEvents = [mouse(.mouseMoved), mouse(.leftMouseUp), mouse(.rightMouseUp), system(0, 0), system(8, 0x0b00), stillScroll]
        precondition(handle(key("/test-")) == nil && !revealed)
        for event in quietEvents {
            precondition(handle(event) == nil && !revealed && isPrankArmed)
        }
        recoverOverlays(with: [internalDisplay, externalDisplay], present: false)
        recoverOverlays(with: [], present: false)
        recoverOverlays(with: [internalDisplay], present: false)
        precondition(!revealed && isPrankArmed && webViews.isEmpty)
        precondition(unlock!.feed("code") == .unlocked)
        for event in [mouse(.leftMouseDown), mouse(.rightMouseDown), system(8, (16 << 16) | 0x0a00), activeScroll] {
            precondition(handle(event) == nil && revealed && isPrankArmed)
            revealed = false
            webViews.forEach { $0.stopLoading() }
            webViews.removeAll()
        }
        precondition(handle(key("x")) == nil && revealed && isPrankArmed)
        precondition(handle(key("q", flags: .command)) == nil && isPrankArmed)
        precondition(handle(key("\u{1b}")) == nil && isPrankArmed)
        precondition(!windowShouldClose(internalWindow))
        precondition(!validateMenuItem(NSMenuItem(title: "Quit RickLock", action: #selector(quit), keyEquivalent: "q")))
        precondition(applicationShouldTerminate(NSApp) == .terminateCancel)
        quit()
        precondition(isPrankArmed)
        synchronizeOverlays(with: [], present: false)
        precondition(isPrankArmed && windows.isEmpty)
        activatePrank()
        demo()
        testCamera()
        precondition(isPrankArmed && windows.isEmpty && pendingArm == nil && !cameraDemo)
        synchronizeOverlays(with: [internalDisplay], present: false)
        precondition(isPrankArmed && windows.count == 1)
        cameraStarted = true // Lifecycle checks must never start a camera capture.
        reveal()
        let run = cameraRun
        synchronizeOverlays(with: [externalDisplay], present: false)
        precondition(isPrankArmed && revealed && cameraStarted && cameraRun == run)
        precondition(webViews.count == 1 && windows[0].contentView === webViews[0])
        let resized = DisplayLayout(id: 2, frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let survivingWindow = windows[0]
        synchronizeOverlays(with: [resized], present: false)
        precondition(windows[0] === survivingWindow && survivingWindow.frame == resized.frame)
        precondition(revealed && isPrankArmed)
        precondition(handle(key("/test-code")) == nil)
        precondition(!isPrankArmed && windows.isEmpty && webViews.isEmpty)
        print("PASS: quiet pointer/system events and focus/display recovery preserve password input; click/media/invalid-key triggers, quit rejection and password unlock")
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPrankArmed else { reveal(); return .terminateCancel }
        guard pendingPhotoSaves > 0 else { return .terminateNow }
        terminationWaitingForSave = true
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { inputFilter.stop(); overlayGuard?.invalidate(); updateTimer?.invalidate(); camera.cancel(); if let monitor { NSEvent.removeMonitor(monitor) } }
}

if CommandLine.arguments.contains("--self-test") {
    for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, CGEventType(rawValue: 14)!, CGEventType(rawValue: 29)!] {
        precondition(ExclusiveInput.shouldConsume(type, whileBlocking: true))
        precondition(!ExclusiveInput.shouldConsume(type, whileBlocking: false))
    }
    precondition(!ExclusiveInput.shouldConsume(.tapDisabledByTimeout, whileBlocking: true))
    let input = UnlockInput(password: "test-code")
    precondition(input.feed("test-code") == .rejected)
    precondition(input.feed("/wrong") == .rejected)
    precondition(input.feed("/test-code") == .unlocked)
    precondition(input.feed("/") == .pending)
    precondition(input.feed("test-") == .pending)
    precondition(input.feed("code") == .unlocked)
    precondition(input.feed("/test-c\u{7f}") == .pending)
    precondition(input.feed("code") == .unlocked)
    precondition(input.feed("/test-x") == .rejected)
    precondition(input.feed("/test-codeX") == .rejected)
    precondition(input.feed("/test-code") == .unlocked)
    precondition(input.feed("/\t") == .rejected)
    precondition(input.feed("") == .rejected)
    precondition(input.feed("/\u{7f}") == .pending)
    precondition(input.feed("test-code") == .rejected)
    let slashCode = UnlockInput(password: "some/code")
    precondition(slashCode.feed("/some/code") == .unlocked)
    let now = Date()
    precondition(input.feed("/test-", now: now) == .pending)
    precondition(input.feed("code", now: now.addingTimeInterval(16)) == .rejected)
    let plainPassword = try RickLockConfiguration.parsePassword(from: "# ignored\nRICKLOCK_PASSWORD=test-code\n")
    let quotedPassword = try RickLockConfiguration.parsePassword(from: "export RICKLOCK_PASSWORD='quoted value'\n")
    precondition(plainPassword == "test-code")
    precondition(quotedPassword == "quoted value")
    do {
        _ = try RickLockConfiguration.parsePassword(from: "RICKLOCK_PASSWORD=/wrong\n")
        preconditionFailure("A leading slash in .env must be rejected")
    } catch RickLockConfigurationError.invalidPassword { }
    print("PASS: input suppression policy including media keys/gestures, valid password prefixes, mismatch/trailing-input rejection, backspace and timeout")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
if CommandLine.arguments.contains("--input-filter-check") {
    let filter = ExclusiveInput()
    guard filter.start(handler: { _ in }) else {
        print("FAIL: exclusive input filter unavailable; grant RickLock Accessibility access")
        exit(1)
    }
    filter.stop()
    print("PASS: exclusive input filter can start; check did not block or record input")
    exit(0)
}
if CommandLine.arguments.contains("--camera-speed-test") {
    app.setActivationPolicy(.accessory)
    let camera = BustedCamera()
    let capture = {
        let started = ProcessInfo.processInfo.systemUptime
        camera.capture { result in
            switch result {
            case .success(let data):
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                guard let image = NSBitmapImageRep(data: data) else { exit(1) }
                var brightness = 0.0
                for y in 0..<16 {
                    for x in 0..<16 {
                        guard let color = image.colorAt(x: x * image.pixelsWide / 16, y: y * image.pixelsHigh / 16)?.usingColorSpace(.sRGB) else { exit(1) }
                        brightness += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    }
                }
                print(String(format: "PASS: camera photo delivered in %.0f ms; %dx%d JPEG, %d bytes; mean brightness %.1f/255", elapsed, image.pixelsWide, image.pixelsHigh, data.count, brightness * 255 / 256))
                camera.cancel { exit(0) }
            case .failure(let error):
                print("FAIL: " + error.localizedDescription)
                exit(1)
            }
        }
    }
    if CommandLine.arguments.contains("--prepared") {
        camera.prepare { result in
            if case .failure(let error) = result { print("FAIL: " + error.localizedDescription); exit(1) }
            capture()
        }
    } else { capture() }
    app.run()
    exit(0)
}
if CommandLine.arguments.contains("--overlay-self-test") {
    delegate.testOverlayLifecycle()
    exit(0)
}
app.delegate = delegate
app.run()
