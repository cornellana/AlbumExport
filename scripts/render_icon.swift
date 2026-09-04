#!/usr/bin/env swift
//
// Genera el icono de AlbumExport: una pila de fotos saliendo hacia una flecha,
// con la fila de etiquetas de color y una estrella de valoración. Estilo macOS:
// forma de rectángulo redondeado con márgenes transparentes (macOS no aplica
// máscara a los iconos, a diferencia de iOS).
//
// Se dibuja con CoreGraphics puro porque NSGraphicsContext no funciona de forma
// fiable fuera de una app de AppKit. Exporta los diez tamaños del appiconset de
// macOS y su Contents.json.
//
// Uso: swift scripts/render_icon.swift AlbumExport/Assets.xcassets/AppIcon.appiconset
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset"
let colorSpace = CGColorSpaceCreateDeviceRGB()

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

// Con canal alfa: el icono de macOS lleva márgenes transparentes.
guard let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("No se pudo crear el contexto de dibujo")
}

// MARK: - Forma base (rectángulo redondeado de macOS: 824 px con radio ~185)

let inset = 100.0
let plate = CGRect(x: inset, y: inset, width: Double(side) - inset * 2, height: Double(side) - inset * 2)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: color(0, 0, 0, 0.35))
context.addPath(platePath)
context.setFillColor(color(0.10, 0.12, 0.30))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(platePath)
context.clip()
let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0.13, 0.09, 0.42), color(0.10, 0.32, 0.58), color(0.05, 0.58, 0.62)] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
context.drawLinearGradient(background, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

// Brillo suave en la parte superior.
let gloss = CGGradient(colorsSpace: colorSpace, colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0.0)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gloss, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.midY), options: [])

// MARK: - Pila de fotos

func drawCard(center: CGPoint, size: CGSize, angle: Double, front: Bool) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle * .pi / 180)
    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let path = CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil)
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0, 0, 0, 0.30))
    context.addPath(path)
    context.setFillColor(color(0.98, 0.98, 0.99))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    if front {
        // Paisaje dentro de la foto: cielo, sol y montañas.
        let photo = rect.insetBy(dx: 26, dy: 26)
        context.saveGState()
        context.addPath(CGPath(roundedRect: photo, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.clip()
        let sky = CGGradient(colorsSpace: colorSpace, colors: [color(0.99, 0.62, 0.30), color(0.36, 0.66, 0.95)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: photo.midX, y: photo.minY), end: CGPoint(x: photo.midX, y: photo.maxY), options: [])
        context.setFillColor(color(1.0, 0.85, 0.35))
        let sunRadius = 52.0
        context.fillEllipse(in: CGRect(x: photo.maxX - 150 - sunRadius, y: photo.maxY - 140 - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
        let mountains = CGMutablePath()
        mountains.move(to: CGPoint(x: photo.minX, y: photo.minY))
        mountains.addLine(to: CGPoint(x: photo.minX, y: photo.minY + 120))
        mountains.addLine(to: CGPoint(x: photo.minX + 140, y: photo.minY + 260))
        mountains.addLine(to: CGPoint(x: photo.minX + 250, y: photo.minY + 150))
        mountains.addLine(to: CGPoint(x: photo.minX + 360, y: photo.minY + 300))
        mountains.addLine(to: CGPoint(x: photo.maxX, y: photo.minY + 110))
        mountains.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        mountains.closeSubpath()
        context.addPath(mountains)
        context.setFillColor(color(0.12, 0.35, 0.32))
        context.fillPath()
        context.restoreGState()
    }
    context.restoreGState()
}

let cardSize = CGSize(width: 430, height: 330)
let stackCenter = CGPoint(x: 420, y: 560)
drawCard(center: CGPoint(x: stackCenter.x - 30, y: stackCenter.y + 26), size: cardSize, angle: 10, front: false)
drawCard(center: CGPoint(x: stackCenter.x - 12, y: stackCenter.y + 12), size: cardSize, angle: 4, front: false)
drawCard(center: stackCenter, size: cardSize, angle: -4, front: true)

// MARK: - Flecha de exportación

let arrow = CGMutablePath()
let ax = 690.0, ay = 560.0
arrow.move(to: CGPoint(x: ax, y: ay + 50))
arrow.addLine(to: CGPoint(x: ax + 90, y: ay + 50))
arrow.addLine(to: CGPoint(x: ax + 90, y: ay + 120))
arrow.addLine(to: CGPoint(x: ax + 230, y: ay))
arrow.addLine(to: CGPoint(x: ax + 90, y: ay - 120))
arrow.addLine(to: CGPoint(x: ax + 90, y: ay - 50))
arrow.addLine(to: CGPoint(x: ax, y: ay - 50))
arrow.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0, 0, 0, 0.35))
context.addPath(arrow)
context.setFillColor(color(1.0, 0.72, 0.18))
context.setLineJoin(.round)
context.setLineWidth(22)
context.setStrokeColor(color(1.0, 0.72, 0.18))
context.strokePath()
context.addPath(arrow)
context.fillPath()
context.restoreGState()

// MARK: - Estrella y etiquetas de color

func starPath(center: CGPoint, radius: Double) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<10 {
        let r = i % 2 == 0 ? radius : radius * 0.45
        let angle = Double(i) * .pi / 5 + .pi / 2
        let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

let rowY = 250.0
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: color(0, 0, 0, 0.3))
context.addPath(starPath(center: CGPoint(x: 250, y: rowY), radius: 58))
context.setFillColor(color(1.0, 0.85, 0.25))
context.fillPath()
let dotColors: [CGColor] = [
    color(0.93, 0.26, 0.24), color(0.98, 0.58, 0.16), color(0.98, 0.84, 0.22),
    color(0.30, 0.78, 0.36), color(0.26, 0.55, 0.96),
]
for (index, dot) in dotColors.enumerated() {
    let cx = 400.0 + Double(index) * 96
    context.setFillColor(dot)
    context.fillEllipse(in: CGRect(x: cx - 34, y: rowY - 34, width: 68, height: 68))
}
context.restoreGState()
context.restoreGState() // clip del plato

// MARK: - Exportación en todos los tamaños

guard let master = context.makeImage() else { fatalError("No se pudo generar la imagen") }
let directory = URL(fileURLWithPath: outputDirectory)
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func write(_ image: CGImage, pixels: Int, filename: String) {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let scaled = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(filename) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("No se pudo escribir \(filename)")
    }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("No se pudo escribir \(filename)") }
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = scale == 1 ? "icon_\(points).png" : "icon_\(points)@2x.png"
        write(master, pixels: points * scale, filename: filename)
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: directory.appendingPathComponent("Contents.json"))
print("Icono generado en \(directory.path) (\(images.count) tamaños)")
