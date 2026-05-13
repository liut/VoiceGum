import Foundation
import CZlib

enum Gzip {
    static func compress(_ data: Data) -> Data? {
        let count = data.count
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int32 = 0
        let ret = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int32 in
            gzip_compress(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(count), &outPtr, &outLen)
        }
        guard ret == 0 /* Z_OK */, let ptr = outPtr, outLen > 0 else { return nil }
        defer { free(ptr) }
        return Data(bytes: ptr, count: Int(outLen))
    }

    static func decompress(_ data: Data) -> Data? {
        let count = data.count
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int32 = 0
        let ret = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int32 in
            gzip_decompress(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(count), &outPtr, &outLen)
        }
        guard ret == 0 /* Z_OK */, let ptr = outPtr, outLen > 0 else { return nil }
        defer { free(ptr) }
        return Data(bytes: ptr, count: Int(outLen))
    }
}
