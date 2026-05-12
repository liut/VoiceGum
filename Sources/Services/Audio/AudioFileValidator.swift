import Foundation
import AVFoundation

public enum AudioFileValidator {
    public static let supportedExtensions = ["wav", "mp3", "m4a", "flac", "aac", "alac", "aiff", "caf", "mp4", "mov", "m4v"]

    public static func isValid(file url: URL) -> Bool {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        return true
    }

    public static func audioFormat(for url: URL) -> AVAudioFormat? {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return nil
        }
        return audioFile.processingFormat
    }
}
