import AppKit
import Combine
import GradeKit

/// The picture and what was measured from it, kept apart from everything else the app holds.
///
/// WHY ITS OWN OBSERVABLE. SwiftUI invalidates every view observing an object when any one of its
/// published properties changes, so while the whole model was one object a new preview frame
/// rebuilt the inspector — thirty-four controls, each with a text field — sixty times a second
/// during a drag. The pixels were never the problem: grading a frame costs about 4ms and the
/// rebuild around it cost more. Only the views that show the picture observe this.
final class LivePreview: ObservableObject {
    @Published var image: NSImage?
    @Published var scopes: Scopes?
    /// True when the picture is not of the look and clip now selected: the frame or meter reading
    /// it needs is still coming, or the grade was refused. Said beside the picture.
    @Published var isOutOfDate = false
    /// What holding C shows: this clip in the look as it ships, with no Adjust and the stages at
    /// their defaults. ALWAYS THAT, never the step before the last change: the question a person
    /// asks with it is "what have my adjustments done", which the previous step cannot answer.
    @Published var baseline: NSImage?
    @Published var status = ""
    @Published var statusIsFailure = false
    @Published var isRendering = false

    func say(_ text: String, failure: Bool = false) {
        status = text
        statusIsFailure = failure
    }
}
