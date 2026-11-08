import Foundation
import UIKit
import Compression

/// Reads MIDlet metadata (name, icon) from JAR manifest without starting JVM.
struct JARMetadata {
    let midletName: String
    let version: String?
    let vendor: String?
    let iconPath: String?
    let className: String?

    /// Read metadata from a JAR file by parsing its MANIFEST.MF
    static func read(from jarPath: String) -> JARMetadata? {
        guard let manifestData = ZIPReader.extractEntry(
            zipPath: jarPath, entryName: "META-INF/MANIFEST.MF"
        ) else { return nil }

        guard let manifestStr = String(data: manifestData, encoding: .utf8) else { return nil }

        let attrs = parseManifest(manifestStr)

        // Parse MIDlet-1: "DisplayName, IconPath, ClassName"
        var displayName = attrs["MIDlet-Name"] ?? ""
        var iconPath: String? = nil
        var className: String? = nil

        if let midlet1 = attrs["MIDlet-1"] {
            let parts = midlet1.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 1 && !parts[0].isEmpty { displayName = parts[0] }
            if parts.count >= 2 && !parts[1].isEmpty { iconPath = parts[1] }
            if parts.count >= 3 && !parts[2].isEmpty { className = parts[2] }
        }

        if displayName.isEmpty {
            displayName = URL(fileURLWithPath: jarPath).deletingPathExtension().lastPathComponent
        }

        return JARMetadata(
            midletName: displayName,
            version: attrs["MIDlet-Version"],
            vendor: attrs["MIDlet-Vendor"],
            iconPath: iconPath,
            className: className
        )
    }

    /// Extract icon image from JAR
    func readIcon(from jarPath: String) -> UIImage? {
        guard var path = iconPath, !path.isEmpty else { return nil }
        // Normalize path: remove leading /
        if path.hasPrefix("/") { path = String(path.dropFirst()) }

        guard let data = ZIPReader.extractEntry(zipPath: jarPath, entryName: path) else {
            return nil
        }
        return UIImage(data: data)
    }

    /// Parse MANIFEST.MF format (key: value with continuation lines)
    private static func parseManifest(_ text: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var currentKey: String? = nil
        var currentValue = ""

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Continuation line
                currentValue += line.dropFirst()
            } else if let colonIdx = line.firstIndex(of: ":") {
                // Save previous
                if let key = currentKey {
                    attrs[key] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                currentKey = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colonIdx)...])
            }
        }
        if let key = currentKey {
            attrs[key] = currentValue.trimmingCharacters(in: .whitespaces)
        }
        return attrs
    }
}

// MARK: - Minimal ZIP reader using zlib (system library)

enum ZIPReader {

    /// Extract a single entry from a ZIP file by name
    static func extractEntry(zipPath: String, entryName: String) -> Data? {
        let fileURL = URL(fileURLWithPath: zipPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: zipPath),
              let fileSize = attrs[.size] as? Int,
              fileSize <= 50_000_000 else { return nil } // 50 MB max for JAR metadata scan
        guard let fileData = try? Data(contentsOf: fileURL) else { return nil }

        return fileData.withUnsafeBytes { rawBuf -> Data? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let size = rawBuf.count

            // Find End of Central Directory (EOCD) — scan backwards for signature 0x06054b50
            guard let eocdOffset = findEOCD(base: base, size: size) else { return nil }

            let cdOffset = Int(readU32(base, eocdOffset + 16))   // offset of central directory
            let cdEntries = Int(readU16(base, eocdOffset + 10)) // total entries
            guard cdOffset >= 0, cdOffset < size else { return nil }

            // Walk central directory entries
            var pos = cdOffset
            for _ in 0..<cdEntries {
                guard pos + 46 <= size else { break }
                let sig = readU32(base, pos)
                guard sig == 0x02014b50 else { break }

                let method = readU16(base, pos + 10)
                let compSize = Int(readU32(base, pos + 20))
                let uncompSize = Int(readU32(base, pos + 24))
                let nameLen = Int(readU16(base, pos + 28))
                let extraLen = Int(readU16(base, pos + 30))
                let commentLen = Int(readU16(base, pos + 32))
                let localHeaderOff = Int(readU32(base, pos + 42))

                guard pos + 46 + nameLen <= size else { break }
                let name = String(bytes: UnsafeBufferPointer(start: base + pos + 46, count: nameLen), encoding: .utf8) ?? ""

                if name == entryName {
                    // Found! Read from local file header
                    return extractFromLocal(base: base, size: size, offset: localHeaderOff,
                                            method: method, compSize: compSize, uncompSize: uncompSize)
                }

                pos += 46 + nameLen + extraLen + commentLen
            }
            return nil
        }
    }

    private static func findEOCD(base: UnsafePointer<UInt8>, size: Int) -> Int? {
        // EOCD is at least 22 bytes, scan backwards
        let minPos = max(0, size - 65557) // max comment size is 65535
        for i in stride(from: size - 22, through: minPos, by: -1) {
            if readU32(base, i) == 0x06054b50 {
                return i
            }
        }
        return nil
    }

    private static func extractFromLocal(base: UnsafePointer<UInt8>, size: Int, offset: Int,
                                          method: UInt16, compSize: Int, uncompSize: Int) -> Data? {
        guard offset + 30 <= size else { return nil }
        let sig = readU32(base, offset)
        guard sig == 0x04034b50 else { return nil }

        let localNameLen = Int(readU16(base, offset + 26))
        let localExtraLen = Int(readU16(base, offset + 28))
        let dataStart = offset + 30 + localNameLen + localExtraLen

        guard dataStart + compSize <= size else { return nil }

        if method == 0 {
            // Stored (no compression)
            return Data(bytes: base + dataStart, count: compSize)
        } else if method == 8 {
            // Deflate — use system zlib via Compression framework
            let compressed = Data(bytes: base + dataStart, count: compSize)
            // Try raw DEFLATE decompression
            var decompressed = Data(count: uncompSize)
            let result = decompressed.withUnsafeMutableBytes { dstBuf in
                compressed.withUnsafeBytes { srcBuf in
                    compression_decode_buffer(
                        dstBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), uncompSize,
                        srcBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), compSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            return result > 0 ? decompressed.prefix(result) : nil
        }
        return nil
    }

    private static func readU16(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
    }

    private static func readU32(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(base[offset]) | (UInt32(base[offset + 1]) << 8) |
        (UInt32(base[offset + 2]) << 16) | (UInt32(base[offset + 3]) << 24)
    }
}
