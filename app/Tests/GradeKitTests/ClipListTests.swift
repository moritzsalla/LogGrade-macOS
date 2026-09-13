import XCTest
@testable import GradeKit

final class ClipListTests: XCTestCase {
    private func probe() -> ClipProbe? {
        EngineLocation.resolveTool("ffprobe").map(ClipProbe.init)
    }

    func testKeepsARefusedClipWithItsReason() throws {
        // A file that silently disappears when you drop it reads as a broken interface, and the
        // reason is the thing the person needs in order to act.
        let list = ClipList(probe: probe())
        let notAClip = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: notAClip)
        defer { try? FileManager.default.removeItem(at: notAClip) }

        list.add([notAClip])
        XCTAssertEqual(list.entries.count, 1, "it stays in the list")
        XCTAssertFalse(list.entries[0].isUsable)
        XCTAssertTrue(list.usable.isEmpty)
        XCTAssertFalse(list.entries[0].verdict.description.isEmpty, "and it carries a reason")
    }

    func testTheStemIsTheKey() throws {
        let list = ClipList(probe: nil)
        let url = URL(fileURLWithPath: "/tmp/IMG_0609.mov")
        list.add([url])
        XCTAssertEqual(list.entries.map(\.stem), ["IMG_0609"],
                       "the stem is the join key back to the footage and the project file")
        // Adding the same file twice is not two clips.
        list.add([url])
        XCTAssertEqual(list.entries.count, 1)
        list.remove("IMG_0609")
        XCTAssertTrue(list.entries.isEmpty)
    }

    func testWithoutFfprobeItSaysSoRatherThanGuessing() {
        let list = ClipList(probe: nil)
        list.add([URL(fileURLWithPath: "/tmp/IMG_0001.mov")])
        guard case .unreadable(let why) = list.entries[0].verdict else {
            return XCTFail("no measurement is not the same as a passing measurement")
        }
        XCTAssertTrue(why.contains("ffprobe"), "should name what is missing: \(why)")
    }

    func testRealFootageIsUsableAndGetsAThumbnail() throws {
        let here = URL(fileURLWithPath: #filePath)
        guard let engine = EngineLocation.discover(from: here.deletingLastPathComponent()) else {
            throw XCTSkip("no engine checkout")
        }
        let clips = (try? FileManager.default.contentsOfDirectory(
            at: engine.root.appendingPathComponent("src"), includingPropertiesForKeys: nil)) ?? []
        guard let clip = clips.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            throw XCTSkip("no footage in src/")
        }
        guard let p = probe() else { throw XCTSkip("no ffprobe") }
        let list = ClipList(probe: p)
        list.add([clip])
        XCTAssertTrue(list.entries[0].isUsable, "got \(list.entries[0].verdict)")

        // ADDING IS WHAT ASKS FOR IT. This used to call loadThumbnail directly, which tested the
        // generator and not the contract — so when a fourth place to add clips forgot to make that
        // second call, every clip imported through it showed a black rectangle and the suite
        // stayed green.
        let loaded = expectation(description: "thumbnail")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { loaded.fulfill() }
        wait(for: [loaded], timeout: 10)
        let image = list.entries[0].thumbnail
        XCTAssertNotNil(image, "no frame came back")
        if let image {
            // appliesPreferredTrackTransform honours the display matrix, so the thumbnail is
            // vertical even though the container's dimensions are not.
            XCTAssertGreaterThan(image.height, image.width,
                                 "the thumbnail should be the right way up")
        }
    }
}
