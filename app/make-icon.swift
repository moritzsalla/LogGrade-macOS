#!/usr/bin/env swift
// Draws the app icon, rather than storing one.
//
// WHY IT IS DRAWN. The curve in the icon is the shipped tone curve, read from the engine's own
// generator with look.json's parameters — the same table the render applies. This project's whole
// claim is that the grade is a measurement kept in one place, and an icon traced by hand would be
// a second copy of it that goes stale the day the look is re-tuned. Re-run this after a re-grade
// and the icon follows.
//
// RUN IT FROM THE REPO ROOT. It reads look.json and scripts/ relative to the working directory,
// and writes dist/AppIcon.icns there.
//
// Usage:  swift app/make-icon.swift            (writes dist/AppIcon.icns)

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let generator = root.appendingPathComponent("scripts/make-tone-lut.py")
let lookFile = root.appendingPathComponent("look.json")

func look(_ key: String) -> String {
    guard let data = try? Data(contentsOf: lookFile),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tone = root["tone"] as? [String: Any],
          let value = tone[key] as? NSNumber else {
        FileHandle.standardError.write(Data("make-icon: look.json has no tone.\(key)\n".utf8))
        exit(1)
    }
    return String(value.doubleValue)
}

let process = Process()
process.executableURL = generator
process.arguments = ["--stdout",
                     "--gamma", look("gamma"), "--pivot", look("pivot"),
                     "--contrast", look("contrast"), "--toe", look("toe"),
                     "--shoulder", look("shoulder"), "--black", look("black")]
let pipe = Pipe()
process.standardOutput = pipe
// The generator announces itself on stderr, which is noise inside a build script.
process.standardError = Pipe()
try process.run()
let table = pipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()

let curve: [Double] = String(decoding: table, as: UTF8.self).split(separator: "\n").compactMap {
    let parts = $0.split(separator: " ")
    guard parts.count == 3 else { return nil }
    return Double(parts[0])
}
guard curve.count > 1 else {
    FileHandle.standardError.write(Data("make-icon: the generator wrote no table\n".utf8))
    exit(1)
}

/// RAL 1021, the plate yellow this pipeline measures against, and the app's one accent.
let plate = CGColor(red: 0.953, green: 0.765, blue: 0, alpha: 1)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("no context at \(size)")
    }
    ctx.setAllowsAntialiasing(true)

    // The plate. macOS icons sit in a margin rather than filling their canvas, so a row of them
    // lines up whatever shape each one is.
    let inset = s * 0.094
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let plateShape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                            transform: nil)
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.114, green: 0.114, blue: 0.114, alpha: 1),
        CGColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    ctx.addPath(plateShape)
    ctx.setStrokeColor(CGColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()

    // The graph, well inside the plate so the curve never touches the corner radius.
    let pad = rect.width * 0.175
    let graph = rect.insetBy(dx: pad, dy: pad)

    // No identity diagonal. It was drawn once, as a reference for the curve to depart from, and
    // the curve covers most of it — so what showed was two fragments poking out at the ends,
    // which reads as a mistake rather than as a reference. One object on the plate.

    // The curve itself, sampled from the engine's table.
    let steps = max(24, size / 2)
    let path = CGMutablePath()
    for i in 0...steps {
        let x = Double(i) / Double(steps)
        let y = curve[min(curve.count - 1, Int(x * Double(curve.count - 1)))]
        let point = CGPoint(x: graph.minX + graph.width * CGFloat(x),
                            y: graph.minY + graph.height * CGFloat(y))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    ctx.addPath(path)
    ctx.setStrokeColor(plate)
    ctx.setLineWidth(max(1.5, s * 0.042))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("no image at \(size)") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("no png at \(size)")
    }
    return png
}

let iconset = URL(fileURLWithPath: "dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2)
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
