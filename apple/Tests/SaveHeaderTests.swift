import CoreGraphics
import XCTest

/// Builds a synthetic original-Skyrim `.ess` prefix: magic, u32 header size, header fields,
/// then the screenshot (RGB for version 9, RGBA for 11+), then an arbitrary trailer.
struct SyntheticSaveHeader {
    var magic = Data("TESV_SAVEGAME".utf8)
    var version: UInt32 = 9
    var saveNumber: UInt32 = 7
    var playerName = "Lydia"
    var declaredNameLength: UInt16?
    var level: UInt32 = 23
    var location = "Whiterun"
    var gameDate = "4E 201, Morndas, 9:41 PM"
    var race = "NordRace"
    var shotWidth: UInt32 = 4
    var shotHeight: UInt32 = 2
    var headerSizeOverride: UInt32?
    var trailer = Data("change-forms".utf8)

    var channels: Int { version >= 11 ? 4 : 3 }
    private var pixelCount: Int {
        shotWidth <= 2048 && shotHeight <= 2048 ? Int(shotWidth) * Int(shotHeight) : 0
    }

    var fields: Data {
        var data = Data()
        data.appendLittleEndian(version)
        data.appendLittleEndian(saveNumber)
        data.appendWString(playerName, declaredLength: declaredNameLength)
        data.appendLittleEndian(level)
        data.appendWString(location)
        data.appendWString(gameDate)
        data.appendWString(race)
        data.appendLittleEndian(UInt16(1))                 // sex
        data.appendLittleEndian(Float(12.5).bitPattern)    // current experience
        data.appendLittleEndian(Float(300).bitPattern)     // level-up experience
        data.appendLittleEndian(UInt64(130_000_000_000_000_000)) // FILETIME
        data.appendLittleEndian(shotWidth)
        data.appendLittleEndian(shotHeight)
        return data
    }

    /// Pixel i is (10i, 10i+1, 10i+2), plus alpha 7 for four-channel formats.
    var screenshot: Data {
        var data = Data()
        for index in 0..<pixelCount {
            data.append(contentsOf: [UInt8(truncatingIfNeeded: index * 10), UInt8(truncatingIfNeeded: index * 10 + 1),
                                     UInt8(truncatingIfNeeded: index * 10 + 2)])
            if channels == 4 { data.append(7) }
        }
        return data
    }

    var expectedRGBA: Data {
        var data = Data()
        for index in 0..<pixelCount {
            data.append(contentsOf: [UInt8(truncatingIfNeeded: index * 10), UInt8(truncatingIfNeeded: index * 10 + 1),
                                     UInt8(truncatingIfNeeded: index * 10 + 2), 255])
        }
        return data
    }

    /// Offset just past the last header field.
    var headerEnd: Int { magic.count + 4 + fields.count }

    func build() -> Data {
        var data = magic
        let fields = fields
        data.appendLittleEndian(headerSizeOverride ?? UInt32(fields.count))
        data.append(fields)
        data.append(screenshot)
        data.append(trailer)
        return data
    }
}

final class SaveHeaderTests: XCTestCase {
    func testParsesOriginalV9HeaderAndRGBThumbnail() throws {
        let synthetic = SyntheticSaveHeader()
        let header = try XCTUnwrap(SaveHeader.parse(synthetic.build()))
        XCTAssertEqual(header.version, 9)
        XCTAssertEqual(header.saveNumber, 7)
        XCTAssertEqual(header.playerName, "Lydia")
        XCTAssertEqual(header.level, 23)
        XCTAssertEqual(header.location, "Whiterun")
        XCTAssertEqual(header.gameDate, "4E 201, Morndas, 9:41 PM")
        XCTAssertEqual(header.race, "NordRace")
        XCTAssertEqual(header.thumbnailWidth, 4)
        XCTAssertEqual(header.thumbnailHeight, 2)
        XCTAssertEqual(header.thumbnailRGBA, synthetic.expectedRGBA)
        XCTAssertEqual(Array(header.thumbnailRGBA.prefix(8)), [0, 1, 2, 255, 10, 11, 12, 255])

        let image = try XCTUnwrap(header.thumbnail())
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)
    }

    func testFourChannelFormatsUseTheWiderStride() throws {
        let synthetic = SyntheticSaveHeader(version: 12)
        let header = try XCTUnwrap(SaveHeader.parse(synthetic.build()))
        XCTAssertEqual(header.thumbnailRGBA, synthetic.expectedRGBA, "Alpha is ignored and forced opaque")
    }

    func testParsingAnUnalignedSliceReadsTheSameBytes() throws {
        let synthetic = SyntheticSaveHeader()
        let padded = Data(repeating: 0xEE, count: 5) + synthetic.build()
        let slice = padded.dropFirst(5)
        XCTAssertEqual(slice.startIndex, 5, "Precondition: a slice that does not start at zero")
        let header = try XCTUnwrap(SaveHeader.parse(slice))
        XCTAssertEqual(header.playerName, "Lydia")
        XCTAssertEqual(header.thumbnailRGBA, synthetic.expectedRGBA)
    }

    func testEveryTruncationIsNilOrThumbnailFreeWithoutCrashing() {
        let synthetic = SyntheticSaveHeader()
        let full = synthetic.build()
        let shotEnd = synthetic.headerEnd + synthetic.screenshot.count
        for length in 0...full.count {
            let header = SaveHeader.parse(full.prefix(length))
            if length < synthetic.headerEnd {
                XCTAssertNil(header, "length \(length)")
            } else if length < shotEnd {
                XCTAssertEqual(header?.playerName, "Lydia", "length \(length)")
                XCTAssertEqual(header?.thumbnailWidth, 0, "A partial screenshot is dropped, length \(length)")
                XCTAssertEqual(header?.thumbnailRGBA.isEmpty, true, "length \(length)")
            } else {
                XCTAssertEqual(header?.thumbnailRGBA, synthetic.expectedRGBA, "length \(length)")
            }
        }
    }

    func testWrongMagicIsRejected() {
        for magic in ["TESV_SAVEGAMX", "TES4SAVEGAME_", "tesv_savegame", "XXXXXXXXXXXXX"] {
            XCTAssertNil(SaveHeader.parse(SyntheticSaveHeader(magic: Data(magic.utf8)).build()), magic)
        }
        XCTAssertNil(SaveHeader.parse(Data()))
        XCTAssertNil(SaveHeader.parse(SaveHeader.magic))
    }

    func testAbsurdStringLengthsAreRejected() throws {
        XCTAssertNil(SaveHeader.parse(SyntheticSaveHeader(declaredNameLength: 0xFFFF).build()))
        let tooLong = String(repeating: "a", count: 513)
        XCTAssertNil(SaveHeader.parse(SyntheticSaveHeader(playerName: tooLong).build()), "Over the 512-byte cap")
        let longest = String(repeating: "a", count: 512)
        let header = try XCTUnwrap(SaveHeader.parse(SyntheticSaveHeader(playerName: longest).build()))
        XCTAssertEqual(header.playerName, longest)
    }

    func testAbsurdScreenshotGeometryDropsTheThumbnailWithoutCrashing() throws {
        let cases: [SyntheticSaveHeader] = [
            SyntheticSaveHeader(shotWidth: .max, shotHeight: .max),      // product overflows Int
            SyntheticSaveHeader(shotWidth: 3_100_000_000, shotHeight: 3_100_000_000),
            SyntheticSaveHeader(shotWidth: 1_025, shotHeight: 1),
            SyntheticSaveHeader(shotWidth: 0, shotHeight: 2),
            SyntheticSaveHeader(headerSizeOverride: 8),                  // screenshot would overlap fields
            SyntheticSaveHeader(headerSizeOverride: .max),               // screenshot beyond the data
        ]
        for synthetic in cases {
            let header = try XCTUnwrap(SaveHeader.parse(synthetic.build()),
                                       "\(synthetic.shotWidth)x\(synthetic.shotHeight)")
            XCTAssertEqual(header.playerName, "Lydia")
            XCTAssertEqual(header.thumbnailWidth, 0)
            XCTAssertTrue(header.thumbnailRGBA.isEmpty)
            XCTAssertNil(header.thumbnail())
        }
    }
}
