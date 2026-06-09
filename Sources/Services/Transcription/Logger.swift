import Foundation

public actor Logger {
    public static let shared = Logger()

    private let logURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.voicegum.logger", qos: .utility)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = appSupport.appendingPathComponent("VoiceGum/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        logURL = logDir.appendingPathComponent("voicegum-\(date).log")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let msg = "[\(dateFormatter.string(from: Date()))] Logger started\n"
        try? msg.data(using: .utf8)?.write(to: logURL)
        fputs("[VoiceGum] Logger started to \(logURL.path)\n", stderr)
    }

    public func info(_ message: String) {
        log("INFO", message)
    }

    public func warn(_ message: String) {
        log("WARN", message)
    }

    public func error(_ message: String) {
        log("ERROR", message)
    }

    public func debug(_ message: String) {
        log("DEBUG", message)
    }

    private func log(_ level: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"

        // Write to file immediately to ensure logs are captured
        queue.async { [logURL] in
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: logURL)
            }
        }
        fputs("[\(level)] \(message)\n", stderr)
    }

    public func getRecentLogs(count: Int = 100) -> String {
        return queue.sync {
            guard let data = try? Data(contentsOf: logURL),
                  let text = String(data: data, encoding: .utf8) else {
                return "No logs"
            }
            let lines = text.components(separatedBy: "\n")
            let recent = lines.suffix(count)
            return recent.joined(separator: "\n")
        }
    }

    public func getLogPath() -> String {
        return logURL.path
    }
}
