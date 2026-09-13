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
    /// Observed separately, so a new frame redraws the picture and nothing else.
    @ObservedObject var preview: LivePreview

    /// Held on the keyboard, not clicked. The window's key monitor sets this.
    private var comparing: Bool { model.isComparing }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Palette.well)
                if let image = comparing ? (preview.comparison ?? preview.image)
                                          : preview.image {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // Dimmed when the picture no longer answers the controls. A live
                            // frame does answer them, so it is not dimmed.
                            .opacity(model.isStale && !preview.isLive ? 0.55 : 1)
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
                         ? "Drop Apple Log clips here to start"
                         : "Rendering the first frame of this clip…")
                        .font(Type.label)
                        .foregroundColor(Palette.inkTertiary)
                }
                // NO SPINNER OVER THE WELL. It used to be an unaligned child of this stack, so it
                // centred itself — on top of the picture when there was one, and squarely on top
                // of the placeholder text when there was not. The status line below already says
                // what is happening in words, so the spinner belongs in front of that, which is
                // also where every native app puts one.
            }

            HStack(alignment: .top, spacing: 10) {
                ScopesView(scopes: preview.scopes)
                // The curve lives with the picture rather than with its sliders, because the
                // inspector scrolls and a readout you cannot see while you adjust is not a readout.
                VStack(alignment: .leading, spacing: 4) {
                    Text("curve").font(Type.caption).foregroundColor(Palette.inkTertiary)
                    CurveView(curve: model.curve)
                        .frame(width: 78, height: 78)
                }
            }

            HStack(spacing: 12) {
                // NO PREVIEW BUTTON. It had one job — ask for the exact frame — and every path
                // that changes the look now does that on its own: live while you move a control,
                // and an engine render the moment you let go. A button that re-does what just
                // happened is a button that teaches you to distrust the picture.
                Text("hold C for the picture before this change")
                    .font(Type.label)
                    .foregroundColor(preview.comparison == nil ? Palette.inkTertiary
                                                                   : Palette.inkSecondary)
                Spacer()
                if comparing {
                    Readout(text: "before")
                } else if preview.isLive {
                    Readout(text: "live")
                } else if model.isStale {
                    Readout(text: "out of date")
                }
            }

            // Said every time, not only on failure: a preview that quietly omits half the chain is
            // output that looks done, which is the failure this whole labelling exists to prevent.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if preview.isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 11, height: 11)
                        .tint(Palette.inkTertiary)
                }
                Text(preview.status.isEmpty
                     ? "This is the grade. Grain, sharpening, denoise, the stabiliser and dither "
                       + "are added when you convert."
                     : preview.status)
                    .font(Type.caption)
                    .foregroundColor(preview.statusIsFailure ? Palette.lamp : Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Palette.surround)
    }
}
