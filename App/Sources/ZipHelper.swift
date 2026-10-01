import Foundation
import Compression

enum ZipError: Error, LocalizedError {
    case cannotEnumerate
    case emptyDirectory
    case invalidZip
    case unsupportedMethod
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate: return "无法读取文件夹"
        case .emptyDirectory: return "文件夹是空的"
        case .invalidZip: return "不是有效的 zip 文件"
        case .unsupportedMethod: return "不支持的压缩方式"
        case .ioError(let s): return s
        }
    }
}

// MARK: - CRC32

private let crcTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        table[i] = c
    }
    return table
}()

func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFFFFFF
}

// MARK: - 小端写入/读取

func appendU16(_ v: UInt16, to d: inout Data) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
}

func appendU32(_ v: UInt32, to d: inout Data) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
}

func readU16(_ d: Data, at o: Int) -> UInt16 {
    d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt16.self) }.littleEndian
}

func readU32(_ d: Data, at o: Int) -> UInt32 {
    d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }.littleEndian
}

// MARK: - 打包：文件夹 -> .zip（存储方式，不压缩，保证兼容）

// MARK: - 压缩：文件夹 -> .zip（流式写入，内存占用恒定，扩展里大文件夹不闪退）

/// 文件数超过 zip 格式上限时抛错（避免 UInt16 截断）
private let maxZipEntries = 65535

func zipDirectory(at src: URL, to zipFile: URL, progress: ((Int, Int, String) -> Void)? = nil) throws {
    let fm = FileManager.default
    let basePath = src.path.hasSuffix("/") ? src.path : src.path + "/"

    var files: [(rel: String, url: URL, isDir: Bool, size: UInt64)] = []
    guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles]) else {
        throw ZipError.cannotEnumerate
    }
    for case let url as URL in enumerator {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        var rel = String(url.path.dropFirst(basePath.count))
        guard !rel.isEmpty else { continue }
        if isDir.boolValue { rel += "/" }
        var size: UInt64 = 0
        if !isDir.boolValue {
            size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        }
        files.append((rel, url, isDir.boolValue, size))
    }
    if files.isEmpty { throw ZipError.emptyDirectory }
    if files.count > maxZipEntries { throw ZipError.ioError("文件数量超过65535，不支持") }

    if fm.fileExists(atPath: zipFile.path) { try fm.removeItem(at: zipFile) }
    fm.createFile(atPath: zipFile.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: zipFile) else {
        throw ZipError.ioError("无法创建压缩包")
    }
    defer { try? handle.close() }

    var central = Data()
    var offset: UInt64 = 0
    var count: UInt32 = 0
    let chunkSize = 1024 * 1024 // 每次只读 1MB，内存恒定

    func writeData(_ d: Data) throws {
        try handle.write(contentsOf: d)
        offset += UInt64(d.count)
        if offset > UInt64(UInt32.max) { throw ZipError.ioError("压缩包超过4GB，不支持") }
    }

    /// 第一遍：流式算 CRC（不占内存）
    func crcOfFile(_ url: URL) throws -> UInt32 {
        let rh = try FileHandle(forReadingFrom: url)
        defer { try? rh.close() }
        var crc: UInt32 = 0xFFFFFFFF
        while true {
            guard let chunk = try rh.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            for byte in chunk {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// 第二遍：流式拷贝进 zip
    func copyFile(_ url: URL) throws {
        let rh = try FileHandle(forReadingFrom: url)
        defer { try? rh.close() }
        while true {
            guard let chunk = try rh.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try writeData(chunk)
        }
    }

    for (i, f) in files.enumerated() {
        progress?(i + 1, files.count, f.rel)
        if f.size > UInt64(UInt32.max) { throw ZipError.ioError("单个文件超过4GB：\(f.rel)") }

        let nameData = f.rel.data(using: .utf8) ?? Data()
        let crc: UInt32 = f.isDir ? 0 : try crcOfFile(f.url)
        let size = UInt32(f.size)
        let localOffset = UInt32(offset)

        // Local file header（标准格式，无 data descriptor，兼容所有解压工具）
        var h = Data()
        appendU32(0x04034b50, to: &h)
        appendU16(20, to: &h)
        appendU16(0x0800, to: &h) // UTF-8
        appendU16(0, to: &h)     // method: stored
        appendU16(0, to: &h)     // time
        appendU16(0, to: &h)     // date
        appendU32(crc, to: &h)
        appendU32(size, to: &h)
        appendU32(size, to: &h)
        appendU16(UInt16(nameData.count), to: &h)
        appendU16(0, to: &h)
        h.append(nameData)
        try writeData(h)

        if !f.isDir {
            try copyFile(f.url)
        }

        // Central directory entry
        appendU32(0x02014b50, to: &central)
        appendU16(20, to: &central)
        appendU16(20, to: &central)
        appendU16(0x0800, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU32(crc, to: &central)
        appendU32(size, to: &central)
        appendU32(size, to: &central)
        appendU16(UInt16(nameData.count), to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU16(0, to: &central)
        appendU32(f.isDir ? 0x41FF0010 : 0x20FF0000, to: &central)
        appendU32(localOffset, to: &central)
        central.append(nameData)

        count += 1
    }

    let centralOffset = UInt32(offset)
    let centralSize = UInt32(central.count)
    try writeData(central)

    var end = Data()
    appendU32(0x06054b50, to: &end)
    appendU16(0, to: &end)
    appendU16(0, to: &end)
    appendU16(UInt16(count), to: &end)
    appendU16(UInt16(count), to: &end)
    appendU32(centralSize, to: &end)
    appendU32(centralOffset, to: &end)
    appendU16(0, to: &end)
    try writeData(end)
}

// MARK: - 解压：.zip -> 文件夹（流式，支持大文件；支持 stored / deflate）

/// 流式解压单个 deflate 数据块到输出文件
private func streamInflateToFile(fh: FileHandle, compSize: Int, outURL: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }
    fm.createFile(atPath: outURL.path, contents: nil)
    guard let outFH = try? FileHandle(forWritingTo: outURL) else { throw ZipError.ioError("无法创建输出文件") }
    defer { try? outFH.close() }

    // raw deflate 包一层 zlib 头，用 COMPRESSION_ZLIB 流式解码
    // 注意：compression_stream 需要完整的 zlib 流（含 Adler32 尾），我们手动补
    let inBufSize = 1 << 16  // 64KB
    let outBufSize = 1 << 16
    let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: inBufSize)
    defer { inBuf.deallocate() }
    let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outBufSize)
    defer { outBuf.deallocate() }

    var stream = compression_stream(dst_ptr: outBuf, dst_size: 0,
                                    src_ptr: UnsafePointer(inBuf), src_size: 0,
                                    state: nil)
    var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
    guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.unsupportedMethod }
    defer { compression_stream_destroy(&stream) }

    var remaining = compSize
    var firstChunk = true
    var finished = false

    // zlib 头
    let zlibHeader: [UInt8] = [0x78, 0x9C]

    while !finished {
        var chunk: Data
        if firstChunk {
            // 第一块：zlib 头 + 尽量多的数据
            let want = min(remaining, inBufSize - 2)
            let raw = fh.readData(ofLength: want)
            if raw.count != want { throw ZipError.invalidZip }
            remaining -= want
            var combined = Data(zlibHeader)
            combined.append(raw)
            chunk = combined
            firstChunk = false
        } else if remaining > 0 {
            let want = min(remaining, inBufSize)
            let raw = fh.readData(ofLength: want)
            if raw.count != want { throw ZipError.invalidZip }
            remaining -= want
            chunk = raw
        } else {
            // 数据读完，补 Adler32 占位尾（4字节0），让 zlib 流正常结束
            chunk = Data([0, 0, 0, 0])
        }

        let isLast = (remaining == 0)
        chunk.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            stream.src_ptr = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            stream.src_size = chunk.count
            var flags: Int32 = 0
            // 最后一块数据（含补的尾）给 FINALIZE 标志
            if isLast { flags = COMPRESSION_STREAM_FINALIZE }
            repeat {
                stream.dst_ptr = outBuf
                stream.dst_size = outBufSize
                status = compression_stream_process(&stream, flags)
                let produced = outBufSize - stream.dst_size
                if produced > 0 {
                    outFH.write(Data(bytes: outBuf, count: produced))
                }
            } while stream.dst_size == 0 && status == COMPRESSION_STATUS_OK
        }
        if isLast { finished = true }
        if status == COMPRESSION_STATUS_ERROR { throw ZipError.unsupportedMethod }
    }
}

func inflateRawDeflate(_ data: Data) -> Data? {
    if data.isEmpty { return Data() }
    // 包一层 zlib 头尾，用系统解码（Adler32 用占位，多数实现不强校验）
    var wrapped = Data([0x78, 0x9C])
    wrapped.append(data)
    wrapped.append(contentsOf: [0, 0, 0, 0])
    let dstCapacity = max(data.count * 4, 1024)

    return wrapped.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Data? in
        guard let srcBase = srcPtr.baseAddress else { return nil }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }
        let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_ZLIB)
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
        defer { scratch.deallocate() }
        let decoded = compression_decode_buffer(dst, dstCapacity,
                                                srcBase.assumingMemoryBound(to: UInt8.self),
                                                wrapped.count, nil, COMPRESSION_ZLIB)
        guard decoded > 0 else { return nil }
        return Data(bytes: dst, count: decoded)
    }
}

/// v19: 流式解压，大文件不爆内存
/// - Parameters:
///   - progress: (已解压文件数, 当前文件名) 回调用
func unzipFile(at zipURL: URL, to destDir: URL, progress: ((Int, String) -> Void)? = nil) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

    guard let fh = try? FileHandle(forReadingFrom: zipURL) else {
        throw ZipError.ioError("打不开 zip 文件")
    }
    defer { try? fh.close() }

    func readExactly(_ n: Int) throws -> Data {
        let d = fh.readData(ofLength: n)
        guard d.count == n else { throw ZipError.invalidZip }
        return d
    }
    func readU16(_ d: Data, at o: Int) -> UInt16 {
        d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt16.self) }.littleEndian
    }
    func readU32(_ d: Data, at o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }.littleEndian
    }

    var extracted = 0
    while true {
        // 读本地文件头（至少 30 字节，不够就结束）
        let header = fh.readData(ofLength: 30)
        if header.count == 0 { break }  // 正常结束
        guard header.count == 30 else { throw ZipError.invalidZip }
        let sig = readU32(header, at: 0)
        if sig == 0x02014b50 || sig == 0x06054b50 { break } // 中央目录/结尾
        guard sig == 0x04034b50 else { throw ZipError.invalidZip }

        let method = readU16(header, at: 8)
        let compSize = Int(readU32(header, at: 18))
        let nameLen = Int(readU16(header, at: 26))
        let extraLen = Int(readU16(header, at: 28))

        let nameData = try readExactly(nameLen)
        guard let name = String(data: nameData, encoding: .utf8) else { throw ZipError.invalidZip }
        if extraLen > 0 { _ = try readExactly(extraLen) }

        // 安全：防止 ../ 穿透
        let safeName = name.replacingOccurrences(of: "..", with: "_")
        let outURL = destDir.appendingPathComponent(safeName)

        if safeName.hasSuffix("/") {
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        } else {
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if method == 0 {
                // stored：分块拷贝
                if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }
                fm.createFile(atPath: outURL.path, contents: nil)
                guard let outFH = try? FileHandle(forWritingTo: outURL) else {
                    throw ZipError.ioError("无法创建输出文件")
                }
                defer { try? outFH.close() }
                var remaining = compSize
                while remaining > 0 {
                    let want = min(remaining, 1 << 20)  // 1MB 块
                    let chunk = fh.readData(ofLength: want)
                    guard chunk.count == want else { throw ZipError.invalidZip }
                    outFH.write(chunk)
                    remaining -= want
                }
            } else if method == 8 {
                try streamInflateToFile(fh: fh, compSize: compSize, outURL: outURL)
            } else {
                throw ZipError.unsupportedMethod
            }
        }
        extracted += 1
        progress?(extracted, (safeName as NSString).lastPathComponent)
    }
    if extracted == 0 { throw ZipError.invalidZip }
}
