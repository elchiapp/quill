import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Resolution/format export only. Do not alter the generated 3D artwork.
guard CommandLine.arguments.count == 5,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Usage: swift export-mobile-icon.swift master.png mac-icon.png ios-icon.png watch-icon.png")
}
let size = 1024
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
func save(_ image: CGImage, to destination: String) {
    let output = CGImageDestinationCreateWithURL(URL(fileURLWithPath: destination) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not save icon: \(destination)") }
}
let mac = CGContext(data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
mac.interpolationQuality = .high
mac.draw(image, in: bounds)
save(mac.makeImage()!, to: CommandLine.arguments[2])
let context = CGContext(data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 17 / 255, green: 28 / 255, blue: 29 / 255, alpha: 1))
context.fill(bounds)
context.interpolationQuality = .high
context.draw(image, in: bounds)
let opaque = context.makeImage()!
for destination in CommandLine.arguments.dropFirst(3) {
    save(opaque, to: destination)
}
print("Exported 1024px Mac, iPhone and Watch icons from the shared 3D master.")
