//
// WHAT IT SHOWS. A vertical strip of the picture before the grade beside the same strip after it:
// flat, desaturated log on the left and the graded result on the right. That is the whole job of
// this app in one image, and it is legible at sixteen points because the two halves differ in
// value, not only in hue.
//
// The colours are not chosen. Both strips are produced by ffmpeg from one synthetic ramp — the
// right one through the grade as lib.sh's `grade_chain` builds it for a render: Apple's
// conversion, the film look and print at their strengths, the shipped tone curve, saturation and
// warmth. So the icon is an output of the pipeline rather than an illustration of it, and
// re-running this after a re-grade changes it.
//
// WHAT IT LEAVES OUT, and why that is not a shortcut. The input correction and halation run before
// the conversion and are not part of `grade_chain`: the correction needs a cube generated from
// look.json, and halation is a spatial glow around bright areas, which has no meaning on an
// eight-pixel strip. The delivery stage — grain, sharpening, dither — is left out for the same
// reason. A look that turns either pre-conversion stage on is therefore drawn without it.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// A vertical sweep of colour, written as a 16-bit PNG for ffmpeg to grade.
///
/// COLOUR, NOT GREY. A neutral ramp was tried first and came out of the chain almost unchanged —
/// Apple's conversion is colorimetrically accurate and the film cube barely moves neutrals, so the
/// icon was two grey bars. What this look actually does lives in the saturated colours, which is
/// also what the whole calibration is built around. So the sweep runs through hue while it runs
/// through luminance, and the icon shows the palette the look produces.
func sweep(height: Int) -> URL {
    let width = 8
    var px = [UInt16](repeating: 65535, count: width * height * 4)
    for y in 0..<height {
        let t = Double(y) / Double(height - 1)
        // Top bright, because the strip is painted downward. Hue walks from a cool shadow through
        // warm midtones to a near-neutral highlight, which is the axis a graded frame lives on.
        // Held deliberately low. The shipped look adds saturation on top of whatever it is given,
        // so a sweep that looks right going in comes out as neon: the first attempt produced a
        // fire-orange right-hand side rather than a film one.
        let colour = NSColor(
            hue: 0.085 - 0.02 * CGFloat(t),
            saturation: CGFloat(0.10 + 0.22 * t),
            brightness: CGFloat(1 - 0.94 * t), alpha: 1
        )
        .usingColorSpace(.deviceRGB)!
        let r = UInt16(colour.redComponent * 65535)
        let g = UInt16(colour.greenComponent * 65535)
        let b = UInt16(colour.blueComponent * 65535)
        for x in 0..<width {
            let i = (y * width + x) * 4
            px[i] = r
            px[i + 1] = g
            px[i + 2] = b
        }
    }
    let wide = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue)
    let ctx = CGContext(
        data: &px, width: width, height: height, bitsPerComponent: 16,
        bytesPerRow: width * 8, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: wide.rawValue)!
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(UUID().uuidString).png")
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!)
        .representation(using: .png, properties: [:])!.write(to: url)
    return url
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

/// The grade's filter graph, as the engine builds it.
///
/// ASKED OF lib.sh, NOT WRITTEN HERE. This file used to assemble its own graph — one named look,
/// the tone cube, nothing else — so the icon silently stopped being the grade the moment the look
/// gained a print stage, a strength, saturation or warmth, while this header went on saying it was
/// the real chain. `grade_chain` is the builder every render uses, so the icon follows a re-grade
/// without anyone remembering it exists.
///
/// The look, print and strengths are deliberately NOT put in the environment: `grade_chain`
/// treats an unset variable as "ask look.json" and a set one as a choice, and look.json is the
/// answer wanted here.
func gradedChain(cst: String) -> String {
    // The look values are ASSIGNED before the call, not substituted into its arguments: errexit
    // does not see a substitution that fails inside an argument list, so a look.json missing
    // `colour` built a graph with an empty saturation and exited 0.
    let script = #"""
        source "$1/scripts/lib.sh"
        ensure_tone_lut "$1" >/dev/null
        sat="$(look .colour.saturation)"
        warm="$(look .colour.warmth)"
        grade_chain "$1/luts/tone/shipped.cube" "$sat" "$warm" \
            "format=gbrp16le,lut3d=file='$2':interp=tetrahedral,"
        """#
    let bash = Process()
    bash.executableURL = URL(fileURLWithPath: "/bin/bash")
    bash.arguments = ["-c", script, "make-icon", root.path, cst]
    let out = Pipe()
    let err = Pipe()
    bash.standardOutput = out
    bash.standardError = err
    do { try bash.run() } catch { fail("could not run bash: \(error)") }
    let chain = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let complaint = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    bash.waitUntilExit()
    let trimmed = chain.trimmingCharacters(in: .whitespacesAndNewlines)
    guard bash.terminationStatus == 0, !trimmed.isEmpty else {
        fail("lib.sh could not build the grade: \(complaint)")
    }
    return trimmed
}

/// The ramp, optionally through the grade.
func strip(graded: Bool, height: Int) -> [(CGFloat, CGFloat, CGFloat)] {
    let source = sweep(height: height)
    defer { try? FileManager.default.removeItem(at: source) }
    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: out) }

    // Labels, because grade_chain splits and merges planes; -vf cannot carry a labelled graph.
    var graph = "[0:v]format=gbrp16le[o]"
    if graded {
        // REFUSED RATHER THAN SKIPPED. Leaving the conversion out used to be silent, which drew
        // the log ramp beside a tone-curved log ramp and called that the grade. The cube is not
        // in git (Apple's licence), so a fresh clone reaches this.
        let cst = root.appendingPathComponent("luts/rendering/neutral.cube").path
        guard FileManager.default.fileExists(atPath: cst) else {
            fail("the rendering cube is missing (\(cst))")
        }
        graph = "[0:v]\(gradedChain(cst: cst))[o]"
    }

    // ~/.local/bin FIRST, which is the order GradeKit's own tool lookup uses and for the same
    // reason: this machine has a broken Homebrew ffmpeg at /usr/local/bin that starts and then
    // dies on a missing dylib. Searching in the obvious order finds it and nothing else.
    // A copy of `EngineLocation.toolSearchPaths`, because this is run as a standalone script and
    // cannot import GradeKit; change the two together.
    let ffmpeg = [
        "\(NSHomeDirectory())/.local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let ffmpeg else { return [] }
    let run = Process()
    run.executableURL = URL(fileURLWithPath: ffmpeg)
    run.arguments = [
        "-v", "error", "-y", "-i", source.path, "-filter_complex", graph,
        "-map", "[o]", "-frames:v", "1", "-pix_fmt", "rgb48be", out.path,
    ]
    let err = Pipe()
    run.standardError = err
    guard (try? run.run()) != nil else { return [] }
    let complaint = err.fileHandleForReading.readDataToEndOfFile()
    run.waitUntilExit()
    if run.terminationStatus != 0 {
        let text = "make-icon: ffmpeg said: " + String(decoding: complaint, as: UTF8.self) + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
    guard run.terminationStatus == 0,
        let image = NSImage(contentsOf: out)?.cgImage(
            forProposedRect: nil, context: nil,
            hints: nil)
    else { return [] }
    var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(
        data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (0..<image.height).map { y in
        let i = (y * image.width + image.width / 2) * 4
        return (CGFloat(px[i]) / 255, CGFloat(px[i + 1]) / 255, CGFloat(px[i + 2]) / 255)
    }
}

func draw(
    size: Int, flat: [(CGFloat, CGFloat, CGFloat)],
    graded: [(CGFloat, CGFloat, CGFloat)]
) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        fatalError("no context at \(size)")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The macOS app shape: a continuous-curvature rounded square inset from the canvas, which is
    // what makes a row of icons line up whatever is inside them.
    let inset = s * 0.094
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    ctx.saveGState()
    ctx.addPath(
        CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
            transform: nil))
    ctx.clip()

    // ONE FIELD, NOT TWO PANELS. Down the icon it runs from light to black, which is the tone
    // curve; across it, it runs from the flat log colour to the graded one, so the same row is the
    // same brightness on both sides and only its colour changes. There is no divider: the point is
    // that grading is a continuous move, and a line down the middle made it look like a comparison
    // slider instead.
    if !flat.isEmpty, !graded.isEmpty {
        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
        var px = [UInt8](repeating: 255, count: max(1, w * h * 4))
        for y in 0..<h {
            let row = min(flat.count - 1, y * flat.count / max(1, h))
            let a = flat[row]
            let b = graded[min(graded.count - 1, row)]
            for x in 0..<w {
                let t = CGFloat(x) / CGFloat(max(1, w - 1))
                let i = (y * w + x) * 4
                px[i] = UInt8(max(0, min(255, (a.0 + (b.0 - a.0) * t) * 255)))
                px[i + 1] = UInt8(max(0, min(255, (a.1 + (b.1 - a.1) * t) * 255)))
                px[i + 2] = UInt8(max(0, min(255, (a.2 + (b.2 - a.2) * t) * 255)))
            }
        }
        if let field = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .makeImage()
        {
            ctx.interpolationQuality = .high
            ctx.draw(field, in: rect)
        }
    }
    ctx.restoreGState()

    // A hairline, so the shape still reads against a white background.
    ctx.addPath(
        CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
            transform: nil))
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.14))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("no image at \(size)") }
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("no png at \(size)") }
    return png
}

let flat = strip(graded: false, height: 96)
let graded = strip(graded: true, height: 96)
guard !flat.isEmpty, !graded.isEmpty else {
    FileHandle.standardError.write(Data("make-icon: could not render the ramps\n".utf8))
    exit(1)
}

let iconset = URL(fileURLWithPath: "dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base, flat: flat, graded: graded).write(
        to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2, flat: flat, graded: graded)
        .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "dist/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("make-icon: iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("wrote dist/AppIcon.icns")
