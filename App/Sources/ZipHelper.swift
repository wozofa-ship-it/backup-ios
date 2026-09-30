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

func zipDirectory(at src: URL, to zipFile: URL) throws {
    let fm = FileManager.default
    let basePath = src.path.hasSuffix("/") ? src.path : src.path + "/"

    var files: [(rel: String, url: URL, isDir: Bool)] = []
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
        files.append((rel, url, isDir.boolValue))
    }
    if files.isEmpty { throw ZipError.emptyDirectory }

    var zip = Data()
    var central = Data()
    var count: UInt32 = 0

    for f in files {
        let nameData = f.rel.data(using: .utf8) ?? Data()
        let content: Data
        let crc: UInt32
        if f.isDir {
            content = Data()
            crc = 0
        } else {
            content = try Data(contentsOf: f.url)
            crc = crc32(content)
        }
        let localOffset = UInt32(zip.count)
        let size = UInt32(content.count)

        // Local file header
        appendU32(0x04034b50, to: &zip)
        appendU16(20, to: &zip)
        appendU16(0x0800, to: &zip) // UTF-8
        appendU16(0, to: &zip)     // method: stored
        appendU16(0, to: &zip)     // time
        appendU16(0, to: &zip)     // date
        appendU32(crc, to: &zip)
        appendU32(size, to: &zip)
        appendU32(size, to: &zip)
        appendU16(UInt16(nameData.count), to: &zip)
        appendU16(0, to: &zip)
        zip.append(nameData)
        zip.append(content)

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

    let centralOffset = UInt32(zip.count)
    let centralSize = UInt32(central.count)
    zip.append(central)

    appendU32(0x06054b50, to: &zip)
    appendU16(0, to: &zip)
    appendU16(0, to: &zip)
    appendU16(UInt16(count), to: &zip)
    appendU16(UInt16(count), to: &zip)
    appendU32(centralSize, to: &zip)
    appendU32(centralOffset, to: &zip)
    appendU16(0, to: &zip)

    try zip.write(to: zipFile)
}

// MARK: - 解压：.zip -> 文件夹（支持 stored / deflate）

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

func unzipFile(at zipURL: URL, to destDir: URL) throws {
    let fm = FileManager.default
    let data = try Data(contentsOf: zipURL)
    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

    var offset = 0
    var extracted = 0
    while offset + 30 <= data.count {
        let sig = readU32(data, at: offset)
        if sig == 0x02014b50 || sig == 0x06054b50 { break } // 中央目录/结尾
        guard sig == 0x04034b50 else { throw ZipError.invalidZip }

        let method = readU16(data, at: offset + 8)
        let compSize = Int(readU32(data, at: offset + 18))
        let nameLen = Int(readU16(data, at: offset + 26))
        let extraLen = Int(readU16(data, at: offset + 28))
        let nameStart = offset + 30
        guard nameStart + nameLen <= data.count else { throw ZipError.invalidZip }
        let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
        guard let name = String(data: nameData, encoding: .utf8) else { throw ZipError.invalidZip }
        let dataStart = nameStart + nameLen + extraLen
        guard dataStart + compSize <= data.count else { throw ZipError.invalidZip }
        let compData = data.subdata(in: dataStart..<(dataStart + compSize))

        let outURL = destDir.appendingPathComponent(name)
        if name.hasSuffix("/") {
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        } else {
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content: Data
            if method == 0 {
                content = compData
            } else if method == 8 {
                guard let inflated = inflateRawDeflate(compData) else { throw ZipError.unsupportedMethod }
                content = inflated
            } else {
                throw ZipError.unsupportedMethod
            }
            try content.write(to: outURL)
        }
        extracted += 1
        offset = dataStart + compSize
    }
    if extracted == 0 { throw ZipError.invalidZip }
}
