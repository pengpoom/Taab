#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let appIconURL = root.appendingPathComponent("resources/icons/app/app.iconset/icon_512x512@2x.png")
private let menuIconDirectory = root.appendingPathComponent("resources/icons/menubar")

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func drawGradient(_ context: CGContext, _ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

private func withRotation(_ context: CGContext, rect: CGRect, degrees: CGFloat, drawing: () -> Void) {
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: degrees * .pi / 180)
    context.translateBy(x: -rect.midX, y: -rect.midY)
    drawing()
    context.restoreGState()
}

private func drawGTrack(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat, color: CGColor) {
    context.saveGState()
    context.setStrokeColor(color)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let track = CGMutablePath()
    track.addArc(center: center, radius: radius, startAngle: 35 * .pi / 180, endAngle: 325 * .pi / 180, clockwise: false)
    context.addPath(track)
    context.strokePath()

    context.move(to: CGPoint(x: center.x + radius * 0.02, y: center.y))
    context.addLine(to: CGPoint(x: center.x + radius, y: center.y))
    context.addLine(to: CGPoint(x: center.x + radius, y: center.y - radius * 0.42))
    context.strokePath()
    context.restoreGState()
}

private func drawWindowCard(
    _ context: CGContext,
    rect: CGRect,
    radius: CGFloat,
    degrees: CGFloat,
    fill: CGColor,
    stroke: CGColor,
    shadowAlpha: CGFloat,
    foreground: Bool
) {
    withRotation(context, rect: rect, degrees: degrees) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -22), blur: 34, color: color(3, 18, 52, shadowAlpha))
        context.addPath(roundedRect(rect, radius))
        context.setFillColor(fill)
        context.fillPath()
        context.restoreGState()

        context.addPath(roundedRect(rect, radius))
        context.setStrokeColor(stroke)
        context.setLineWidth(5)
        context.strokePath()

        let titleBarY = rect.maxY - rect.height * 0.18
        context.setStrokeColor(color(255, 255, 255, foreground ? 0.16 : 0.22))
        context.setLineWidth(4)
        context.move(to: CGPoint(x: rect.minX + 32, y: titleBarY))
        context.addLine(to: CGPoint(x: rect.maxX - 32, y: titleBarY))
        context.strokePath()

        for index in 0..<3 {
            let dot = CGRect(
                x: rect.minX + 42 + CGFloat(index) * 35,
                y: titleBarY + 26,
                width: 16,
                height: 16
            )
            context.setFillColor(color(255, 255, 255, foreground ? 0.82 : 0.58))
            context.fillEllipse(in: dot)
        }

        if foreground {
            drawGTrack(
                context,
                center: CGPoint(x: rect.midX, y: rect.midY - 26),
                radius: 112,
                lineWidth: 62,
                color: color(255, 255, 255, 0.96)
            )
        }
    }
}

private func drawAppIcon(in context: CGContext, size: CGFloat) {
    let scale = size / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = CGRect(x: 38, y: 38, width: 948, height: 948)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 32, color: color(4, 24, 70, 0.28))
    context.addPath(roundedRect(tile, 220))
    context.setFillColor(color(24, 119, 242))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(roundedRect(tile, 220))
    context.clip()
    drawGradient(
        context,
        [color(36, 211, 220), color(44, 137, 244), color(57, 64, 205)],
        [0, 0.52, 1],
        from: CGPoint(x: 130, y: 910),
        to: CGPoint(x: 880, y: 100)
    )

    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(255, 255, 255, 0.34), color(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 230, y: 830), startRadius: 0,
        endCenter: CGPoint(x: 230, y: 830), endRadius: 570,
        options: []
    )
    context.restoreGState()

    context.addPath(roundedRect(tile.insetBy(dx: 4, dy: 4), 216))
    context.setStrokeColor(color(255, 255, 255, 0.26))
    context.setLineWidth(8)
    context.strokePath()

    drawWindowCard(
        context,
        rect: CGRect(x: 226, y: 455, width: 620, height: 360),
        radius: 58,
        degrees: -7,
        fill: color(255, 255, 255, 0.31),
        stroke: color(255, 255, 255, 0.34),
        shadowAlpha: 0.22,
        foreground: false
    )

    drawWindowCard(
        context,
        rect: CGRect(x: 170, y: 225, width: 690, height: 430),
        radius: 66,
        degrees: 3,
        fill: color(8, 35, 93, 0.91),
        stroke: color(255, 255, 255, 0.22),
        shadowAlpha: 0.34,
        foreground: true
    )

    context.restoreGState()
}

private func writeAppIcon() throws {
    let size = 1024
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "GlideIconGenerator", code: 1)
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawAppIcon(in: context, size: CGFloat(size))

    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GlideIconGenerator", code: 2)
    }
    try png.write(to: appIconURL, options: .atomic)
}

private enum MenuIconStyle: Int {
    case outlined = 0
    case filled = 1
    case colored = 2
}

private func writeMenuIcon(_ style: MenuIconStyle) throws {
    let url = menuIconDirectory.appendingPathComponent("menubar-\(style.rawValue).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 22, height: 22)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "GlideIconGenerator", code: 3)
    }

    context.beginPDFPage(nil)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    switch style {
        case .outlined:
            drawGTrack(context, center: CGPoint(x: 11, y: 11), radius: 7.15, lineWidth: 2.15, color: color(0, 0, 0))
        case .filled:
            drawGTrack(context, center: CGPoint(x: 11, y: 11), radius: 7.15, lineWidth: 3.25, color: color(0, 0, 0))
        case .colored:
            context.saveGState()
            drawGTrack(context, center: CGPoint(x: 11, y: 11), radius: 7.15, lineWidth: 3.1, color: color(31, 191, 220))
            context.setFillColor(color(69, 92, 230))
            context.fillEllipse(in: CGRect(x: 16.3, y: 6.2, width: 3.2, height: 3.2))
            context.restoreGState()
    }

    context.endPDFPage()
    context.closePDF()
}

do {
    try FileManager.default.createDirectory(at: appIconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: menuIconDirectory, withIntermediateDirectories: true)
    try writeAppIcon()
    try MenuIconStyle.allCases.forEach(writeMenuIcon)
    print("Generated Glide app and menubar icons")
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(1)
}

extension MenuIconStyle: CaseIterable {}
