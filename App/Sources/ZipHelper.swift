import Foundation
import Compression

enum ZipError: Error, LocalizedError {
    case cannotEnumerate
    case emptyDirectory
    case invalidZip
    case truncatedFile   // v20: 文件被截断（压缩时闪退导致的不完整 zip）
    case badHeader       // v20: 文件头不是 zip
    case unsupportedMethod
    case unsupportedMethodNumber(Int)
    case partialFailure(failed: Int, total: Int)  // v25: 部分文件失败，其余已解出
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate: return "无法读取文件夹"
        case .emptyDirectory: return "文件夹是空的"
        case .invalidZip: return "不是有效的 zip 文件"
        case .truncatedFile: return "zip 文件不完整（压缩时闪退导致），请删掉重新压缩"
        case .badHeader: return "文件头不是 zip 格式，文件已损坏"
        case .unsupportedMethod: return "不支持的压缩方式"
        case .unsupportedMethodNumber(let m): return "不支持的压缩方式 (method=\(m)，仅支持 stored/deflate)"
        case .partialFailure(let f, let t): return "解压完成 \(t - f)/\(t) 个文件，\(f) 个失败（已跳过）"
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

/// v25: 用 SWCompression 的纯 Swift Deflate 解码器（MIT），不依赖系统 API hack
func inflateRawDeflate(_ data: Data, uncompSize: Int = 0) -> Data? {
    if data.isEmpty { return Data() }
    do {
        return try Deflate.decompress(data: data)
    } catch {
        return nil
    }
}

/// v21: 用中央目录解析（标准做法），支持 data descriptor 的 zip（如系统"压缩"生成的）
/// - Parameters:
///   - progress: (已解压文件数, 当前文件名) 回调用
func unzipFile(at zipURL: URL, to destDir: URL, progress: ((Int, String) -> Void)? = nil) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

    guard let fh = try? FileHandle(forReadingFrom: zipURL) else {
        throw ZipError.ioError("打不开 zip 文件")
    }
    defer { try? fh.close() }

    let fileSize = (try? fm.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
    guard fileSize >= 22 else { throw ZipError.badHeader }

    func readU16(_ d: Data, at o: Int) -> UInt16 {
        d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt16.self) }.littleEndian
    }
    func readU32(_ d: Data, at o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }.littleEndian
    }
    func readAt(_ offset: Int, _ n: Int) throws -> Data {
        try fh.seek(toOffset: UInt64(offset))
        let d = fh.readData(ofLength: n)
        guard d.count == n else { throw ZipError.truncatedFile }
        return d
    }

    // 1. 找 EOCD（文件尾 64KB 内搜 0x06054b50）
    let tailSize = min(fileSize, 65557 + 22)
    let tail = try readAt(fileSize - tailSize, tailSize)
    var eocdOffsetInTail: Int? = nil
    var i = tail.count - 22
    while i >= 0 {
        if readU32(tail, at: i) == 0x06054b50 { eocdOffsetInTail = i; break }
        i -= 1
    }
    guard let eocdRel = eocdOffsetInTail else { throw ZipError.truncatedFile }
    let cdCount = Int(readU16(tail, at: eocdRel + 10))
    let cdOffset = Int(readU32(tail, at: eocdRel + 16))
    guard cdCount > 0 else { throw ZipError.invalidZip }

    // 2. 逐条读中央目录
    var extracted = 0
    var failed = 0
    var cdPos = cdOffset
    for _ in 0..<cdCount {
        let h = try readAt(cdPos, 46)
        guard readU32(h, at: 0) == 0x02014b50 else { throw ZipError.invalidZip }
        let method = readU16(h, at: 10)
        let compSize = Int(readU32(h, at: 20))
        let uncompSize = Int(readU32(h, at: 24))
        let nameLen = Int(readU16(h, at: 28))
        let extraLen = Int(readU16(h, at: 30))
        let commentLen = Int(readU16(h, at: 32))
        let localOffset = Int(readU32(h, at: 42))
        cdPos += 46
        let nameData = try readAt(cdPos, nameLen)
        cdPos += nameLen + extraLen + commentLen
        guard let name = String(data: nameData, encoding: .utf8) else { continue }

        let safeName = name.replacingOccurrences(of: "..", with: "_")
        let outURL = destDir.appendingPathComponent(safeName)
        if safeName.hasSuffix("/") {
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
            continue
        }
        // 3. 跳到本地头，算出数据起始位置
        let lh = try readAt(localOffset, 30)
        guard readU32(lh, at: 0) == 0x04034b50 else { throw ZipError.invalidZip }
        let lhNameLen = Int(readU16(lh, at: 26))
        let lhExtraLen = Int(readU16(lh, at: 28))
        let dataStart = localOffset + 30 + lhNameLen + lhExtraLen

        try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }
        // v25: 单个文件失败只跳过不中断，全部跑完再报部分失败
        do {
            if method == 0 {
                // stored：分块拷贝
                fm.createFile(atPath: outURL.path, contents: nil)
                guard let outFH = try? FileHandle(forWritingTo: outURL) else {
                    throw ZipError.ioError("无法创建输出文件")
                }
                defer { try? outFH.close() }
                try fh.seek(toOffset: UInt64(dataStart))
                var remaining = compSize
                while remaining > 0 {
                    let want = min(remaining, 1 << 20)
                    let chunk = fh.readData(ofLength: want)
                    guard chunk.count == want else { throw ZipError.truncatedFile }
                    outFH.write(chunk)
                    remaining -= want
                }
            } else if method == 8 {
                let compData = try readAt(dataStart, compSize)
                guard let inflated = inflateRawDeflate(compData, uncompSize: uncompSize) else { throw ZipError.unsupportedMethod }
                try inflated.write(to: outURL)
            } else {
                throw ZipError.unsupportedMethodNumber(Int(method))
            }
        } catch {
            failed += 1
            progress?(extracted + failed, "跳过：\((safeName as NSString).lastPathComponent)")
            continue
        }
        extracted += 1
        progress?(extracted + failed, (safeName as NSString).lastPathComponent)
    }
    if extracted == 0 && failed == 0 { throw ZipError.invalidZip }
    if failed > 0 { throw ZipError.partialFailure(failed: failed, total: extracted + failed) }
}
