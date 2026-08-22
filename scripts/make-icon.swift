#!/usr/bin/env swift

// Renders Sources/OpenLens/AppIcon.icns. Run it after changing anything here:
//
//     swift scripts/make-icon.swift
//
// The icon is drawn rather than hand-painted so it stays reviewable in a diff
// and can be re-rendered at any size. Every size is drawn from scratch at its
// own resolution instead of being downsampled from 1024, which is what keeps
// the 16 pt version from turning to mush.
//
// It deliberately produces a plain `.icns` rather than an asset catalog.
// `actool` always writes `CFBundleIconName` into the Info.plist, and on
// macOS 26 that key sends the system down its new icon path, where a legacy
// `AppIcon.appiconset` is replaced by Apple's grey "icon design template"
// placeholder — the app ends up with no icon at all. `CFBundleIconFile`
// pointing at an `.icns` renders correctly on 14 through 26.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// Apple's icon grid: on a 1024 canvas the body is 824 wide, centred.
private let canvas: CGFloat = 1024
private let bodyInset: CGFloat = 100

/// macOS icon corners are a superellipse, not a rounded rectangle. The
/// difference is small but it is the difference between "native" and "someone
/// drew this in a hurry".
private func squircle(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 512
    let power = 2 / exponent

    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = centre.x + a * CGFloat(copysign(pow(abs(cosT), power), cosT))
        let y = centre.y + b * CGFloat(copysign(pow(abs(sinT), power), sinT))
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

// MARK: - Colours

private func grey(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: value, green: value, blue: value, alpha: alpha)
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

private let accent = rgb(0.21, 0.77, 0.93)

private func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: locations
    )
}

// MARK: - Drawing

private func drawIcon(in context: CGContext, side: CGFloat) {
    // Everything below is written against the 1024 grid and scaled once, so the
    // proportions are identical at every size.
    context.scaleBy(x: side / canvas, y: side / canvas)
    context.setShouldAntialias(true)

    let bodyRect = CGRect(
        x: bodyInset,
        y: bodyInset,
        width: canvas - bodyInset * 2,
        height: canvas - bodyInset * 2
    )
    let body = squircle(in: bodyRect)

    // Body: graphite, lit from above, matching the placeholder card the
    // extension publishes when the app is not running.
    context.saveGState()
    context.addPath(body)
    context.clip()
    if let fill = gradient(
        [rgb(0.33, 0.36, 0.43), rgb(0.16, 0.17, 0.21), rgb(0.07, 0.08, 0.10)],
        [0, 0.55, 1]
    ) {
        context.drawLinearGradient(
            fill,
            start: CGPoint(x: 0, y: bodyRect.maxY),
            end: CGPoint(x: 0, y: bodyRect.minY),
            options: []
        )
    }
    // A hairline of light along the inside of the top edge. Clipped to the body,
    // so only the inner half of the stroke survives.
    context.addPath(body)
    context.setStrokeColor(grey(1, 0.16))
    context.setLineWidth(8)
    context.strokePath()
    context.restoreGState()

    let centre = CGPoint(x: canvas / 2, y: canvas / 2)

    // Framing brackets. This is the part that says "OpenLens" rather than
    // "a camera": the whole app is about choosing a crop.
    let bracketBox = CGRect(x: 196, y: 196, width: 632, height: 632)
    let arm: CGFloat = 150
    let thickness: CGFloat = 54
    context.saveGState()
    context.setStrokeColor(grey(1, 0.92))
    context.setLineWidth(thickness)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for corner in [
        (CGPoint(x: bracketBox.minX, y: bracketBox.minY), CGFloat(1), CGFloat(1)),
        (CGPoint(x: bracketBox.maxX, y: bracketBox.minY), CGFloat(-1), CGFloat(1)),
        (CGPoint(x: bracketBox.minX, y: bracketBox.maxY), CGFloat(1), CGFloat(-1)),
        (CGPoint(x: bracketBox.maxX, y: bracketBox.maxY), CGFloat(-1), CGFloat(-1))
    ] {
        let (point, dx, dy) = corner
        context.move(to: CGPoint(x: point.x + dx * arm, y: point.y))
        context.addLine(to: point)
        context.addLine(to: CGPoint(x: point.x, y: point.y + dy * arm))
        context.strokePath()
    }
    context.restoreGState()

    // Lens barrel.
    let barrel: CGFloat = 246
    context.saveGState()
    context.addEllipse(in: CGRect(
        x: centre.x - barrel, y: centre.y - barrel, width: barrel * 2, height: barrel * 2
    ))
    context.clip()
    if let fill = gradient([rgb(0.16, 0.18, 0.22), rgb(0.05, 0.06, 0.07)], [0, 1]) {
        context.drawLinearGradient(
            fill,
            start: CGPoint(x: 0, y: centre.y + barrel),
            end: CGPoint(x: 0, y: centre.y - barrel),
            options: []
        )
    }
    context.restoreGState()

    // Glass, and the accent ring that gives the icon its one colour.
    let glass: CGFloat = 178
    context.saveGState()
    context.addEllipse(in: CGRect(
        x: centre.x - glass, y: centre.y - glass, width: glass * 2, height: glass * 2
    ))
    context.clip()
    if let fill = gradient(
        [rgb(0.10, 0.33, 0.44), rgb(0.03, 0.09, 0.14), rgb(0.01, 0.03, 0.05)],
        [0, 0.6, 1]
    ) {
        context.drawRadialGradient(
            fill,
            startCenter: CGPoint(x: centre.x - glass * 0.35, y: centre.y + glass * 0.35),
            startRadius: 0,
            endCenter: centre,
            endRadius: glass * 1.35,
            options: []
        )
    }
    context.restoreGState()

    context.setStrokeColor(accent)
    context.setLineWidth(30)
    context.strokeEllipse(in: CGRect(
        x: centre.x - glass, y: centre.y - glass, width: glass * 2, height: glass * 2
    ))

    // Pupil. Small and very dark: it is what reads as "lens" at 16 pt, once the
    // gradients have blurred into a single tone.
    context.setFillColor(rgb(0.01, 0.02, 0.03))
    let pupil: CGFloat = 74
    context.fillEllipse(in: CGRect(
        x: centre.x - pupil, y: centre.y - pupil, width: pupil * 2, height: pupil * 2
    ))

    // Specular highlight across the upper left of the glass.
    context.saveGState()
    context.addEllipse(in: CGRect(
        x: centre.x - glass, y: centre.y - glass, width: glass * 2, height: glass * 2
    ))
    context.clip()
    if let sheen = gradient([grey(1, 0.34), grey(1, 0)], [0, 1]) {
        context.drawRadialGradient(
            sheen,
            startCenter: CGPoint(x: centre.x - glass * 0.4, y: centre.y + glass * 0.5),
            startRadius: 0,
            endCenter: CGPoint(x: centre.x - glass * 0.4, y: centre.y + glass * 0.5),
            endRadius: glass * 0.95,
            options: []
        )
    }
    context.restoreGState()
}

// MARK: - Output

private func render(side: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    drawIcon(in: context, side: CGFloat(side))
    return context.makeImage()
}

private func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2)
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let staging = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("OpenLensIcon-\(UUID().uuidString)/AppIcon.iconset")
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

/// The (point size, scale) pairs `iconutil` expects for macOS.
///
/// 512@2x is deliberately omitted. A 1024 px slice (`ic10`) makes macOS 26
/// treat the icon as legacy artwork and shrink it onto a light grey plate
/// instead of masking it edge to edge like every other app. Stopping at 512
/// gets the native treatment, and 512 is the largest size the Finder actually
/// asks an `.icns` for.
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1)
]

for variant in variants {
    let pixels = variant.point * variant.scale
    let name = "icon_\(variant.point)x\(variant.point)"
        + (variant.scale == 2 ? "@2x" : "") + ".png"
    guard let image = render(side: pixels) else {
        FileHandle.standardError.write("Failed to render \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    try write(image, to: staging.appendingPathComponent(name))
    print("drew \(name) (\(pixels)px)")
}

let output = root.appendingPathComponent("Sources/OpenLens/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", staging.path, "--output", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(output.path)")
