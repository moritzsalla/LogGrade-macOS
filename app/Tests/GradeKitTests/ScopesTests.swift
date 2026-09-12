import CoreGraphics
import XCTest
@testable import GradeKit

final class ScopesTests: XCTestCase {
    /// A solid patch, so every assertion is about one known colour.
    private func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 32) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("no bitmap context") }
        context.setFillColor(red: r, green: g, blue: b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { throw XCTSkip("no image") }
        return image
    }

    func testASolidGreyIsOneSpikeAndNoChroma() throws {
        let scopes = Scopes.measure(try solid(0.5, 0.5, 0.5), stride: 1)
        XCTAssertGreaterThan(scopes.sampleCount, 0)
        // One occupied bin, at mid grey.
        let occupied = scopes.luma.enumerated().filter { $0.element > 0 }.map(\.offset)
        XCTAssertEqual(occupied.count, 1, "a solid patch should be one level, got \(occupied)")
        XCTAssertEqual(occupied[0], 127, accuracy: 1)
        // And it sits at the centre of the vectorscope, because grey has no chroma.
        let p = Scopes.vectorPosition(0.5, 0.5, 0.5)
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
    }

    func testTheRampFillsTheRangeAndNamesItsEnds() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 256, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<256 {
            let v = Double(x) / 255
            context.setFillColor(red: v, green: v, blue: v, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 8))
        }
        let scopes = Scopes.measure(context.makeImage()!, stride: 1)
        XCTAssertEqual(scopes.floorLuma, 0, "a ramp starts at black")
        XCTAssertEqual(scopes.peakLuma, 255, "and reaches white")
        // Broadly flat rather than exactly one pixel per level: drawing through a colour-managed
        // context is not an identity transform, so a few adjacent levels collapse into each other.
        // Measured at 205 of 256 occupied here — the assertion is that the ramp COVERS the range,
        // which is what a scope is read for, not that the drawing path is lossless.
        let occupied = scopes.luma.filter { $0 > 0 }.count
        XCTAssertGreaterThan(occupied, 180, "the ramp should cover most of the range, got \(occupied)")
        let quarters = stride(from: 0, to: 256, by: 64).map { start in
            scopes.luma[start..<min(256, start + 64)].reduce(0, +)
        }
        XCTAssertTrue(quarters.allSatisfy { $0 > 0 }, "a quarter of the range is empty: \(quarters)")
    }

    func testTheReferencesLandWhereTheirHuesShould() {
        // Not a colour-science claim, a sanity one: the three calibration colours have to sit in
        // different quadrants, or a vectorscope with them drawn on it tells you nothing.
        let plate = Scopes.vectorPosition(0.953, 0.765, 0.000)
        let red = Scopes.vectorPosition(0.800, 0.024, 0.020)
        let blue = Scopes.vectorPosition(0.024, 0.224, 0.443)
        XCTAssertLessThan(plate.x, 0.5, "yellow is short of blue")
        XCTAssertGreaterThan(blue.x, 0.5, "blue is long of blue")
        XCTAssertLessThan(red.y, 0.5, "red is high on the red axis")
        XCTAssertEqual(Scopes.references.count, 3)
        XCTAssertTrue(Scopes.references.allSatisfy { !$0.ral.isEmpty },
                      "each reference names the standard it comes from")
    }

    func testAParadeSeparatesTheChannels() throws {
        let scopes = Scopes.measure(try solid(1.0, 0.0, 0.0), stride: 1)
        XCTAssertEqual(scopes.red.lastIndex(where: { $0 > 0 }), 255)
        XCTAssertEqual(scopes.green.lastIndex(where: { $0 > 0 }), 0)
        XCTAssertEqual(scopes.blue.lastIndex(where: { $0 > 0 }), 0)
    }

    func testSamplingIsDeterministicAndProportional() throws {
        let image = try solid(0.25, 0.5, 0.75, size: 64)
        let dense = Scopes.measure(image, stride: 1)
        let sparse = Scopes.measure(image, stride: 4)
        XCTAssertEqual(dense.sampleCount, 64 * 64)
        XCTAssertEqual(sparse.sampleCount, 64 * 64 / 4)
        // The shape is what a scope is for, so a sampled read has to agree with a full one.
        XCTAssertEqual(dense.luma.firstIndex(where: { $0 > 0 }),
                       sparse.luma.firstIndex(where: { $0 > 0 }))
    }
}
