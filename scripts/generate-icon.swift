import AppKit
import Foundation

// 앱 아이콘: 재생 중인 곡 옆에 뜨는 표시와 같은 막대 다섯 개. 색은 앱 안에 있는 것만 쓴다.
// 바탕은 표지 없는 재생 화면의 회색(0x3D3D45)에서 앱 바탕 검정(0x0A0A0A)으로 내려간다. 모서리 마스크는 iOS가 적용한다.
// 사용: swift scripts/generate-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
// 틴트 모드는 iOS가 색을 입히므로 단색 검정 바탕을 쓴다.
for (appearance, top) in [("", 0x3D3D45), ("Dark", 0x3D3D45), ("Tinted", 0x0A0A0A)] {
    let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSGradient(colors: [color(0x0A0A0A), color(0x0A0A0A), color(top)], atLocations: [0, 0.12, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 90)
    NSColor.white.setFill()
    let heights: [CGFloat] = [220, 430, 600, 340, 500], width: CGFloat = 84, gap: CGFloat = 46
    var x = (CGFloat(size) - (width * 5 + gap * 4)) / 2
    for height in heights {
        NSBezierPath(roundedRect: NSRect(x: x, y: (CGFloat(size) - height) / 2, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
        x += width + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    let target = appearance.isEmpty ? output : output.deletingLastPathComponent().appendingPathComponent("AppIcon\(appearance).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: target)
}
