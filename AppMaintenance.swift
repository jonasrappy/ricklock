import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4, let pid = Int32(arguments[3]) else { exit(2) }
let current = URL(fileURLWithPath: arguments[1])
let replacement = URL(fileURLWithPath: arguments[2])
let backup = current.deletingLastPathComponent().appendingPathComponent(".RickLock.backup-\(UUID().uuidString).app")
let files = FileManager.default

for _ in 0..<300 {
    if kill(pid, 0) != 0 { break }
    usleep(100_000)
}
guard kill(pid, 0) != 0 else { exit(3) }

do {
    try files.moveItem(at: current, to: backup)
    do {
        try files.moveItem(at: replacement, to: current)
    } catch {
        try? files.moveItem(at: backup, to: current)
        throw error
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ["--idle"]
    let semaphore = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: current, configuration: configuration) { _, _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 10)
    try? files.removeItem(at: backup)
    try? files.removeItem(at: replacement.deletingLastPathComponent())
    try? files.removeItem(atPath: arguments[0])
} catch {
    exit(4)
}
