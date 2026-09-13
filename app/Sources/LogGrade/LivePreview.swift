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
    /// True when the picture is this app's approximation rather than the engine's render. The
    /// interface says which, always, because they are not the same claim.
    @Published var isLive = false
    /// The last frame the ENGINE produced. Compare reaches for this so that holding a key answers
    /// a question about the grade rather than about the model.
    @Published var lastExact: NSImage?
    /// The render before that one, which is what compare shows once the exact frame IS the picture.
    @Published var previous: NSImage?
    @Published var status = ""
    @Published var statusIsFailure = false
    @Published var isRendering = false

    /// What holding the compare key shows: the picture as it was before the adjustment in
    /// progress. Mid-drag that is the render the drag started from; once the render lands, that
    /// frame is the picture, so the comparison moves back one.
    var comparison: NSImage? { isLive ? lastExact : previous }

    func say(_ text: String, failure: Bool = false) {
        status = text
        statusIsFailure = failure
    }
}
