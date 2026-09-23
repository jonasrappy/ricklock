import AppKit
import CryptoKit
import Foundation

final class BackgroundMaintenance {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private let repository = "jonasrappy/ricklock"
    private let archiveName = "RickLock.app.zip"
    private let checksumName = "RickLock.app.zip.sha256"
    private var running = false

    func check(completion: @escaping (URL?) -> Void) {
        guard !running else { completion(nil); return }
        running = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("RickLock", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  !release.draft,
                  !release.prerelease,
                  self.isNewer(release.tag_name),
                  let archive = release.assets.first(where: { $0.name == self.archiveName }),
                  let checksum = release.assets.first(where: { $0.name == self.checksumName }) else {
                self.finish(nil, completion); return
            }
            self.download(archive: archive.browser_download_url, checksum: checksum.browser_download_url, releaseTag: release.tag_name) {
                self.finish($0, completion)
            }
        }.resume()
    }

    private func finish(_ result: URL?, _ completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            self.running = false
            completion(result)
        }
    }

    private func download(archive: URL, checksum: URL, releaseTag: String, completion: @escaping (URL?) -> Void) {
        let group = DispatchGroup()
        var archiveData: Data?
        var checksumData: Data?
        group.enter()
        URLSession.shared.dataTask(with: archive) { data, _, _ in archiveData = data; group.leave() }.resume()
        group.enter()
        URLSession.shared.dataTask(with: checksum) { data, _, _ in checksumData = data; group.leave() }.resume()
        group.notify(queue: .global(qos: .utility)) {
            guard let archiveData, let checksumData,
                  let expected = String(data: checksumData, encoding: .utf8)?.split(whereSeparator: { $0.isWhitespace }).first?.lowercased(),
                  expected.count == 64 else { completion(nil); return }
            let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { completion(nil); return }
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("RickLock-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let zip = root.appendingPathComponent(self.archiveName)
                try archiveData.write(to: zip, options: .atomic)
                guard self.run("/usr/bin/ditto", ["-x", "-k", zip.path, root.path]) else { throw CocoaError(.fileReadCorruptFile) }
                let app = root.appendingPathComponent("RickLock.app", isDirectory: true)
                guard self.validate(app: app, releaseTag: releaseTag) else { throw CocoaError(.fileReadCorruptFile) }
                completion(app)
            } catch {
                completion(nil)
            }
        }
    }

    private func validate(app: URL, releaseTag: String) -> Bool {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "dk.jonassorensen.RickLock",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              normalize(version) == normalize(releaseTag),
              compare(version, currentVersion) == .orderedDescending else { return false }
        return run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func isNewer(_ tag: String) -> Bool { compare(tag, currentVersion) == .orderedDescending }

    private func normalize(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalize(lhs).split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        let right = normalize(rhs).split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }
}
