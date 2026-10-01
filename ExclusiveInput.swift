import AppKit
import ApplicationServices

final class ExclusiveInput {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let state = NSLock()
    private var handler: ((CGEvent) -> Void)?
    private var blocking = false
    var isBlocking: Bool {
        get { state.withLock { blocking } }
        set { state.withLock { blocking = newValue } }
    }
    var isEnabled: Bool { state.withLock { tap }.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    static func shouldConsume(_ type: CGEventType, whileBlocking blocking: Bool) -> Bool {
        blocking && type != .tapDisabledByTimeout && type != .tapDisabledByUserInput
    }

    func start(handler: @escaping (CGEvent) -> Void) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }
        state.withLock { self.handler = handler }
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let filter = Unmanaged<ExclusiveInput>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                filter.ensureEnabled()
                return Unmanaged.passUnretained(event)
            }
            guard ExclusiveInput.shouldConsume(type, whileBlocking: filter.isBlocking) else { return Unmanaged.passUnretained(event) }
            if let copy = event.copy() {
                DispatchQueue.main.async { [weak filter] in
                    guard let filter else { return }
                    let handler = filter.state.withLock { filter.blocking ? filter.handler : nil }
                    handler?(copy)
                }
            }
            return nil
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask.max, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            state.withLock { self.handler = nil }
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            state.withLock { self.handler = nil }
            return false
        }
        state.withLock { self.tap = tap; self.source = source }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            let active = state.withLock { () -> Bool in
                guard self.tap === tap else { return false }
                runLoop = loop
                CFRunLoopAddSource(loop, source, .commonModes)
                return true
            }
            ready.signal()
            guard active else { return }
            // Keep input suppression independent of WebKit, camera and UI work.
            while state.withLock({ self.tap === tap }) {
                CFRunLoopRunInMode(.defaultMode, 0.1, false)
            }
        }
        thread.name = "RickLock exclusive input"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        guard ready.wait(timeout: .now() + 2) == .success else { stop(); return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return isEnabled
    }

    func ensureEnabled() {
        if let tap = state.withLock({ self.tap }), !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        let (tap, source, loop) = state.withLock { () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?) in
            blocking = false
            let previous = (self.tap, self.source, runLoop)
            self.tap = nil
            self.source = nil
            runLoop = nil
            handler = nil
            return previous
        }
        if let source, let loop { CFRunLoopRemoveSource(loop, source, .commonModes); CFRunLoopStop(loop) }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
    }

    deinit { stop() }
}
