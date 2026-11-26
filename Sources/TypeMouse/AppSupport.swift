import Foundation
import ServiceManagement
import TypeMouseCore

enum ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/typemouse/config.json")

    @discardableResult
    static func save(_ config: Config) -> Bool {
        do {
            try config.encoded().write(to: url, options: .atomic)
            return true
        } catch {
            Log.info("config save failed: \(error)")
            return false
        }
    }

    static func load() -> Config {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config().encoded().write(to: url)
        }
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try Config.decode(data)
        } catch {
            Log.info("config error, using defaults: \(error)")
            return Config()
        }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TypeMouse/typemouse.log")
    private static let maxBytes: UInt64 = 1_048_576
    private static let queue = DispatchQueue(label: "typemouse.log")
    private static let echoLock = NSLock()
    private nonisolated(unsafe) static var _echo = false
    private nonisolated(unsafe) static var formatter: ISO8601DateFormatter?

    static var echo: Bool {
        get { echoLock.withLock { _echo } }
        set { echoLock.withLock { _echo = newValue } }
    }

    /// Waits for pending writes. Call before exit().
    static func flush() { queue.sync {} }

    static func info(_ message: String) {
        let now = Date()
        let shouldEcho = echo
        queue.async {
            let fmt =
                formatter
                ?? {
                    let created = ISO8601DateFormatter()
                    created.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    formatter = created
                    return created
                }()
            let line = "\(fmt.string(from: now)) \(message)\n"
            let data = Data(line.utf8)
            if shouldEcho { FileHandle.standardError.write(data) }
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            } else if let attrs = try? fm.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? UInt64, size >= maxBytes
            {
                let backup = url.appendingPathExtension("1")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: url, to: backup)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}

/// Starts TypeMouse at login through SMAppService (macOS 13+).
enum LoginItem {
    private static let didSetUpKey = "loginItemSetUp"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("launch at login: \(on ? "on" : "off") (status \(SMAppService.mainApp.status.rawValue))")
        } catch {
            Log.info("launch at login change failed: \(error)")
        }
    }

    /// Turns the login item on once. After that, the menu toggle is the user's choice.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSetUpKey) else { return }
        defaults.set(true, forKey: didSetUpKey)
        if !isEnabled { set(true) }
    }
}
