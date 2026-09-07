// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func polygon(_ points: [(CGFloat, CGFloat)], _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
    path.close()
    color.setFill()
    path.fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.39, blue: 0.61, alpha: 1),
                   ending: NSColor(calibratedRed: 0.08, green: 0.19, blue: 0.36, alpha: 1))!.draw(in: background, angle: -75)
        polygon([(230, 324), (512, 190), (794, 324), (794, 645), (512, 778), (230, 645)],
                NSColor(calibratedRed: 0.90, green: 0.69, blue: 0.40, alpha: 1))
        polygon([(512, 190), (794, 324), (794, 645), (512, 510)],
                NSColor(calibratedRed: 0.73, green: 0.49, blue: 0.25, alpha: 1))
        polygon([(230, 645), (512, 510), (794, 645), (512, 778)],
                NSColor(calibratedRed: 1, green: 0.84, blue: 0.57, alpha: 1))
        polygon([(425, 736), (706, 602), (631, 566), (349, 700)],
                NSColor(calibratedRed: 1, green: 0.94, blue: 0.77, alpha: 1))
        polygon([(631, 566), (706, 602), (706, 451), (631, 415)],
                NSColor(calibratedRed: 0.93, green: 0.79, blue: 0.57, alpha: 1))
        let label = NSBezierPath(roundedRect: NSRect(x: 300, y: 335, width: 126, height: 44), xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 1, alpha: 0.8).setFill(); label.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
