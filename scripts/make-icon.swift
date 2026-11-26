#!/usr/bin/env swift
// Draws the Evergreen app icon with CoreGraphics and packs it into an .icns with iconutil.
//
//   swift scripts/make-icon.swift app/Resources/AppIcon.icns [preview-512.png]
//
// Follows the macOS icon grid: 1024 pt canvas, 824 pt continuous-corner body centred with a
// 100 pt margin, and a soft drop shadow below the body. Every size is rendered from vectors
// (no downscaling), and fine detail is dropped at the smallest sizes.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift OUTPUT.icns [PREVIEW.png]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let preview = arguments.count >= 3 ? URL(fileURLWithPath: arguments[2]) : nil

let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.2) } as CFArray,
               locations: stops.map(\.1))!
}

/// Superellipse (n = 4.6) approximating Apple's continuous-corner icon body.
func bodyPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 4.6
    let steps = 720
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let unit = size / 1024
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = bodyPath(in: body)

    // Drop shadow (macOS grid: below the body, soft).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x102F25))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    ctx.drawLinearGradient(
        gradient([(0x2F7557, 0, 1), (0x164735, 0.55, 1), (0x102F25, 1, 1)]),
        start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    if pixels >= 64 {
        let glow = CGPoint(x: body.midX, y: body.maxY - body.height * 0.15)
        ctx.drawRadialGradient(
            gradient([(0xB2EBAC, 0, 0.23), (0xB2EBAC, 1, 0)]),
            startCenter: glow, startRadius: 0, endCenter: glow, endRadius: body.width * 0.74, options: [])
    }

    // The three boughs share one silhouette so the tree stays legible at menu and Dock sizes.
    let tree = CGMutablePath()
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: body.midX + body.width * x, y: body.minY + body.height * y)
    }
    tree.move(to: point(0, 0.82))
    for (x, y) in [(0.16, 0.60), (0.095, 0.60), (0.23, 0.43), (0.15, 0.43),
                   (0.30, 0.25), (0.046, 0.25), (0.046, 0.16), (-0.046, 0.16),
                   (-0.046, 0.25), (-0.30, 0.25), (-0.15, 0.43), (-0.23, 0.43),
                   (-0.095, 0.60), (-0.16, 0.60)] {
        tree.addLine(to: point(x, y))
    }
    tree.closeSubpath()

    ctx.saveGState()
    ctx.addPath(tree)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0xF3FFDC, 0, 1), (0xC3ECAB, 0.57, 1), (0x82C69A, 1, 1)]),
        start: point(0, 0.82), end: point(0, 0.16), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(color(0x000000, 0.18))
    ctx.setLineWidth(max(1, 2 * unit))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Evergreen-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(render(pixels: points * scale), to: iconset.appendingPathComponent(name))
    }
}
if let preview {
    try writePNG(render(pixels: 512), to: preview)
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output.path)")
