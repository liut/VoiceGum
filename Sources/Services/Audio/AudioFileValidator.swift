import Foundation
import AVFoundation

public enum AudioFileValidator {
    public static let supportedExtensions = ["wav", "mp3", "m4a", "flac", "aac", "alac", "aiff", "caf", "mp4", "mov", "m4v"]
    public static let maxFileSize: Int64 = 500_000_000 // 500 MB

    public static func isValid(file url: URL) -> Bool {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        // Check file size to prevent memory exhaustion
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > maxFileSize {
            return false
        }
        return true
    }
}
