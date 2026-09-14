import CZlib
import Foundation

/// Streaming gzip/zlib decompressor backed by the platform's libz.
///
/// Used by `import-db` (Sortie 5) to decompress a `.sql.gz` dump while
/// streaming it into the database container, without ever holding the whole
/// (potentially multi-gigabyte) dump in memory: callers feed bounded input
/// chunks to ``inflate(_:)`` and get bounded output chunks back.
///
/// `windowBits` of `15 + 32` (`MAX_WBITS + 32`) makes zlib auto-detect either
/// a gzip or a zlib stream header, so this also happens to accept a raw zlib
/// stream if one is ever fed to it.
final class GzipInflateStream {
    enum InflateError: Error, CustomStringConvertible, Equatable {
        case initFailed(Int32)
        case inflateFailed(Int32, String)
        /// Input ended before the gzip trailer: the file is truncated.
        case truncated

        var description: String {
            switch self {
            case .initFailed(let code):
                "zlib inflateInit2 failed (code \(code))"
            case .inflateFailed(let code, let message):
                "zlib inflate failed (code \(code)): \(message)"
            case .truncated:
                "gzip input ended before the end of the compressed stream (truncated file?)"
            }
        }
    }

    /// Size of the reusable output buffer used to drain each `inflate()` call.
    private static let outputBufferSize = 256 * 1024

    private var stream = z_stream()
    /// Set once zlib reports `Z_STREAM_END`; further input is ignored.
    private(set) var finished = false
    private var closed = false

    init() throws {
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        let windowBits: Int32 = 15 + 32
        let result = CZlib.inflateInit2_(&stream, windowBits, CZlib.zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else { throw InflateError.initFailed(result) }
    }

    deinit {
        if !closed {
            CZlib.inflateEnd(&stream)
        }
    }

    /// Feeds `input` (may be empty, e.g. to flush at end-of-stream) and
    /// returns whatever decompressed bytes zlib has ready. Once ``finished``
    /// becomes true (the gzip trailer has been consumed) further calls are a
    /// no-op returning empty data.
    func inflate(_ input: Data) throws -> Data {
        guard !finished, !closed else { return Data() }
        guard !input.isEmpty else { return Data() }

        var output = Data()
        var inputCopy = input
        var outBuffer = [UInt8](repeating: 0, count: Self.outputBufferSize)

        try inputCopy.withUnsafeMutableBytes { (rawIn: UnsafeMutableRawBufferPointer) in
            stream.next_in = rawIn.bindMemory(to: UInt8.self).baseAddress
            stream.avail_in = UInt32(rawIn.count)

            repeat {
                let produced: Int = try outBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = UInt32(outPtr.count)
                    let code = CZlib.inflate(&stream, Z_NO_FLUSH)
                    switch code {
                    case Z_OK, Z_BUF_ERROR:
                        break
                    case Z_STREAM_END:
                        finished = true
                    default:
                        let message = stream.msg.map { String(cString: $0) } ?? "unknown error"
                        throw InflateError.inflateFailed(code, message)
                    }
                    return outPtr.count - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: outBuffer[0..<produced])
                }
                if finished { break }
            } while stream.avail_out == 0
        }
        return output
    }

    /// Releases zlib's internal state early. `inflate(_:)` after this is a no-op.
    func close() {
        guard !closed else { return }
        CZlib.inflateEnd(&stream)
        closed = true
    }
}
