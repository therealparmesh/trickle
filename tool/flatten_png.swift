import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4,
      let size = Int(CommandLine.arguments[3]),
      size > 0,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1])
else {
  fputs("usage: flatten_png source destination size\n", stderr)
  exit(2)
}

var proposedRect = NSRect(origin: .zero, size: image.size)
guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
      let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
else {
  fputs("could not create image context\n", stderr)
  exit(1)
}

context.setFillColor(
  CGColor(
    red: 6.0 / 255.0,
    green: 9.0 / 255.0,
    blue: 14.0 / 255.0,
    alpha: 1
  )
)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.interpolationQuality = .high
context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))

let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
else {
  fputs("could not create PNG destination\n", stderr)
  exit(1)
}
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else {
  fputs("could not encode PNG\n", stderr)
  exit(1)
}
