import Foundation
import os.log

public enum LogLevel: String, Sendable, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public struct LogEntry: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    public var logLine: String {
        "[\(formattedTimestamp)] [\(category)] [\(level.rawValue)] \(message)"
    }
}

public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    private let osLogger = Logger(subsystem: "com.moonlight.mac", category: "App")
    private let queue = DispatchQueue(label: "com.moonlight.mac.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var entries: [LogEntry] = []
    private let maxEntries = 500

    public var logFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MoonlightMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("moonlight.log")
    }

    private init() {
        setupLogFile()
        info("MoonlightMac Logger initialized. Log file: \(logFileURL.path)", category: "SYSTEM")
    }

    private func setupLogFile() {
        let path = logFileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            self.fileHandle = handle
        }
    }

    public func log(_ level: LogLevel, category: String, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        let line = entry.logLine

        // Output to OS log
        switch level {
        case .debug:
            osLogger.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info:
            osLogger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            osLogger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error:
            osLogger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }

        // Print to standard console
        print(line)

        // Write to persistent file on serial queue
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }

            if let data = (line + "\n").data(using: .utf8) {
                self.fileHandle?.write(data)
                try? self.fileHandle?.synchronize()
            }
        }
    }

    public func debug(_ message: String, category: String = "APP") {
        log(.debug, category: category, message)
    }

    public func info(_ message: String, category: String = "APP") {
        log(.info, category: category, message)
    }

    public func warning(_ message: String, category: String = "APP") {
        log(.warning, category: category, message)
    }

    public func error(_ message: String, category: String = "APP") {
        log(.error, category: category, message)
    }

    public func getRecentEntries() -> [LogEntry] {
        queue.sync { entries }
    }

    public func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.removeAll()
            try? self.fileHandle?.close()
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
            self.setupLogFile()
        }
    }
}
