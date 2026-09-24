// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

/// Internal model representing a 512-byte POSIX ustar header block.
struct TarHeader {
    let filename: String
    let fileSize: UInt64
    let modificationDate: Date
    let isValidChecksum: Bool

    /// Creates a raw 512-byte POSIX header for writing.
    static func makeHeader(relativePath: String, fileSize: UInt64, modificationDate: Date) -> Data {
        var header = Data(count: 512)

        header.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            // File Name (bytes 0..99)
            let nameBytes = Array(relativePath.utf8.prefix(100))
            for i in 0..<nameBytes.count { ptr[i] = nameBytes[i] }

            // File Mode (bytes 100..107) -> "0000644\0"
            let mode = "0000644\0"
            memcpy(ptr + 100, mode, 8)

            // UID / GID (bytes 108..123)
            let uidGid = "0000000\0"
            memcpy(ptr + 108, uidGid, 8)
            memcpy(ptr + 116, uidGid, 8)

            // File Size in Octal (bytes 124..135)
            let sizeStr = String(format: "%011llo", fileSize)
            memcpy(ptr + 124, sizeStr, 11)

            // Modification Time in Octal (bytes 136..147)
            let mtimeInt = Int64(modificationDate.timeIntervalSince1970)
            let mtimeStr = String(format: "%011llo", mtimeInt)
            memcpy(ptr + 136, mtimeStr, 11)

            // Checksum placeholder (bytes 148..155) - filled with spaces (0x20)
            memset(ptr + 148, 0x20, 8)

            // Type Flag (byte 156) -> '0' (Regular file)
            ptr[156] = 0x30

            // Magic string "ustar\0" (bytes 257..262)
            let magic = "ustar\0"
            memcpy(ptr + 257, magic, 6)

            // Version "00" (bytes 263..264)
            let version = "00"
            memcpy(ptr + 263, version, 2)

            // Calculate Checksum over 512 bytes
            var sum: UInt32 = 0
            for i in 0..<512 {
                sum += UInt32(ptr[i])
            }

            // Write Octal Checksum into bytes 148..155
            let checksumStr = String(format: "%06o\0 ", sum)
            memcpy(ptr + 148, checksumStr, 8)
        }

        return header
    }

    /// Parses a 512-byte header block from an existing TAR archive.
    static func parse(from data: Data) -> TarHeader? {
        guard data.count == 512 else { return nil }

        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> TarHeader? in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }

            // Check null header (end marker)
            if data.allSatisfy({ $0 == 0 }) { return nil }

            // Extract filename
            let nameData = Data(bytes: ptr, count: 100)
            guard let filename = String(bytes: nameData.prefix(while: { $0 != 0 }), encoding: .utf8),
                  !filename.isEmpty else { return nil }

            // Extract size (bytes 124..134)
            let sizeData = Data(bytes: ptr + 124, count: 11)
            guard let sizeStr = String(bytes: sizeData, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let fileSize = UInt64(sizeStr, radix: 8) else { return nil }

            // Extract mtime (bytes 136..146)
            let mtimeData = Data(bytes: ptr + 136, count: 11)
            let mtimeStr = String(bytes: mtimeData, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let mtimeInt = TimeInterval(UInt64(mtimeStr, radix: 8) ?? 0)
            let modificationDate = Date(timeIntervalSince1970: mtimeInt)

            // Validate Checksum
            var calculatedSum: UInt32 = 0
            for i in 0..<512 {
                if i >= 148 && i < 156 {
                    calculatedSum += 32 // space character
                } else {
                    calculatedSum += UInt32(ptr[i])
                }
            }

            let checksumData = Data(bytes: ptr + 148, count: 6)
            let checksumStr = String(bytes: checksumData, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let storedChecksum = UInt32(checksumStr, radix: 8) ?? 0

            return TarHeader(
                filename: filename,
                fileSize: fileSize,
                modificationDate: modificationDate,
                isValidChecksum: calculatedSum == storedChecksum
            )
        }
    }
}
