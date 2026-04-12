#!/usr/bin/env swift

// logo-samples.swift — renders the four logo proposals into a single
// composite PNG so the user can compare them side by side at the same
// scale they'd appear in the sidebar.
//
// Pure Core Graphics + AppKit. No SwiftUI run loop or ImageRenderer
// gymnastics. Each option is drawn into its own card on a dark canvas
// matching the actual sidebar background.
//
// Output: /tmp/logo-samples.png

import Foundation
import AppKit
import CoreGraphics

// MARK: - Layout

let CANVAS_W: CGFloat = 820
let SAMPLE_H: CGFloat = 120
let HEADER_H: CGFloat = 28
let MARGIN: CGFloat = 28
let SAMPLE_COUNT = 4
let CANVAS_H: CGFloat =
    MARGIN
    + CGFloat(SAMPLE_COUNT) * (HEADER_H + SAMPLE_H)
    + CGFloat(SAMPLE_COUNT - 1) * MARGIN
    + MARGIN

// MARK: - Color tokens (mirroring DesignSystem.swift dark mode values)

let bgDark        = CGColor(red: 0.10, green: 0.10, blue: 0.115, alpha: 1.0)
let bgCard        = CGColor(red: 0.18, green: 0.18, blue: 0.20,  alpha: 1.0)
let cardBorder    = CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)
let textPrimary   = NSColor.white
let textSecondary = NSColor(white: 1.0, alpha: 0.55)
let accent        = CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
let accentNS      = NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)

// MARK: - Context setup

func makeContext(width: Int, height: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

// MARK: - Drawing helpers

func withNSGraphicsContext(_ cg: CGContext, _ block: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    block()
    NSGraphicsContext.restoreGraphicsState()
}

func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor, ctx: CGContext) {
    withNSGraphicsContext(ctx) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}

func textSize(_ s: String, font: NSFont) -> CGSize {
    (s as NSString).size(withAttributes: [.font: font])
}

extension NSFont {
    func rounded() -> NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - Sample card frame

/// Lays out one sample at vertical offset `topOffset` from the top of the
/// canvas, draws the eyebrow title above the card, and returns the inner
/// content rect for the option's drawing function. CG coordinates are
/// y-up so this converts the offset-from-top into a y-from-bottom rect.
func drawSampleFrame(in ctx: CGContext, topOffset: CGFloat, title: String) -> CGRect {
    let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let titleY = CANVAS_H - topOffset - HEADER_H + 8
    drawText(
        title.uppercased(),
        at: CGPoint(x: MARGIN + 4, y: titleY),
        font: titleFont,
        color: textSecondary,
        ctx: ctx
    )

    let cardRect = CGRect(
        x: MARGIN,
        y: CANVAS_H - topOffset - HEADER_H - SAMPLE_H,
        width: CANVAS_W - MARGIN * 2,
        height: SAMPLE_H
    )
    let cardPath = CGPath(
        roundedRect: cardRect,
        cornerWidth: 14,
        cornerHeight: 14,
        transform: nil
    )

    ctx.addPath(cardPath)
    ctx.setFillColor(bgCard)
    ctx.fillPath()

    ctx.addPath(cardPath)
    ctx.setStrokeColor(cardBorder)
    ctx.setLineWidth(1)
    ctx.strokePath()

    return cardRect
}

// MARK: - Option 1: Modernized vector snail + wordmark

func drawOption1(in ctx: CGContext, frame: CGRect) {
    let snailSize: CGFloat = 76
    let snailX = frame.minX + 32
    let snailY = frame.minY + (frame.height - snailSize) / 2
    drawSnailMark(in: ctx, frame: CGRect(x: snailX, y: snailY, width: snailSize, height: snailSize))

    let topFont = NSFont.systemFont(ofSize: 30, weight: .bold).rounded()
    let bottomFont = NSFont.systemFont(ofSize: 30, weight: .light).rounded()

    let wordX = snailX + snailSize + 22
    let wordY = frame.midY - 19
    let topW = textSize("photo", font: topFont).width
    drawText("photo", at: CGPoint(x: wordX, y: wordY), font: topFont, color: textPrimary, ctx: ctx)
    drawText("snail", at: CGPoint(x: wordX + topW + 8, y: wordY), font: bottomFont, color: NSColor(white: 1, alpha: 0.65), ctx: ctx)
}

/// A right-facing snail: round shell sitting on top of a body that
/// extends to the right with a head bulge and two antennae. Drawn as
/// one continuous silhouette so the body and shell read as one creature.
func drawSnailMark(in ctx: CGContext, frame: CGRect) {
    // The body is a single continuous shape: wide flat curve underneath,
    // arcing up on the right to form a head, then a small dip back down.
    // Drawn first in the lighter accent so the shell circle (drawn next)
    // sits on top and the silhouettes overlap.
    let body = CGMutablePath()
    let bodyBaseY = frame.minY + 4
    let bodyTopY = frame.minY + frame.height * 0.42
    let leftX = frame.minX + 6
    let headRightX = frame.minX + frame.width - 6
    let headTopY = frame.minY + frame.height * 0.55

    body.move(to: CGPoint(x: leftX, y: bodyBaseY))
    // Bottom edge: long flat line along the base
    body.addLine(to: CGPoint(x: headRightX - 4, y: bodyBaseY))
    // Right edge: curve up to form the head
    body.addQuadCurve(
        to: CGPoint(x: headRightX, y: headTopY),
        control: CGPoint(x: headRightX + 4, y: bodyBaseY + 2)
    )
    // Top edge: head bulge curving down to where the shell sits
    body.addQuadCurve(
        to: CGPoint(x: frame.minX + frame.width * 0.55, y: bodyTopY),
        control: CGPoint(x: frame.minX + frame.width * 0.78, y: headTopY)
    )
    // Continue along the top to the left edge
    body.addLine(to: CGPoint(x: leftX + 4, y: bodyTopY))
    // Left edge: curve back down to close the shape
    body.addQuadCurve(
        to: CGPoint(x: leftX, y: bodyBaseY),
        control: CGPoint(x: leftX - 4, y: bodyBaseY + 2)
    )
    body.closeSubpath()

    ctx.addPath(body)
    ctx.setFillColor(accent.copy(alpha: 0.55)!)
    ctx.fillPath()

    // Shell — large filled circle in accent, sitting on top of the body
    // so the silhouettes overlap and read as one creature
    let shellSize = frame.height * 0.74
    let shellRect = CGRect(
        x: frame.minX + frame.width * 0.06,
        y: frame.minY + frame.height - shellSize - 1,
        width: shellSize,
        height: shellSize
    )
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: shellRect)

    // Spiral inside the shell — clockwise from the top, growing outward
    let center = CGPoint(x: shellRect.midX, y: shellRect.midY)
    let maxR = shellRect.width / 2 - 5
    let steps = 110
    let maxTheta: CGFloat = 3.5 * .pi
    let aFactor = maxR / maxTheta
    for i in 0...steps {
        let progress = CGFloat(i) / CGFloat(steps)
        let theta = .pi / 2 - maxTheta * progress
        let r = aFactor * (maxTheta * progress)
        let x = center.x + r * cos(theta)
        let y = center.y + r * sin(theta)
        if i == 0 {
            ctx.move(to: CGPoint(x: x, y: y))
        } else {
            ctx.addLine(to: CGPoint(x: x, y: y))
        }
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Antennae — two short lines rising from the head bulge on the
    // right side of the body, with small dot tips. Drawn in the lighter
    // accent (matches the body) so they read as part of the same creature.
    ctx.setStrokeColor(accent.copy(alpha: 0.55)!)
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    let antBaseX = headRightX - 4
    let antBaseY = headTopY + 2
    ctx.move(to: CGPoint(x: antBaseX - 5, y: antBaseY))
    ctx.addLine(to: CGPoint(x: antBaseX - 3, y: antBaseY + 12))
    ctx.move(to: CGPoint(x: antBaseX - 1, y: antBaseY))
    ctx.addLine(to: CGPoint(x: antBaseX + 2, y: antBaseY + 12))
    ctx.strokePath()

    ctx.setFillColor(accent.copy(alpha: 0.65)!)
    ctx.fillEllipse(in: CGRect(x: antBaseX - 5, y: antBaseY + 10, width: 4, height: 4))
    ctx.fillEllipse(in: CGRect(x: antBaseX, y: antBaseY + 10, width: 4, height: 4))
}

// MARK: - Option 2: Wordmark only (typographic)

/// Two sub-variants of the wordmark, side-by-side, so the user can see
/// both a one-line and a stacked treatment. Both at sidebar-realistic
/// sizes (~32pt cap-height).
func drawOption2(in ctx: CGContext, frame: CGRect) {
    let half = frame.width / 2

    // Variant A — one line, weight contrast (left half)
    let leftCenterX = frame.minX + half / 2
    do {
        let topFont = NSFont.systemFont(ofSize: 32, weight: .bold).rounded()
        let bottomFont = NSFont.systemFont(ofSize: 32, weight: .light).rounded()
        let topW = textSize("photo", font: topFont).width
        let bottomW = textSize("snail", font: bottomFont).width
        let totalW = topW + 8 + bottomW
        let startX = leftCenterX - totalW / 2
        let baselineY = frame.midY - 16
        drawText("photo", at: CGPoint(x: startX, y: baselineY), font: topFont, color: textPrimary, ctx: ctx)
        drawText("snail", at: CGPoint(x: startX + topW + 8, y: baselineY), font: bottomFont, color: NSColor(white: 1, alpha: 0.62), ctx: ctx)
    }

    // Vertical separator
    ctx.setStrokeColor(cardBorder)
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: frame.midX, y: frame.minY + 12))
    ctx.addLine(to: CGPoint(x: frame.midX, y: frame.maxY - 12))
    ctx.strokePath()

    // Variant B — stacked, monospaced lowercase (right half)
    let rightCenterX = frame.midX + half / 2
    do {
        let mono = NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold)
        let topW = textSize("photo", font: mono).width
        let bottomW = textSize("snail", font: mono).width
        let widest = max(topW, bottomW)
        let startX = rightCenterX - widest / 2
        drawText("photo", at: CGPoint(x: startX, y: frame.midY + 4), font: mono, color: textPrimary, ctx: ctx)
        drawText("snail", at: CGPoint(x: startX, y: frame.midY - 24), font: mono, color: NSColor(white: 1, alpha: 0.55), ctx: ctx)
    }
}

// MARK: - Option 3: Geometric spiral mark + wordmark

func drawOption3(in ctx: CGContext, frame: CGRect) {
    let markSize: CGFloat = 64
    let markX = frame.minX + 38
    let markY = frame.minY + (frame.height - markSize) / 2
    drawGeometricSpiral(in: ctx, frame: CGRect(x: markX, y: markY, width: markSize, height: markSize))

    let font = NSFont.systemFont(ofSize: 30, weight: .semibold).rounded()
    let wordX = markX + markSize + 24
    let wordY = frame.midY - 19
    drawText("photo snail", at: CGPoint(x: wordX, y: wordY), font: font, color: textPrimary, ctx: ctx)
}

func drawGeometricSpiral(in ctx: CGContext, frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let outerR = min(frame.width, frame.height) / 2 - 2

    // Outer ring
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(
        x: center.x - outerR,
        y: center.y - outerR,
        width: outerR * 2,
        height: outerR * 2
    ))

    // Inner spiral filling the disc — clockwise from top, shrinking inward
    let steps = 140
    let maxTheta: CGFloat = 4 * .pi
    for i in 0...steps {
        let progress = CGFloat(i) / CGFloat(steps)
        let theta = .pi / 2 - maxTheta * progress
        let r = outerR * (1 - progress * 0.96)
        let x = center.x + r * cos(theta)
        let y = center.y + r * sin(theta)
        if i == 0 {
            ctx.move(to: CGPoint(x: x, y: y))
        } else {
            ctx.addLine(to: CGPoint(x: x, y: y))
        }
    }
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

// MARK: - Option 4: SF Symbol composition + wordmark

func drawOption4(in ctx: CGContext, frame: CGRect) {
    // Show three SF Symbol candidates so the user sees the range. The
    // most on-the-nose for "photo + description" is text.below.photo.fill;
    // photo.stack.fill is more about the library aspect; tag.fill is the
    // most abstract.
    let candidates = ["text.below.photo.fill", "photo.stack.fill", "tag.fill"]
    let cellW = frame.width / CGFloat(candidates.count)

    for (i, name) in candidates.enumerated() {
        let cellRect = CGRect(
            x: frame.minX + cellW * CGFloat(i),
            y: frame.minY,
            width: cellW,
            height: frame.height
        )
        drawSymbolCandidate(in: ctx, frame: cellRect, symbolName: name)

        // Vertical separator (skip the last)
        if i < candidates.count - 1 {
            ctx.setStrokeColor(cardBorder)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: cellRect.maxX, y: frame.minY + 12))
            ctx.addLine(to: CGPoint(x: cellRect.maxX, y: frame.maxY - 12))
            ctx.strokePath()
        }
    }
}

func drawSymbolCandidate(in ctx: CGContext, frame: CGRect, symbolName: String) {
    let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
    guard let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        return
    }
    baseSymbol.isTemplate = true

    // Tint by masking a colored fill with the template image
    let tinted = NSImage(size: baseSymbol.size)
    tinted.lockFocus()
    accentNS.setFill()
    NSRect(origin: .zero, size: baseSymbol.size).fill()
    baseSymbol.draw(
        at: .zero,
        from: NSRect(origin: .zero, size: baseSymbol.size),
        operation: .destinationIn,
        fraction: 1.0
    )
    tinted.unlockFocus()

    let symX = frame.minX + 16
    let symY = frame.midY - tinted.size.height / 2 + 4

    withNSGraphicsContext(ctx) {
        tinted.draw(
            at: NSPoint(x: symX, y: symY),
            from: NSRect(origin: .zero, size: tinted.size),
            operation: .sourceOver,
            fraction: 1.0
        )
    }

    let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
    let wordX = symX + tinted.size.width + 12
    let wordY = frame.midY - 11
    drawText("photo snail", at: CGPoint(x: wordX, y: wordY), font: font, color: textPrimary, ctx: ctx)

    // Symbol name caption below
    let captionFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    drawText(symbolName, at: CGPoint(x: symX, y: symY - 14), font: captionFont, color: textSecondary, ctx: ctx)
}

// MARK: - Main

let ctx = makeContext(width: Int(CANVAS_W), height: Int(CANVAS_H))

// Dark canvas background
ctx.setFillColor(bgDark)
ctx.fill(CGRect(x: 0, y: 0, width: CANVAS_W, height: CANVAS_H))

let samples: [(String, (CGContext, CGRect) -> Void)] = [
    ("Option 1 — Modernized vector snail + wordmark", drawOption1),
    ("Option 2 — Wordmark only (typographic)", drawOption2),
    ("Option 3 — Geometric spiral mark + wordmark", drawOption3),
    ("Option 4 — SF Symbol composition + wordmark", drawOption4),
]

var topOffset: CGFloat = MARGIN
for (title, drawFn) in samples {
    let frame = drawSampleFrame(in: ctx, topOffset: topOffset, title: title)
    drawFn(ctx, frame)
    topOffset += HEADER_H + SAMPLE_H + MARGIN
}

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("error: ctx.makeImage() returned nil\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: PNG encoding failed\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: "/tmp/logo-samples.png"))
print("wrote /tmp/logo-samples.png — \(Int(CANVAS_W))×\(Int(CANVAS_H)) px")
