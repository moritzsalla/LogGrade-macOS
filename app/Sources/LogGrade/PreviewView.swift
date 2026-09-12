import GradeKit
import SwiftUI

/// The picture, in a recess, with nothing bright next to it.
///
/// The panel says when the reading is out of date. An instrument that shows a stale value while
/// the controls have moved on is lying, and this one renders on release rather than continuously,
/// so the gap is real and worth naming.
struct PreviewView: View {
    @ObservedObject var model: GradeModel
    @State private var comparing = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Palette.well)
                if let image = comparing ? (model.previousImage ?? model.previewImage)
                                          : model.previewImage {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(model.isStale ? 0.55 : 1)
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
                         ? "drop a clip to start"
                         : "press preview to render a still through the real chain")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.inkTertiary)
                }
                if model.isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.plate)
                }
            }

            ScopesView(scopes: model.scopes)

            HStack(spacing: 12) {
                Button(model.isStale ? "preview (out of date)" : "preview") { model.renderPreview() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.selectedClip == nil || model.isRendering)
                Text("hold to compare")
                    .font(.system(size: 11))
                    .foregroundColor(model.previousImage == nil ? Palette.inkTertiary
                                                                : Palette.inkSecondary)
                    .onLongPressGesture(minimumDuration: 0.01,
                                        pressing: { comparing = $0 && model.previousImage != nil },
                                        perform: {})
                Spacer()
                if comparing {
                    Readout(text: "previous")
                } else if model.isStale {
                    Readout(text: "controls moved since this render")
                }
            }

            // Said every time, not only on failure: a preview that quietly omits half the chain is
            // output that looks done, which is the failure this whole labelling exists to prevent.
            Text(model.status.isEmpty
                 ? "grade only. no grain, sharpening, denoise, stabiliser or dither."
                 : model.status)
                .font(.system(size: 10.5))
                .foregroundColor(model.status.hasPrefix("the ") ? Palette.lamp : Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Palette.surround)
    }
}
