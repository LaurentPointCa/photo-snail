#!/usr/bin/env swift

// prepare-logo.swift — takes a pixel-art logo PNG with a white background,
// replaces white pixels with transparency, crops to the bounding box of
// non-transparent content (with a small margin), and writes the result as
// the new logo-source.png.
//
// Usage: swift tools/prepare-logo.swift "new logo.png"

import Foundation
import AppKit
import CoreGraphics

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: prepare-logo.swift <input.png>\n".utf8))
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = "Resources/logo-source.png"

// MARK: - Load

guard let inputData = try? Data(contentsOf: URL(fileURLWithPath: inputPath)),
      let provider = CGDataProvider(data: inputData as CFData),
      let source = CGImage(
          pngDataProviderSource: provider,
          decode: nil,
          shouldInterpolate: false,
          intent: .defaultIntent
      ) else {
    FileHandle.standardError.write(Data("error: could not load \(inputPath)\n".utf8))
    exit(1)
}

let w = source.width
let h = source.height
print("loaded \(inputPath) — \(w)×\(h)")

// MARK: - Draw into RGBA buffer

let cs = CGColorSpaceCreateDeviceRGB()
let bytesPerRow = w * 4
var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)

let ctx = CGContext(
    data: &pixels,
    width: w, height: h,
    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.interpolationQuality = .none
ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))

// MARK: - White → transparent

// Threshold: any pixel where all of R, G, B are above this value is
// treated as "white background" and set to fully transparent.
let threshold: UInt8 = 235

var minX = w, minY = h, maxX = 0, maxY = 0

for row in 0..<h {
    for col in 0..<w {
        let offset = row * bytesPerRow + col * 4
        let r = pixels[offset]
        let g = pixels[offset + 1]
        let b = pixels[offset + 2]

        if r > threshold && g > threshold && b > threshold {
            // White → transparent
            pixels[offset]     = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        } else {
            // Non-white → track bounding box
            if col < minX { minX = col }
            if col > maxX { maxX = col }
            // CG row 0 is bottom of image
            if row < minY { minY = row }
            if row > maxY { maxY = row }
        }
    }
}

guard maxX >= minX && maxY >= minY else {
    FileHandle.standardError.write(Data("error: image appears to be entirely white\n".utf8))
    exit(1)
}

print("content bounding box: (\(minX), \(minY)) → (\(maxX), \(maxY))")

// MARK: - Crop with a small margin

let margin = 4
let cropX = max(0, minX - margin)
let cropY = max(0, minY - margin)
let cropW = min(w, maxX + margin + 1) - cropX
let cropH = min(h, maxY + margin + 1) - cropY

// Create a new image from the modified pixel buffer
let fullImage = ctx.makeImage()!

// Crop. CG's cropping rect is in the image's own coordinate space
// (origin at bottom-left), which matches our row-0-is-bottom buffer.
guard let cropped = fullImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else {
    FileHandle.standardError.write(Data("error: cropping failed\n".utf8))
    exit(1)
}

print("cropped to \(cropped.width)×\(cropped.height)")

// MARK: - Write PNG

let rep = NSBitmapImageRep(cgImage: cropped)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: PNG encoding failed\n".utf8))
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) — \(cropped.width)×\(cropped.height) px, transparent background")
