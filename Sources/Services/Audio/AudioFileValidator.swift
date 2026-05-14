import Foundation
import AVFoundation

public enum AudioFileValidator {
    public static let supportedExtensions = ["wav", "mp3", "m4a", "flac", "aac", "alac", "aiff", "caf", "mp4", "mov", "m4v"]
    public static let maxWavFileSize: Int64 = 200_000_000   // 200 MB
    public static let maxOtherFileSize: Int64 = 60_000_000  // 60 MB

    public static func maxFileSize(for url: URL) -> Int64 {
        url.pathExtension.lowercased() == "wav" ? maxWavFileSize : maxOtherFileSize
    }

    public static func isValid(file url: URL) -> Bool {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > maxFileSize(for: url) {
            return false
        }
        return true
    }
}
