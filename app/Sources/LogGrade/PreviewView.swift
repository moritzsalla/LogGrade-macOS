import GradeKit
import SwiftUI

/// The picture, in a recess, with nothing bright next to it.
///
/// The panel always says what it is showing. There are three states and they are not
/// interchangeable: a live approximation while a control is moving, the exact render once it
/// lands, and a stale render when a control the live tier cannot model has moved. An instrument
/// that shows a stale value while the controls have moved on is lying, so the stale one is dimmed
/// and named; the live one is neither, because it does answer the controls.
struct PreviewView: View {
    @ObservedObject var model: GradeModel

    /// Held on the keyboard, not clicked. The window's key monitor sets this.
    private var comparing: Bool { model.isComparing }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Palette.well)
                if let image = comparing ? (model.comparisonImage ?? model.previewImage)
                                          : model.previewImage {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // Dimmed when the picture no longer answers the controls. A live
                            // frame does answer them, so it is not dimmed.
                            .opacity(model.isStale && !model.isLive ? 0.55 : 1)
                        // The crop is judged on the picture, because the question it answers is
                        // what is in the frame and no number answers that.
                        if model.project.delivery.feed, let geometry = model.cropGeometry {
                            CropOverlay(model: model, geometry: geometry)
                                .aspectRatio(image.size.width / image.size.height,
                                             contentMode: .fit)
                        }
                    }
                    .padding(10)
                } else {
                    Text(model.selectedClip == nil
                         ? "drop Apple Log clips here to start"
                         : "press preview for a still from this clip, graded as it will render")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.inkTertiary)
                }
                if model.isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.plate)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                ScopesView(scopes: model.scopes)
                // The curve lives with the picture rather than with its sliders, because the
                // inspector scrolls and a readout you cannot see while you adjust is not a readout.
                VStack(alignment: .leading, spacing: 4) {
                    Text("curve").font(.system(size: 10)).foregroundColor(Palette.inkTertiary)
                    CurveView(curve: model.curve)
                        .frame(width: 78, height: 78)
                }
            }

            HStack(spacing: 12) {
                Button(model.isStale ? "preview (out of date)" : "preview") { model.renderPreview() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.selectedClip == nil || model.isRendering)
                Text("hold C for the picture before this change")
                    .font(.system(size: 11))
                    .foregroundColor(model.comparisonImage == nil ? Palette.inkTertiary
                                                                   : Palette.inkSecondary)
                Spacer()
                if comparing {
                    Readout(text: "before")
                } else if model.isLive {
                    Readout(text: "live")
                } else if model.isStale {
                    Readout(text: "out of date")
                }
            }

            // Said every time, not only on failure: a preview that quietly omits half the chain is
            // output that looks done, which is the failure this whole labelling exists to prevent.
            Text(model.status.isEmpty
                 ? "This is the grade. Grain, sharpening, denoise, the stabiliser and dither are "
                   + "added when you convert."
                 : model.status)
                .font(.system(size: 10.5))
                .foregroundColor(model.statusIsFailure ? Palette.lamp : Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Palette.surround)
    }
}
