#!/usr/bin/env swift

// make-icon.swift — builds the app icon + sidebar wordmark from
// Resources/logo-source.png.
//
// The source file is the canonical artwork. Everything else is derived
// by scaling it down with high-quality interpolation (Lanczos-ish via
// CoreGraphics). No pixel-art quantisation; we just resize cleanly.
//
// Produces:
//   Resources/AppIcon.iconset/*.png   — the full macOS icon family
//   Resources/LogoWordmark.png        — a down-scaled wordmark for the sidebar
//
// After running this, compile the iconset:
//     iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

import Foundation
import AppKit
import CoreGraphics

private let SOURCE_PATH = "Resources/logo-source.png"
private let ICONSET_DIR = "Resources/AppIcon.iconset"
private let WORDMARK_PATH = "Resources/LogoWordmark.png"

// MARK: - Load source

private func loadSource() -> CGImage {
    let url = URL(fileURLWithPath: SOURCE_PATH)
    guard let data = try? Data(contentsOf: url),
          let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            pngDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
          )
    else {
        FileHandle.standardError.write(Data("error: could not load \(SOURCE_PATH)\n".utf8))
        exit(1)
    }
    return image
}

/// Sample the top-left pixel of the source to get the background colour
/// (the cream paper tone). This lets us extend the rectangular source
/// into a square canvas for the icon without hardcoding a constant.
private func sampleBGColor(_ image: CGImage) -> CGColor {
    let cs = CGColorSpaceCreateDeviceRGB()
    var px: [UInt8] = [0, 0, 0, 0]
    let ctx = CGContext(
        data: &px,
        width: 1, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Draw the source so its top-left pixel lands in the 1×1 context.
    // CG's y axis grows up, so "top-left of the image" means drawing the
    // image with its top row aligned with the 1×1 ctx top row.
    ctx.interpolationQuality = .none
    ctx.draw(
        image,
        in: CGRect(x: 0, y: 1 - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height))
    )
    return CGColor(
        red:   CGFloat(px[0]) / 255,
        green: CGFloat(px[1]) / 255,
        blue:  CGFloat(px[2]) / 255,
        alpha: 1
    )
}

// MARK: - Icon composition

/// Render one iconset entry at `size` × `size` pixels.
///
/// The source logo is wider than it is tall (wordmark aspect), so we
/// place it on a square canvas filled with the source's own cream
/// background, scaled to fit ~94% of the canvas width/height so it has
/// a small border. High-quality interpolation keeps the text smooth.
private func drawIcon(size: Int, source: CGImage, bg: CGColor) -> CGImage {
    let w = size, h = size
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // 1. Rounded-square cream background (matches the source paper tone).
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    let cornerR = CGFloat(w) * 0.2237
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
    let bgPath = CGPath(
        roundedRect: canvas,
        cornerWidth: cornerR,
        cornerHeight: cornerR,
        transform: nil
    )
    ctx.addPath(bgPath)
    ctx.setFillColor(bg)
    ctx.fillPath()

    // 2. Logo — fit inside the squircle with a small margin so the
    //    rounded corners aren't crowded.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.interpolationQuality = .high

    let srcW = CGFloat(source.width)
    let srcH = CGFloat(source.height)
    let fit = CGFloat(w) * 0.92
    let scale = min(fit / srcW, fit / srcH)
    let drawW = srcW * scale
    let drawH = srcH * scale
    let drawX = (CGFloat(w) - drawW) / 2
    let drawY = (CGFloat(h) - drawH) / 2
    ctx.draw(source, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Wordmark (simple downscale of the source)

/// Produce a moderately-sized wordmark PNG by scaling the source down
/// with high-quality interpolation. Keeping it well above the display
/// size means SwiftUI's own scaling stays in "downscale" mode and looks
/// smooth regardless of the sidebar's display height.
private func drawWordmark(source: CGImage) -> CGImage {
    let srcW = CGFloat(source.width)
    let srcH = CGFloat(source.height)
    // Target a ~400 pt wide wordmark at 2x retina (≈ 800 px). That's
    // plenty of headroom for any sidebar size we'd realistically use.
    let targetW = 800
    let scale = CGFloat(targetW) / srcW
    let targetH = Int((srcH * scale).rounded())

    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: targetW, height: targetH,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(targetW), height: CGFloat(targetH)))
    return ctx.makeImage()!
}

// MARK: - PNG writer

private func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: url)
}

// MARK: - Iconset spec + main

private let iconsetSpec: [(name: String, size: Int)] = [
    ("icon_16x16.png",        16),
    ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32),
    ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",      128),
    ("icon_128x128@2x.png",   256),
    ("icon_256x256.png",      256),
    ("icon_256x256@2x.png",   512),
    ("icon_512x512.png",      512),
    ("icon_512x512@2x.png",   1024),
]

let source = loadSource()
let bg = sampleBGColor(source)
let fm = FileManager.default

// Iconset
let iconsetURL = URL(fileURLWithPath: ICONSET_DIR, isDirectory: true)
try? fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for (name, size) in iconsetSpec {
    let url = iconsetURL.appendingPathComponent(name)
    let img = drawIcon(size: size, source: source, bg: bg)
    do {
        try writePNG(img, to: url)
        print("wrote \(url.path) — \(size) px")
    } catch {
        FileHandle.standardError.write(Data("failed \(url.path): \(error)\n".utf8))
        exit(1)
    }
}

// Wordmark
let wordmark = drawWordmark(source: source)
do {
    try writePNG(wordmark, to: URL(fileURLWithPath: WORDMARK_PATH))
    print("wrote \(WORDMARK_PATH) — \(wordmark.width)×\(wordmark.height) px")
} catch {
    FileHandle.standardError.write(Data("failed \(WORDMARK_PATH): \(error)\n".utf8))
    exit(1)
}

print("\nNext: iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns")
