#!/usr/bin/env swift

import AppKit

// Generate a 1024x1024 app icon from the highjump.png source image
// Solid black background, white silhouette only, no text, no outline.
// The source image has rounded corners with a white border.
// Strategy: Draw the source larger than the canvas so the border and corners
// are cropped off, leaving just the black background with white figure.

let iconSize: CGFloat = 1024
let size = NSSize(width: iconSize, height: iconSize)

// Load source image
let sourcePath = "/Users/adamklein/Development/jump/highjump.png"
guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    print("Failed to load source image at: \(sourcePath)")
    exit(1)
}

let finalImage = NSImage(size: size)
finalImage.lockFocus()

// Solid black background
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: iconSize, height: iconSize).fill()

// Draw the source image LARGER than the canvas.
// The source has rounded corners + white border taking up ~8-12% of each edge.
// By drawing it at ~120% size and centering, the border and corners get cropped.
let overflow: CGFloat = 130  // how much the image extends beyond each edge
let drawRect = NSRect(
    x: -overflow,
    y: -overflow,
    width: iconSize + overflow * 2,
    height: iconSize + overflow * 2
)
sourceImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

finalImage.unlockFocus()

// Save as PNG
guard let tiffData = finalImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed to generate PNG data")
    exit(1)
}

let outputPath = "/Users/adamklein/Development/jump/Jump/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("✅ App icon saved to: \(outputPath)")
} catch {
    print("Failed to write icon: \(error)")
    exit(1)
}
