import Compression
import CoreGraphics
import Foundation

enum RFBError: LocalizedError {
    case closed
    case protocolError(String)
    case auth(String)

    var errorDescription: String? {
        switch self {
        case .closed: "The Mac closed the connection."
        case .protocolError(let message): message
        case .auth(let message): message
        }
    }
}

/// The remote screen as 32-bit pixels, 0xXXRRGGBB, top row first.
/// Decoding writes and the main actor takes pictures from different threads,
/// so every access holds the lock (none of them waits on anything).
final class Framebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _width: Int
    private var _height: Int
    private var pixels: [UInt32]

    var width: Int { lock.lock(); defer { lock.unlock() }; return _width }
    var height: Int { lock.lock(); defer { lock.unlock() }; return _height }

    init(width: Int, height: Int) {
        _width = width
        _height = height
        pixels = [UInt32](repeating: 0xFF20_2024, count: width * height)
    }

    func resize(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        _width = width
        _height = height
        pixels = [UInt32](repeating: 0xFF20_2024, count: width * height)
    }

    func fill(x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        lock.lock(); defer { lock.unlock() }
        let width = _width
        guard let (x, y, w, h) = clip(x, y, w, h) else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in y..<y + h {
                let start = row * width + x
                for i in start..<start + w { buffer[i] = color }
            }
        }
    }

    func copy(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int, w: Int, h: Int) {
        lock.lock(); defer { lock.unlock() }
        let width = _width, height = _height
        guard clip(sx, sy, w, h) != nil, clip(dx, dy, w, h) != nil,
              sx + w <= width, dx + w <= width, sy + h <= height, dy + h <= height else { return }
        var region = [UInt32](repeating: 0, count: w * h)
        for row in 0..<h {
            let from = (sy + row) * width + sx
            region.replaceSubrange(row * w..<(row + 1) * w, with: pixels[from..<from + w])
        }
        for row in 0..<h {
            let to = (dy + row) * width + dx
            pixels.replaceSubrange(to..<to + w, with: region[row * w..<(row + 1) * w])
        }
    }

    private func clip(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Int, Int, Int, Int)? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(_width, x + w), y1 = min(_height, y + h)
        return x1 > x0 && y1 > y0 ? (x0, y0, x1 - x0, y1 - y0) : nil
    }

    /// Writes `count` pixels produced in reading order into the rectangle.
    func withRect(x: Int, y: Int, w: Int, h: Int, _ body: (inout RectWriter) throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }
        let width = _width, height = _height
        try pixels.withUnsafeMutableBufferPointer { buffer in
            var writer = RectWriter(buffer: buffer, stride: width, height: height, x: x, y: y, w: w, h: h)
            try body(&writer)
        }
    }

    /// A picture of part of the screen (or all of it), copied out so the
    /// framebuffer can keep changing underneath.
    func image(of region: CGRect? = nil) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let width = _width
        let whole = CGRect(x: 0, y: 0, width: width, height: _height)
        let area = (region ?? whole).intersection(whole).integral
        guard area.width >= 1, area.height >= 1 else { return nil }
        let x = Int(area.minX), y = Int(area.minY), w = Int(area.width), h = Int(area.height)
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt32.self)
            pixels.withUnsafeBufferPointer { source in
                for row in 0..<h {
                    let from = (y + row) * width + x
                    UnsafeMutableRawPointer(out.baseAddress! + row * w)
                        .copyMemory(from: source.baseAddress! + from, byteCount: w * 4)
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Puts pixels into a rectangle row by row, ignoring anything off-screen.
struct RectWriter {
    let buffer: UnsafeMutableBufferPointer<UInt32>
    let stride: Int
    let height: Int
    let x: Int, y: Int, w: Int, h: Int
    private var column = 0
    private var row = 0

    init(buffer: UnsafeMutableBufferPointer<UInt32>, stride: Int, height: Int, x: Int, y: Int, w: Int, h: Int) {
        self.buffer = buffer
        self.stride = stride
        self.height = height
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    var done: Bool { row >= h }

    @inline(__always)
    mutating func put(_ pixel: UInt32, count: Int = 1) {
        for _ in 0..<count {
            // A run that overshoots the rectangle must not spill into the rows below it.
            if row >= h { return }
            let px = x + column, py = y + row
            if px < stride, py < height, px >= 0, py >= 0 { buffer[py * stride + px] = pixel }
            column += 1
            if column == w { column = 0; row += 1 }
        }
    }

    /// Fills a sub-rectangle, relative to this rectangle.
    func fill(_ sx: Int, _ sy: Int, _ sw: Int, _ sh: Int, _ pixel: UInt32) {
        for ry in sy..<min(sy + sh, h) {
            let py = y + ry
            guard py >= 0, py < height else { continue }
            for rx in sx..<min(sx + sw, w) {
                let px = x + rx
                if px >= 0, px < stride { buffer[py * stride + px] = pixel }
            }
        }
    }
}

/// Bounds-checked reading over bytes already in memory.
struct ByteReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset = 0

    @inline(__always)
    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw RFBError.protocolError("Truncated screen data.") }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Bytes per ZRLE compressed pixel: 3 for 24-bit colour, 2 for 16-bit.
    var pixelBytes = 3

    /// A ZRLE compressed pixel, little-endian, as 0x00RRGGBB.
    @inline(__always)
    mutating func cpixel() throws -> UInt32 {
        guard offset + pixelBytes <= bytes.count else { throw RFBError.protocolError("Truncated screen data.") }
        defer { offset += pixelBytes }
        if pixelBytes == 2 { return PixelFormat.expand565(UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8) }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    }

    @inline(__always)
    mutating func runLength() throws -> Int {
        var length = 1
        var byte: UInt8
        repeat {
            byte = try u8()
            length += Int(byte)
        } while byte == 255
        return length
    }
}

/// One zlib stream for the whole connection, as ZRLE requires.
final class Inflater {
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var headerSkipped = false

    init() throws {
        let status = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { throw RFBError.protocolError("zlib unavailable.") }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
    }

    func inflate(_ input: [UInt8]) throws -> [UInt8] {
        var input = input
        if !headerSkipped, input.count >= 2 {
            // Compression's ZLIB is raw deflate: drop the 2-byte zlib header once.
            input.removeFirst(2)
            headerSkipped = true
        }
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 4)
        let chunk = 256 * 1024
        var scratch = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeBufferPointer { source in
            stream.pointee.src_ptr = source.baseAddress ?? UnsafePointer(bitPattern: 1)!
            stream.pointee.src_size = source.count
            repeat {
                let produced: Int = try scratch.withUnsafeMutableBufferPointer { destination in
                    stream.pointee.dst_ptr = destination.baseAddress!
                    stream.pointee.dst_size = chunk
                    let status = compression_stream_process(stream, 0)
                    guard status != COMPRESSION_STATUS_ERROR else {
                        throw RFBError.protocolError("Corrupt compressed screen data.")
                    }
                    return chunk - stream.pointee.dst_size
                }
                output.append(contentsOf: scratch[0..<produced])
                // All input can be taken in while output is still held back:
                // keep draining until a call yields nothing.
                if produced == 0 && stream.pointee.src_size == 0 { break }
            } while true
        }
        return output
    }
}

/// The two pixel formats the app asks the Mac for.
enum PixelFormat {
    /// 32 bits per pixel, 24-bit colour, little-endian, 0x00RRGGBB.
    static let full: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    /// 16 bits per pixel, RGB 5-6-5, little-endian: a third less to send.
    static let fast: [UInt8] = [16, 16, 0, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0, 0, 0, 0]

    @inline(__always)
    static func expand565(_ value: UInt32) -> UInt32 {
        let r = value >> 11 & 31, g = value >> 5 & 63, b = value & 31
        return (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2)
    }

    /// A pixel as sent in Raw and Hextile rectangles.
    @inline(__always)
    static func pixel(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int, size: Int) -> UInt32 {
        if size == 2 { return expand565(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8) }
        return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16
    }
}

enum ZRLE {
    /// Decodes one ZRLE rectangle (already inflated) into the framebuffer.
    static func decode(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int, pixelBytes: Int = 3,
                       into framebuffer: Framebuffer) throws {
        try data.withUnsafeBufferPointer { bytes in
            var reader = ByteReader(bytes: bytes)
            reader.pixelBytes = pixelBytes
            var palette = [UInt32](repeating: 0, count: 128)
            for ty in Swift.stride(from: y, to: y + h, by: 64) {
                let th = min(64, y + h - ty)
                for tx in Swift.stride(from: x, to: x + w, by: 64) {
                    let tw = min(64, x + w - tx)
                    try tile(&reader, &palette, x: tx, y: ty, w: tw, h: th, framebuffer)
                }
            }
        }
    }

    private static func tile(_ reader: inout ByteReader, _ palette: inout [UInt32],
                             x: Int, y: Int, w: Int, h: Int, _ framebuffer: Framebuffer) throws {
        let subencoding = Int(try reader.u8())
        switch subencoding {
        case 0:
            try framebuffer.withRect(x: x, y: y, w: w, h: h) { out in
                for _ in 0..<(w * h) { out.put(try reader.cpixel()) }
            }
        case 1:
            framebuffer.fill(x: x, y: y, w: w, h: h, color: try reader.cpixel())
        case 2...16:
            for i in 0..<subencoding { palette[i] = try reader.cpixel() }
            let bits = subencoding == 2 ? 1 : subencoding <= 4 ? 2 : 4
            let mask = UInt8((1 << bits) - 1)
            try framebuffer.withRect(x: x, y: y, w: w, h: h) { out in
                for _ in 0..<h {
                    var byte: UInt8 = 0
                    var left = 0
                    for _ in 0..<w {
                        if left == 0 { byte = try reader.u8(); left = 8 }
                        left -= bits
                        out.put(palette[Int(byte >> UInt8(left) & mask)])
                    }
                }
            }
        case 128:
            try framebuffer.withRect(x: x, y: y, w: w, h: h) { out in
                while !out.done {
                    let pixel = try reader.cpixel()
                    out.put(pixel, count: try reader.runLength())
                }
            }
        case 130...255:
            let size = subencoding - 128
            for i in 0..<size { palette[i] = try reader.cpixel() }
            try framebuffer.withRect(x: x, y: y, w: w, h: h) { out in
                while !out.done {
                    let index = try reader.u8()
                    let pixel = palette[Int(index & 0x7F)]
                    out.put(pixel, count: index & 0x80 != 0 ? try reader.runLength() : 1)
                }
            }
        default:
            throw RFBError.protocolError("Unknown ZRLE tile type \(subencoding).")
        }
    }
}
