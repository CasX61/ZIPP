#!/usr/bin/env swift
// Erzeugt aus einem randlosen, quadratischen Bild das macOS-App-Icon:
// abgerundete Form (Squircle, „continuous corners“) im Apple-Raster
// (824 × 824 auf 1024 × 1024), transparenter Rand, dezenter Schatten.
// Danach alle Größen für Assets.xcassets/AppIcon.appiconset.
//
// Aufruf: swift scripts/make-icon.swift assets/AppIcon-source.png app/Zipp/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Aufruf: make-icon.swift <quelle.png> <ziel.appiconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let scale = s / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = RoundedRectangle(cornerRadius: 185.4 * scale, style: .continuous).path(in: body).cgPath

    // Schatten (wie in Apples Icon-Vorlage, bei kleinen Größen schwächer)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                  color: CGColor(gray: 0, alpha: size >= 64 ? 0.3 : 0.15))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Bild in die Form schneiden
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(sourceCG, in: body)
    ctx.restoreGState()

    // Feine Innenkante für Tiefe
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    ctx.setLineWidth(max(1, 2 * scale))
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let px = base * factor
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: px).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(factor)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("✓ \(images.count) Icon-Größen in \(outDir.path)")
