// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation
import XCTest
@testable import TarBackup

final class TarHeaderTests: XCTestCase {
    func testHeaderRoundTripPreservesMetadataAndProducesValidChecksum() throws {
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)

        let data = TarHeader.makeHeader(
            relativePath: "images/photo.heic",
            fileSize: 12_345,
            modificationDate: modificationDate
        )
        let header = try XCTUnwrap(TarHeader.parse(from: data))

        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(header.filename, "images/photo.heic")
        XCTAssertEqual(header.fileSize, 12_345)
        XCTAssertEqual(header.modificationDate, modificationDate)
        XCTAssertTrue(header.isValidChecksum)
        XCTAssertEqual(String(decoding: data[257..<262], as: UTF8.self), "ustar")
    }

    func testParseRejectsBlocksWithInvalidLength() {
        XCTAssertNil(TarHeader.parse(from: Data(count: 511)))
        XCTAssertNil(TarHeader.parse(from: Data(count: 513)))
    }

    func testParseRecognizesZeroFilledEndMarker() {
        XCTAssertNil(TarHeader.parse(from: Data(count: 512)))
    }

    func testParseReportsInvalidChecksumWhenHeaderIsCorrupted() throws {
        var data = TarHeader.makeHeader(
            relativePath: "file.txt",
            fileSize: 42,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        data[200] = 1

        let header = try XCTUnwrap(TarHeader.parse(from: data))

        XCTAssertFalse(header.isValidChecksum)
    }

    func testFilenameFieldUsesTheEntire100ByteRange() throws {
        let filename = String(repeating: "n", count: 100)
        let data = TarHeader.makeHeader(
            relativePath: filename,
            fileSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(Array(data[0..<100]), Array(filename.utf8))
        XCTAssertEqual(try XCTUnwrap(TarHeader.parse(from: data)).filename, filename)
    }

    func test99ByteFilenameIsFollowedByNullTerminator() throws {
        let filename = String(repeating: "n", count: 99)
        let data = TarHeader.makeHeader(
            relativePath: filename,
            fileSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(Array(data[0..<99]), Array(filename.utf8))
        XCTAssertEqual(data[99], 0)
        XCTAssertEqual(try XCTUnwrap(TarHeader.parse(from: data)).filename, filename)
    }

    func testOversizedFilenameCannotOverwriteBytesOutsideNameField() {
        let maximumName = String(repeating: "n", count: 100)
        let oversizedName = String(repeating: "n", count: 511)
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)

        let expectedHeader = TarHeader.makeHeader(
            relativePath: maximumName,
            fileSize: 42,
            modificationDate: modificationDate
        )
        let oversizedNameHeader = TarHeader.makeHeader(
            relativePath: oversizedName,
            fileSize: 42,
            modificationDate: modificationDate
        )

        XCTAssertEqual(
            oversizedNameHeader,
            expectedHeader,
            "Bytes after name[0...99] must not be modified by an oversized filename"
        )
    }

    func testHeaderWritesEveryUstarFieldToItsDefinedByteRange() throws {
        let filename = "file.txt"
        let largeRepresentableValue: UInt64 = 4_294_967_296
        let data = TarHeader.makeHeader(
            relativePath: filename,
            fileSize: largeRepresentableValue,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(largeRepresentableValue))
        )

        var expectedName = Array(filename.utf8)
        expectedName.append(contentsOf: repeatElement(0, count: 100 - expectedName.count))

        XCTAssertEqual(Array(data[0..<100]), expectedName, "name must occupy bytes 0...99")
        XCTAssertEqual(Array(data[100..<108]), Array("0000644\0".utf8), "mode must occupy bytes 100...107")
        XCTAssertEqual(Array(data[108..<116]), Array("0000000\0".utf8), "uid must occupy bytes 108...115")
        XCTAssertEqual(Array(data[116..<124]), Array("0000000\0".utf8), "gid must occupy bytes 116...123")
        XCTAssertEqual(Array(data[124..<136]), Array("40000000000\0".utf8), "size must occupy bytes 124...135")
        XCTAssertEqual(Array(data[136..<148]), Array("40000000000\0".utf8), "mtime must occupy bytes 136...147")

        let checksumField = Array(data[148..<156])
        XCTAssertTrue(checksumField[0..<6].allSatisfy { (48...55).contains($0) })
        XCTAssertEqual(checksumField[6], 0, "checksum byte 154 must be NUL")
        XCTAssertEqual(checksumField[7], 32, "checksum byte 155 must be a space")

        XCTAssertEqual(data[156], Character("0").asciiValue, "type flag must occupy byte 156")
        XCTAssertTrue(data[157..<257].allSatisfy { $0 == 0 }, "link name must occupy bytes 157...256")
        XCTAssertEqual(Array(data[257..<263]), Array("ustar\0".utf8), "magic must occupy bytes 257...262")
        XCTAssertEqual(Array(data[263..<265]), Array("00".utf8), "version must occupy bytes 263...264")
        XCTAssertTrue(data[265..<512].allSatisfy { $0 == 0 }, "unused fields must remain zero-filled")

        let parsedHeader = try XCTUnwrap(TarHeader.parse(from: data))
        XCTAssertEqual(parsedHeader.fileSize, largeRepresentableValue)
        XCTAssertEqual(parsedHeader.modificationDate.timeIntervalSince1970, TimeInterval(largeRepresentableValue))
        XCTAssertTrue(parsedHeader.isValidChecksum)
    }
}
