import Foundation

enum RickLockConfigurationError: LocalizedError {
    case missingFile(URL)
    case missingPassword
    case invalidPassword(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let url):
            return "Missing configuration file at \(url.path). Create .env from .env.example and rebuild RickLock."
        case .missingPassword:
            return "RICKLOCK_PASSWORD is missing from .env."
        case .invalidPassword(let reason):
            return "RICKLOCK_PASSWORD is invalid: \(reason)"
        }
    }
}

enum RickLockConfiguration {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RickLock/.env")
    }

    static func loadPassword() throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RickLockConfigurationError.missingFile(fileURL)
        }
        return try parsePassword(from: String(contentsOf: fileURL, encoding: .utf8))
    }

    static func parsePassword(from contents: String) throws -> String {
        var password: String?
        for sourceLine in contents.components(separatedBy: .newlines) {
            var line = sourceLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "RICKLOCK_PASSWORD" else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            password = value
        }
        guard let password else { throw RickLockConfigurationError.missingPassword }
        guard !password.isEmpty else { throw RickLockConfigurationError.invalidPassword("it cannot be empty") }
        guard !password.hasPrefix("/") else { throw RickLockConfigurationError.invalidPassword("store it without the leading slash") }
        guard !password.contains(where: { $0.isNewline }) else { throw RickLockConfigurationError.invalidPassword("it must be one line") }
        guard password.count <= 64 else { throw RickLockConfigurationError.invalidPassword("use no more than 64 characters") }
        return password
    }
}
