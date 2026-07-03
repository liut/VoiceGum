import Foundation
import VoiceGumPreferences

/// Manages a `llama-server` child process with auto-port allocation, health-check polling,
/// and idle-timeout shutdown.
public actor LlamaServerManager {

    public static let shared = LlamaServerManager()

    private var process: Process?
    private var port: UInt16 = 0
    private var lastKwargs = ""
    private var idleWorkItem: DispatchWorkItem?
    private let idleTimeout: TimeInterval = 120

    public var baseURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/v1")
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Start

    /// Starts `llama-server` on a free ephemeral port. Returns the base URL (`http://127.0.0.1:{port}/v1`).
    /// If the server is already running with the same kwargs, reuses it.
    public func start(model: String, threads: Int = 4, sourceLang: String = "auto",
                      targetLang: String? = nil) async throws -> URL {
        let tgt = targetLang ?? AppPreferences.shared.translateTargetLanguage
        let kwargsKey = model.lowercased().contains("translategemma")
            ? "\(sourceLang)→\(tgt)" : ""
        if let url = baseURL, process?.isRunning == true, lastKwargs == kwargsKey {
            cancelIdleStop()
            return url
        }
        if process?.isRunning == true { stop() }

        guard let binPath = AppPreferences.shared.llamaCLIPath() else {
            throw LlamaServerError.binaryNotFound
        }

        stop()

        port = try findFreePort()
        let proc = Process()
        let exeName = URL(fileURLWithPath: binPath).lastPathComponent

        var args: [String] = []
        if exeName == "llama" {
            args.append("server")
        }
        let isLocal = model.hasPrefix("/") || model.hasPrefix("~") || model.hasSuffix(".gguf")
        if isLocal {
            args += ["-m", model]
        } else {
            args += ["--hf-repo", model]
        }

        if model.lowercased().contains("translategemma") {
            args += ["--no-jinja"]
            let src = translategemmaLangCode(sourceLang)
            let tgt = translategemmaLangCode(targetLang ?? AppPreferences.shared.translateTargetLanguage)
            args += ["--chat-template-kwargs", #"{"source_lang_code":"\#(src)","target_lang_code":"\#(tgt)"}"#]
        }

        args += [
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "-t", "\(threads)",
            "-ngl", "auto"
        ]

        proc.executableURL = URL(fileURLWithPath: binPath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let cmdLine = ([binPath] + args).joined(separator: " ")
        await Logger.shared.info("[llama-server] 启动: \(cmdLine)")

        try proc.run()
        process = proc

        // Poll /health until the server responds or times out.
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if proc.isRunning == false {
                throw LlamaServerError.processExited(proc.terminationStatus)
            }
            do {
                var req = URLRequest(url: healthURL, timeoutInterval: 1)
                req.httpMethod = "GET"
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 {
                    await Logger.shared.info("[llama-server] 就绪: port=\(self.port)")
                    lastKwargs = kwargsKey
                    return URL(string: "http://127.0.0.1:\(self.port)/v1")!
                }
            } catch {
                // Server not ready yet — keep polling.
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        stop()
        throw LlamaServerError.timeout
    }

    /// Maps BCP-47 language codes to ISO 639-1 for TranslageGemma.
    private func translategemmaLangCode(_ code: String) -> String {
        let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh") { return "zh" }
        if normalized.hasPrefix("ja") { return "ja" }
        if normalized.hasPrefix("ko") { return "ko" }
        if normalized.hasPrefix("en") || normalized == "auto" { return "en" }
        if normalized.count >= 2 { return String(normalized.prefix(2)) }
        return "en"
    }

    // MARK: - Stop

    public func stop() {
        cancelIdleStop()
        guard let proc = process else { return }
        proc.terminate()
        // Give it a moment, then force-kill if still alive.
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning {
                kill(pid, SIGKILL)
            }
        }
        proc.waitUntilExit()
        process = nil
        port = 0
        lastKwargs = ""
    }

    // MARK: - Idle management

    /// Call before each request — resets the idle timer.
    public func cancelIdleStop() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
    }

    /// Call after each request — schedules auto-stop after idle timeout.
    public func scheduleIdleStop() {
        cancelIdleStop()
        let workItem = DispatchWorkItem { [weak self] in
            Task { await self?.stop() }
        }
        idleWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + idleTimeout, execute: workItem)
    }

    // MARK: - Private

    private func findFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LlamaServerError.noPortAvailable }
        defer { close(fd) }

        // Set SO_REUSEADDR so the port can be immediately reused after close.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in(
            sin_len: __uint8_t(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: INADDR_ANY.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound >= 0 else { throw LlamaServerError.noPortAvailable }

        var boundAddr = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundSize) }
        }
        guard got >= 0 else { throw LlamaServerError.noPortAvailable }
        return boundAddr.sin_port.bigEndian
    }
}

public enum LlamaServerError: LocalizedError {
    case binaryNotFound
    case noPortAvailable
    case timeout
    case processExited(Int32)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "llama-server / llama 未找到，请确认已安装"
        case .noPortAvailable:
            return "无法分配可用端口"
        case .timeout:
            return "llama-server 启动超时"
        case .processExited(let code):
            return "llama-server 异常退出 (exit code \(code))"
        }
    }
}
