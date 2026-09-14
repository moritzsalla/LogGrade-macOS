import XCTest
@testable import GradeKit

/// The shape editor asks the engine whether a shape can be rendered, and decides only what the
/// engine cannot know: how this shape sits among the others the project holds.
///
/// Every test here runs the real `lib.sh`. A stub resolver would test that Swift agrees with a
/// stub, which is the untied copy this replaced.
final class ShapeEditingTests: XCTestCase {
    private func draft(_ name: String, _ w: String, _ h: String,
                       centre: Bool = false) -> ShapeDraft {
        ShapeDraft(name: name, aspectWidth: w, aspectHeight: h, centre: centre)
    }

    /// What the engine itself says to a name and spec, called as a shell caller would call it.
    private func engineVerdict(_ engine: EngineLocation, _ d: ShapeDraft) throws -> String? {
        let name = try libSh(engine, "require_clip_name", [d.name])
        if name.status != 0 { return name.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        let spec = try libSh(engine, "deliverable_spec", [d.spec])
        if spec.status != 0 { return spec.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    /// The editor and the engine agree on every input, and a refusal is the engine's text.
    ///
    /// The set is the one a hand-copied rule gets wrong: whitespace, which the first copy let
    /// through and the engine then misparsed; characters the engine accepts that look risky (`-x`,
    /// `..`, unicode, a long name); and a shape taller than the master, which is NOT the editor's
    /// to refuse — whether a window fits is a fact about each clip, decided by `crop_prefix`.
    func testTheEditorAndTheEngineAgreeOnEveryInput() throws {
        let engine = try engineCheckout()
        let inputs = [
            draft("square", "1", "1"), draft("a b", "1", "1"), draft("tab\tbed", "1", "1"),
            draft("é", "1", "1"), draft("-x", "1", "1"), draft("..", "1", "1"),
            draft(String(repeating: "n", count: 200), "1", "1"), draft("", "1", "1"),
            draft("a/b", "1", "1"), draft("q'x", "1", "1"), draft("a,b", "1", "1"),
            draft("a:b", "1", "1"), draft("x", "0", "1"), draft("x", "1", "0"),
            draft("x", "-1", "1"), draft("x", "1.5", "1"), draft("x", "", "1"),
            draft("x", "9", "32"), draft("x", "4", "5", centre: true),
        ]
        for input in inputs {
            let label = "'\(input.spec)'"
            var delivery = Project.Delivery(targets: [.reels])
            let refusal = delivery.save(input, replacing: nil,
                                        resolve: engine.resolveDeliverable)
            if let said = try engineVerdict(engine, input) {
                XCTAssertEqual(refusal, .engine(said),
                               "\(label): not refused in the engine's words")
                XCTAssertEqual(delivery.targets, [.reels], "\(label): a refusal changed the set")
            } else {
                XCTAssertNil(refusal, "\(label): the engine accepts it and the editor did not")
                XCTAssertEqual(delivery.targets.count, 2, "\(label): accepted but not added")
            }
        }
    }

    /// The table above proves agreement; this proves the guards it agrees with are the ones meant,
    /// by their own words, so a refusal for some other reason cannot pass as the right one.
    func testEachRefusalIsTheEnginesOwnReason() throws {
        let engine = try engineCheckout()
        let expected: [(ShapeDraft, String)] = [
            (draft("a b", "1", "1"), "deliverable name 'a b' contains whitespace"),
            (draft("a/b", "1", "1"), "clip name 'a/b' contains '/'"),
            (draft("a:b", "1", "1"), "contains a character ffmpeg reads as filter syntax"),
            (draft("", "1", "1"), "empty clip name"),
            (draft("x", "0", "1"), "deliverable 'x' has a zero aspect term"),
            (draft("x", "-1", "1"), "deliverable 'x' has a non-integer aspect '-1:1'"),
        ]
        for (input, words) in expected {
            var delivery = Project.Delivery()
            let refusal = delivery.save(input, replacing: nil, resolve: engine.resolveDeliverable)
            XCTAssertTrue(refusal?.description.contains(words) ?? false,
                          "'\(input.spec)': expected \"\(words)\", "
                            + "got \(String(describing: refusal))")
        }
    }

    /// A custom `feed` is not the preset — it compares unequal and writes another file — and
    /// would still be listed as if it were. Refused whether or not the preset is ticked, and
    /// ignoring case, because `Reels_9x16.mp4` and `reels_9x16.mp4` are one file on this disk.
    func testAPresetsNameIsRefusedWhetherOrNotItIsTicked() throws {
        let engine = try engineCheckout()
        for (input, preset) in [(draft("feed", "4", "5"), "feed"),
                                (draft("Reels", "9", "16"), "reels"),
                                (draft("feed", "1", "1", centre: true), "feed")] {
            var delivery = Project.Delivery(targets: [.reels])
            let refusal = delivery.save(input, replacing: nil, resolve: engine.resolveDeliverable)
            XCTAssertEqual(refusal, .presetName(preset), "'\(input.spec)' was not refused")
            XCTAssertTrue(refusal?.description.contains("is a preset's name") ?? false)
            XCTAssertEqual(delivery.targets, [.reels])
        }
    }

    /// A different name can still write a preset's file, and only the engine knows the suffix.
    func testAShapeThatWouldWriteAPresetsFileIsRefused() throws {
        let engine = try engineCheckout()
        var delivery = Project.Delivery(targets: [])
        let refusal = delivery.save(draft("reels-stories", "9", "16"), replacing: nil,
                                    resolve: engine.resolveDeliverable)
        XCTAssertEqual(refusal, .sameOutputFile(other: "reels", suffix: "reels-stories_9x16"))
        XCTAssertTrue(refusal?.description.contains("which 'reels' already writes") ?? false)
        XCTAssertEqual(delivery.targets, [])
    }

    func testANameAlreadyInTheProjectIsRefusedIgnoringCase() throws {
        let engine = try engineCheckout()
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        var delivery = Project.Delivery(targets: [.reels, square])
        let refusal = delivery.save(draft("Square", "4", "5"), replacing: nil,
                                    resolve: engine.resolveDeliverable)
        XCTAssertEqual(refusal, .duplicateName("square"))
        XCTAssertTrue(refusal?.description.contains("A shape named 'square' already exists")
                      ?? false)
        XCTAssertEqual(delivery.targets, [.reels, square])
    }

    /// Accepted by the engine and still not storable as typed: a second `:` in a box turns the
    /// rest into an offset, a 20-digit term errors its way past `-le 0`, and a leading zero would
    /// be saved as a different spec from the one checked.
    func testATermTheEngineReadsDifferentlyFromWhatWasTypedIsRefused() throws {
        let engine = try engineCheckout()
        for term in ["1:1", "99999999999999999999", "007"] {
            var delivery = Project.Delivery(targets: [])
            let refusal = delivery.save(draft("x", term, "1"), replacing: nil,
                                        resolve: engine.resolveDeliverable)
            XCTAssertEqual(refusal, .notAsWritten(term), "'\(term)' was stored as something else")
            XCTAssertEqual(delivery.targets, [])
        }
    }

    // MARK: - Adding and editing

    /// An edit replaces the shape it was opened on, where it was, and may keep its own name.
    func testAnEditReplacesItsShapeInPlaceAndMayKeepItsName() throws {
        let engine = try engineCheckout()
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        let tall = Deliverable(name: "tall", aspectWidth: 2, aspectHeight: 3)
        var delivery = Project.Delivery(targets: [.reels, square, tall])
        let mode = ShapeEditorMode.editing(square)
        XCTAssertEqual(mode.draft, draft("square", "1", "1"), "the edit did not open on its shape")
        let refusal = delivery.save(draft("square", "4", "5", centre: true),
                                    replacing: mode.original, resolve: engine.resolveDeliverable)
        XCTAssertNil(refusal, "an edit was refused as a duplicate of itself")
        XCTAssertEqual(delivery.targets,
                       [.reels, Deliverable(name: "square", aspectWidth: 4, aspectHeight: 5,
                                            cropOffset: .centre), tall])
    }

    /// THE BUG THIS EDITOR SHIPPED WITH. Add after Edit opened pre-filled as that edit, and Save
    /// replaced the shape. What the sheet opens on is now the mode itself, so this is what the
    /// panel does: open an edit, then open Add, and save.
    func testAddAfterAnEditOpensEmptyAndAdds() throws {
        let engine = try engineCheckout()
        let square = Deliverable(name: "square", aspectWidth: 1, aspectHeight: 1)
        var delivery = Project.Delivery(targets: [square])
        var open = ShapeEditorMode.editing(square)
        XCTAssertNil(delivery.save(draft("square", "1", "1", centre: true),
                                   replacing: open.original, resolve: engine.resolveDeliverable))
        open = .adding
        XCTAssertEqual(open.draft, ShapeDraft(), "Add opened with a previous shape in it")
        XCTAssertNil(delivery.save(draft("tall", "2", "3"), replacing: open.original,
                                   resolve: engine.resolveDeliverable))
        XCTAssertEqual(delivery.targets.map(\.name), ["square", "tall"],
                       "Add replaced a shape instead of adding one")
    }
}
