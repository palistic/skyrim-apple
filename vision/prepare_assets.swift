// Mechanical Xcode asset packaging. The generated master artwork is unchanged.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let input = root.appendingPathComponent("Artwork/SkyrimAdjacent-original.png")
let catalog = root.appendingPathComponent("Resources/Assets.xcassets")
let info: [String: Any] = ["author": "xcode", "version": 1]
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func json(_ value: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func context(opaque: Bool = false) -> CGContext {
    CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
              bytesPerRow: 4096, space: colorSpace,
              bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
}

func png(_ image: CGImage, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create icon asset")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon asset") }
}

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil), master.width == master.height else {
    fatalError("Expected the original square generated launcher icon")
}
let back = context(opaque: true)
back.setFillColor(CGColor(gray: 0.025, alpha: 1))
back.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
back.interpolationQuality = .high
back.draw(master, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let normalized = back.makeImage()!
let front = context()
front.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

let stack = catalog.appendingPathComponent("AppIcon.solidimagestack")
try json(["info": info, "layers": [["filename": "Front.solidimagestacklayer"],
                                    ["filename": "Back.solidimagestacklayer"]]],
         at: stack.appendingPathComponent("Contents.json"))
for (name, image) in [("Front", front.makeImage()!), ("Back", normalized)] {
    let layer = stack.appendingPathComponent("\(name).solidimagestacklayer")
    let content = layer.appendingPathComponent("Content.imageset")
    try json(["info": info], at: layer.appendingPathComponent("Contents.json"))
    try json(["info": info, "images": [["filename": "\(name).png", "idiom": "vision", "scale": "2x"]]],
             at: content.appendingPathComponent("Contents.json"))
    try png(image, at: content.appendingPathComponent("\(name).png"))
}
let artwork = catalog.appendingPathComponent("LauncherArtwork.imageset")
try json(["info": info, "images": [["filename": "Artwork.png", "idiom": "universal"]]],
         at: artwork.appendingPathComponent("Contents.json"))
try png(normalized, at: artwork.appendingPathComponent("Artwork.png"))
print("Packaged original artwork as a 1024px visionOS icon and launcher cover.")
