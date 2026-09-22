import Foundation

/// Assembles `LiveChain` for a look: the one place its stages are built, so the preview and the
/// native export cannot put them together differently.
///
/// CACHING, NOT THREAD-SAFE. Each built stage is kept with what it was built from, so a drag that
/// moves one control rebuilds one stage: the correction cube alone is 10 ms on the Intel Mac. Use
/// one builder per queue.
public final class ChainBuilder {
    /// The engine's own default (`CORRECT_SIZE` in grade.sh), because the chain has to be built
    /// from the cube the render builds. The error at 17, 33 and 65 is measured in
    /// `make-correct-lut.py`.
    public static let cubeSize = 33

    public enum Refusal: Error, CustomStringConvertible {
        case conversion(String)
        case correction
        case halation

        public var description: String {
            switch self {
            case .conversion(let stem): return "The conversion “\(stem)” couldn’t be read."
            case .correction: return "That correction isn’t a value the engine accepts."
            case .halation: return "That halation tint isn’t a value the engine accepts."
            }
        }
    }

    /// Everything the colour stages depend on, so a caller keeping a converted frame knows when it
    /// can reuse it.
    public struct ColourKey: Equatable {
        let convertCube: String
        let correct: Look.Correct
        let halation: Look.Halation
        let frameLongEdge: Int
        let sourceLongEdge: Int?
    }

    public struct Built {
        public let chain: LiveChain
        public let colourKey: ColourKey
    }

    private let engine: EngineLocation
    /// Conversion cubes, keyed by the resolved file, which is unique across `luts/rendering/` and
    /// `luts/film/` where a stem need not be. Each is 65 points, and parsing one costs more than a
    /// frame does.
    private var conversions: [URL: Cube3D] = [:]
    private var correction: (Look.Correct, Cube3D?)?

    public init(engine: EngineLocation) {
        self.engine = engine
    }

    /// The chain for `requested`, with what the engine metered added to its correction as the
    /// engine adds it. `frameLongEdge` is the frame being graded and `sourceLongEdge` the decoded
    /// clip's, because the look stores the glow's radius as a fraction of the source frame.
    ///
    /// A stage the engine would refuse throws rather than being left out: a picture of something the
    /// render will not produce is worse than none.
    public func build(
        _ requested: Look, metered: PreviewRenderer.Metered?, frameLongEdge: Int,
        sourceLongEdge: Int?
    ) throws -> Built {
        var look = requested
        if let metered { look.correct = metered.applied(to: look.correct) }

        guard let url = engine.conversionCube(named: look.convertCube) else {
            throw Refusal.conversion(look.convertCube)
        }
        let conversion: Cube3D
        if let cached = conversions[url] {
            conversion = cached
        } else {
            guard let read = try? Cube3D(contentsOf: url) else {
                throw Refusal.conversion(look.convertCube)
            }
            conversions[url] = read
            conversion = read
        }

        if correction?.0 != look.correct {
            correction = (
                look.correct,
                look.correct.isNeutral
                    ? nil : CorrectionCube.cube(for: look.correct, size: Self.cubeSize)
            )
        }
        let correctionCube = correction?.1
        if !look.correct.isNeutral && correctionCube == nil { throw Refusal.correction }

        let halation = LiveHalation(
            look.halation, frameLongEdge: frameLongEdge, sourceLongEdge: sourceLongEdge)
        if !look.halation.isNeutral && halation == nil { throw Refusal.halation }

        return Built(
            chain: LiveChain(
                stages: LiveChain.colourStages(
                    correction: correctionCube, halation: halation, conversion: conversion)),
            colourKey: ColourKey(
                convertCube: look.convertCube, correct: look.correct, halation: look.halation,
                frameLongEdge: frameLongEdge, sourceLongEdge: sourceLongEdge))
    }
}
