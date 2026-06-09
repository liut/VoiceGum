import Darwin
import Foundation
import VoiceGumServices

// MARK: - Usage

func printUsage() {
    fputs("""
        Usage: voicegum-cli [options] [audio_file]

        Transcribe audio to text. Reads from stdin if no file is given.

        Options:
          -m, --model <id>     Model directory name (default: first available)
          -l, --language <code> Language: zh, en, ja, ko, auto (default: auto)
          -o, --output <path>  Write text to file instead of stdout
          -h, --help           Print this help

        Examples:
          voicegum-cli audio.mp3
          voicegum-cli audio.mp3 -l zh -o out.txt
          cat audio.mp3 | voicegum-cli

        Models directory: ~/Library/Application Support/VoiceGum/Models/<id>/
        """, stderr)
}

// MARK: - Argument Parsing

struct CLIArgs {
    var modelId: String?
    var language = "auto"
    var outputPath: String?
    var inputFile: String?
    var showHelp = false
}

func parseArgs(_ args: [String]) -> CLIArgs? {
    var parsed = CLIArgs()
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            parsed.showHelp = true
        case "-m", "--model":
            i += 1
            guard i < args.count else { fputs("voicegum-cli: -m requires a value\n", stderr); return nil }
            parsed.modelId = args[i]
        case "-l", "--language":
            i += 1
            guard i < args.count else { fputs("voicegum-cli: -l requires a value\n", stderr); return nil }
            parsed.language = args[i]
        case "-o", "--output":
            i += 1
            guard i < args.count else { fputs("voicegum-cli: -o requires a value\n", stderr); return nil }
            parsed.outputPath = args[i]
        default:
            if arg.hasPrefix("-") {
                fputs("voicegum-cli: unknown option \(arg)\n", stderr)
                return nil
            }
            parsed.inputFile = arg
        }
        i += 1
    }
    return parsed
}

// MARK: - Model Discovery

func discoverModelID() -> String? {
    let modelsDir = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("VoiceGum/Models")

    guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) else {
        return nil
    }
    for name in names {
        let dir = modelsDir.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            continue
        }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
        if files.contains(where: { $0.hasSuffix(".gguf") }) {
            return name
        }
    }
    return nil
}

// MARK: - Stdin Input

func resolveInputFile(from args: CLIArgs) throws -> URL {
    if let file = args.inputFile {
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.fileNotFound(file)
        }
        return url
    }

    // Check if stdin has data (not a TTY)
    if isatty(STDIN_FILENO) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw CLIError.noInput
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicegum_cli_\(UUID().uuidString).audio")
        try data.write(to: tempURL)
        return tempURL
    }

    throw CLIError.noInput
}

// MARK: - Errors

enum CLIError: Error, CustomStringConvertible {
    case noInput
    case fileNotFound(String)
    case noModelFound
    case transcriptionFailed(String)

    var description: String {
        switch self {
        case .noInput:
            return "No audio file specified and stdin is empty. Use -h for help."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .noModelFound:
            return "No model found. Download a model via the VoiceGum app first."
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        }
    }
}

// MARK: - Entry Point

@main
struct VoiceGumCLI {
    static func main() async {
        guard let args = parseArgs(CommandLine.arguments) else {
            printUsage()
            _exit(1)
        }
        if args.showHelp {
            printUsage()
            _exit(0)
        }

        let modelID: String
        if let specified = args.modelId {
            modelID = specified
        } else if let discovered = discoverModelID() {
            modelID = discovered
        } else {
            fputs("voicegum-cli: \(CLIError.noModelFound.description)\n", stderr)
            _exit(1)
        }

        let audioFile: URL
        do {
            audioFile = try resolveInputFile(from: args)
        } catch {
            fputs("voicegum-cli: \(error)\n", stderr)
            _exit(1)
        }

        let isTempFile = args.inputFile == nil
        defer { if isTempFile { try? FileManager.default.removeItem(at: audioFile) } }

        let service = GGMLTranscriptionService(modelId: modelID)

        let result: TranscriptionResult
        do {
            result = try await service.transcribe(file: audioFile, language: args.language)
        } catch {
            fputs("voicegum-cli: \(CLIError.transcriptionFailed(error.localizedDescription).description)\n", stderr)
            GGMLTranscriptionService.invalidateActiveModel()
            _exit(1)
        }

        GGMLTranscriptionService.invalidateActiveModel()

        if let outputPath = args.outputPath {
            do {
                try result.text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            } catch {
                fputs("voicegum-cli: failed to write output: \(error.localizedDescription)\n", stderr)
                _exit(1)
            }
        } else {
            print(result.text)
            fflush(stdout)
        }
        // Bypass ggml Metal static destructor crash on exit (see AppDelegate.swift:47-53)
        _exit(0)
    }
}
