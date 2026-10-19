import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rasterize only the existing vector icon export; never process reference art.
guard CommandLine.arguments.count == 4,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Usage: swift export-mobile-icon.swift rendered-svg.png ios-icon.png watch-icon.png")
}
let size = 1024
let context = CGContext(data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 17 / 255, green: 28 / 255, blue: 29 / 255, alpha: 1))
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
context.fill(bounds)
context.draw(image, in: bounds)
let opaque = context.makeImage()!
for destination in CommandLine.arguments.dropFirst(2) {
    let output = CGImageDestinationCreateWithURL(URL(fileURLWithPath: destination) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, opaque, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not save icon: \(destination)") }
}
print("Exported opaque 1024px iPhone and Watch icons from the shared SVG artwork.")
