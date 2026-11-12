#!/usr/bin/env swift
// Draws the Daybreak app icon with CoreGraphics and packs it into an .icns with iconutil.
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

/// A smooth hill silhouette across the body, from `left` to `right` heights (fractions of size).
func hill(in rect: CGRect, left: CGFloat, peak: CGFloat, peakX: CGFloat, right: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let y = { (f: CGFloat) in rect.minY + rect.height * f }
    let x = { (f: CGFloat) in rect.minX + rect.width * f }
    path.move(to: CGPoint(x: rect.minX - 10, y: rect.minY - 10))
    path.addLine(to: CGPoint(x: rect.minX - 10, y: y(left)))
    path.addCurve(to: CGPoint(x: x(peakX), y: y(peak)),
                  control1: CGPoint(x: x(peakX * 0.45), y: y(left)),
                  control2: CGPoint(x: x(peakX * 0.7), y: y(peak)))
    path.addCurve(to: CGPoint(x: rect.maxX + 10, y: y(right)),
                  control1: CGPoint(x: x(peakX + (1 - peakX) * 0.35), y: y(peak)),
                  control2: CGPoint(x: x(peakX + (1 - peakX) * 0.6), y: y(right)))
    path.addLine(to: CGPoint(x: rect.maxX + 10, y: rect.minY - 10))
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
    let detailed = pixels >= 64

    // Drop shadow (macOS grid: below the body, soft).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B1F4B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Sky: night indigo at the top warming to gold at the horizon.
    let horizon = body.minY + body.height * 0.36
    ctx.drawLinearGradient(
        gradient([(0x16205A, 0, 1), (0x3C2F86, 0.30, 1), (0x9A4A9A, 0.55, 1), (0xF2785C, 0.80, 1), (0xFFC56E, 1, 1)]),
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])

    let sunCenter = CGPoint(x: body.midX, y: horizon)
    let sunRadius = body.width * 0.205

    // Atmospheric glow around the sun.
    ctx.drawRadialGradient(
        gradient([(0xFFE7A3, 0, 0.85), (0xFFB061, 0.35, 0.45), (0xF2785C, 1, 0)]),
        startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: body.width * 0.62, options: [])

    // Rays.
    if detailed {
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        let rays = 9
        for i in 0..<rays {
            let angle = CGFloat.pi * (0.08 + 0.84 * CGFloat(i) / CGFloat(rays - 1))
            let spread: CGFloat = 0.045
            let length = body.width * 0.75
            let path = CGMutablePath()
            path.move(to: sunCenter)
            path.addLine(to: CGPoint(x: sunCenter.x + cos(angle - spread) * length, y: sunCenter.y + sin(angle - spread) * length))
            path.addLine(to: CGPoint(x: sunCenter.x + cos(angle + spread) * length, y: sunCenter.y + sin(angle + spread) * length))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawRadialGradient(
                gradient([(0xFFF1C9, 0, 0.22), (0xFFF1C9, 1, 0)]),
                startCenter: sunCenter, startRadius: sunRadius, endCenter: sunCenter, endRadius: length, options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // Sun disc.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0xFFFBE8, 0, 1), (0xFFDD8A, 0.55, 1), (0xFFA44F, 1, 1)]),
        start: CGPoint(x: 0, y: sunCenter.y + sunRadius), end: CGPoint(x: 0, y: sunCenter.y - sunRadius), options: [])
    ctx.restoreGState()

    // Back hills (lit rim), then front hills.
    let back = hill(in: body, left: 0.40, peak: 0.335, peakX: 0.26, right: 0.385)
    ctx.addPath(back)
    ctx.setFillColor(color(0x6A3C8C))
    ctx.fillPath()
    let front = hill(in: body, left: 0.25, peak: 0.315, peakX: 0.72, right: 0.20)
    ctx.saveGState()
    ctx.addPath(front)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0x3A2470, 0, 1), (0x1A1446, 1, 1)]),
        start: CGPoint(x: 0, y: body.minY + body.height * 0.32), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // Path winding toward the sun, a quiet nod to "relaunch".
    if detailed {
        let road = CGMutablePath()
        let bx = body.minX, by = body.minY, w = body.width, h = body.height
        road.move(to: CGPoint(x: bx + w * 0.40, y: by - 4))
        road.addCurve(to: CGPoint(x: bx + w * 0.545, y: by + h * 0.27),
                      control1: CGPoint(x: bx + w * 0.70, y: by + h * 0.12),
                      control2: CGPoint(x: bx + w * 0.42, y: by + h * 0.20))
        road.addCurve(to: CGPoint(x: bx + w * 0.62, y: by - 4),
                      control1: CGPoint(x: bx + w * 0.48, y: by + h * 0.20),
                      control2: CGPoint(x: bx + w * 0.86, y: by + h * 0.12))
        road.closeSubpath()
        ctx.saveGState()
        ctx.addPath(front)
        ctx.clip()
        ctx.addPath(road)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0xFFC56E, 0, 0.95), (0xF2785C, 1, 0.55)]),
            start: CGPoint(x: 0, y: by), end: CGPoint(x: 0, y: by + h * 0.28), options: [])
        ctx.restoreGState()
    }

    // Glassy top highlight and a hairline edge for definition on light and dark backgrounds.
    ctx.drawLinearGradient(
        gradient([(0xFFFFFF, 0, 0.16), (0xFFFFFF, 0.45, 0)]),
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
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
    .appendingPathComponent("Daybreak-\(UUID().uuidString).iconset", isDirectory: true)
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
