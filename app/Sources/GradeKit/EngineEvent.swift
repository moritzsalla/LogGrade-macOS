import Foundation

/// One line of the engine's event stream.
///
/// DELIBERATELY NOT AN ENUM OF KNOWN EVENTS. The engine is a shell script that grows, and an app
/// that crashes or silently drops an event it has not been taught about is worse than one that
/// shows it. So the name is a string, the fields are decoded as they arrive, and the accessors
/// below are conveniences over that — a new event type reaches the UI as an unknown rather than as
/// nothing at all.
public struct EngineEvent: Equatable {
    public let name: String
    public let fields: [String: Value]

    /// The JSON value kinds the engine emits: it writes bare numbers and quoted strings, nothing
    /// nested. Anything else is kept as `.other` rather than rejected.
    public enum Value: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case other

        public var stringValue: String? {
            switch self {
            case .string(let s): return s
            case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
            case .bool(let b): return String(b)
            case .other: return nil
            }
        }
        public var intValue: Int? {
            switch self {
            case .number(let d): return Int(d)
            case .string(let s): return Int(s)
            default: return nil
            }
        }
        public var doubleValue: Double? {
            switch self {
            case .number(let d): return d
            case .string(let s): return Double(s)
            default: return nil
            }
        }
    }

    public init(name: String, fields: [String: Value]) {
        self.name = name
        self.fields = fields
    }

    public func string(_ key: String) -> String? { fields[key]?.stringValue }
    public func int(_ key: String) -> Int? { fields[key]?.intValue }
    public func double(_ key: String) -> Double? { fields[key]?.doubleValue }

    public var clip: String? { string("clip") }
    public var path: String? { string("path") }

    /// Decodes one line. Returns nil for a blank line and throws for anything that is not a JSON
    /// object with an `event` name — a malformed line is surfaced, never swallowed.
    public static func decode(line: String) throws -> EngineEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeFailure.notJSON(line: trimmed)
        }
        guard let name = object["event"] as? String else {
            throw DecodeFailure.noEventName(line: trimmed)
        }
        var fields: [String: Value] = [:]
        for (key, raw) in object where key != "event" {
            switch raw {
            case let s as String:
                fields[key] = .string(s)
            case let n as NSNumber:
                // NSNumber BEFORE Bool, and the type checked explicitly. Foundation bridges a JSON
                // 0 or 1 to Bool happily, so `case let b as Bool` first turned every count in the
                // stream — rendered, skipped, failed, matched, dry — into a boolean, and every
                // `int(...)` on them returned nil. Caught by the recorded-stream test, which is
                // what a fixture is for.
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    fields[key] = .bool(n.boolValue)
                } else {
                    fields[key] = .number(n.doubleValue)
                }
            default:
                fields[key] = .other
            }
        }
        return EngineEvent(name: name, fields: fields)
    }

    public enum DecodeFailure: Error, Equatable, CustomStringConvertible {
        case notJSON(line: String)
        case noEventName(line: String)

        public var description: String {
            switch self {
            case .notJSON(let l): return "not JSON: \(l)"
            case .noEventName(let l): return "no event name: \(l)"
            }
        }
    }
}

/// The engine's named refusals and degraded states, from stderr.
///
/// Named rather than matched out of message text, because a message is prose and gets reworded —
/// which already broke a test in the precursor silently. `unknown` carries the raw name so a code
/// added to the engine shows up in the interface instead of vanishing.
public enum EngineCode: Equatable {
    case notPortrait
    case feedWithoutCropOffset
    case notFound
    case noArguments
    case proofAndFrameTogether
    case unknownFrameStage
    case fpsWouldNeedRetiming
    case staleTransform
    case noTransform
    case renderFailed
    case frameFailed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "REFUSE_NOT_PORTRAIT": self = .notPortrait
        case "REFUSE_FEED_NO_CROP_Y": self = .feedWithoutCropOffset
        case "REFUSE_NOT_FOUND": self = .notFound
        case "REFUSE_NO_ARGS": self = .noArguments
        case "REFUSE_PROOF_AND_FRAME": self = .proofAndFrameTogether
        case "REFUSE_FRAME_STAGE": self = .unknownFrameStage
        case "REFUSE_FPS_RETIME": self = .fpsWouldNeedRetiming
        case "STALE_TRANSFORM": self = .staleTransform
        case "NO_TRANSFORM": self = .noTransform
        case "RENDER_FAILED": self = .renderFailed
        case "FRAME_FAILED": self = .frameFailed
        default: self = .unknown(rawValue)
        }
    }

    /// A sentence for the interface, which cites the file carrying the reason rather than
    /// restating it. Prose that explains WHY is a copy, and a copy drifts.
    public var message: String {
        switch self {
        case .notPortrait:
            return "not portrait — see docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md"
        case .feedWithoutCropOffset:
            return "the 4:5 crop offset is a per-clip framing call — pick one per clip"
        case .notFound: return "that file is not there"
        case .noArguments: return "no clips given"
        case .proofAndFrameTogether:
            return "a preview and a proof answer different questions — pick one"
        case .unknownFrameStage:
            return "a preview frame is either graded or source, nothing in between"
        case .fpsWouldNeedRetiming:
            return "that frame rate needs retiming, which judders — see scripts/lib.sh"
        case .staleTransform:
            return "the stabilisation transform is older than its source"
        case .noTransform: return "no stabilisation transform, rendering unstabilised"
        case .renderFailed: return "the render failed; the previous output was left alone"
        case .frameFailed: return "the preview frame failed"
        case .unknown(let raw): return raw
        }
    }
}
