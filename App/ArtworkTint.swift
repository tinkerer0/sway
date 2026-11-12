import SwiftUI
import UIKit

/// 표지에서 뽑은 두 색. 블랙 테마가 재생 화면 배경·미니플레이어·재생 중 표시에 쓴다.
struct ArtworkTint: Equatable {
    /// 재생 화면 배경에 쓰는 어두운 대표색.
    var backdrop: Color
    /// 검정 위에서 보이도록 채도·밝기를 맞춘 선명한 색.
    var highlight: Color
    /// 표지가 없거나 무채색에 가까워 뽑을 색이 없을 때.
    static let neutral = ArtworkTint(backdrop: Color(red: 0.24, green: 0.24, blue: 0.27), highlight: .white)

    /// 표지를 화면과 같은 방식(가운데 정사각형)으로 잘라 40×40으로 줄인 뒤,
    /// 색상을 18구간으로 나눠 채도가 높은 화소가 가장 많이 몰린 구간의 색을 고른다.
    static func extract(from data: Data) -> ArtworkTint? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let scale = CGFloat(side) / max(1, min(width, height))
            let size = CGSize(width: width * scale, height: height * scale)
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        guard drawn else { return nil }
        var bins = [(weight: Double, red: Double, green: Double, blue: Double)](repeating: (0, 0, 0, 0), count: 18)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]), green = Double(pixels[index + 1]), blue = Double(pixels[index + 2])
            let high = max(red, green, blue), chroma = high - min(red, green, blue)
            if high < 45 || chroma < 30 { continue }
            let saturation = chroma / high, weight = saturation * saturation * high / 255
            let bin = Int(hue(red, green, blue, high, chroma) / 20) % 18
            bins[bin].weight += weight; bins[bin].red += red * weight; bins[bin].green += green * weight; bins[bin].blue += blue * weight
        }
        guard let best = bins.max(by: { $0.weight < $1.weight }), best.weight >= 3 else { return .neutral }
        let red = best.red / best.weight, green = best.green / best.weight, blue = best.blue / best.weight
        let high = max(red, green, blue), chroma = high - min(red, green, blue)
        guard chroma > 0 else { return .neutral }
        let angle = hue(red, green, blue, high, chroma)
        return ArtworkTint(backdrop: color(hue: angle, saturation: min(0.62, max(0.3, chroma / high * 0.8)), lightness: 0.3),
                           highlight: color(hue: angle, saturation: 0.88, lightness: 0.64))
    }
    /// 0..<360.
    private static func hue(_ red: Double, _ green: Double, _ blue: Double, _ high: Double, _ chroma: Double) -> Double {
        let sector: Double
        if high == red { sector = ((green - blue) / chroma + 6).truncatingRemainder(dividingBy: 6) }
        else if high == green { sector = (blue - red) / chroma + 2 }
        else { sector = (red - green) / chroma + 4 }
        return sector * 60
    }
    private static func color(hue: Double, saturation: Double, lightness: Double) -> Color {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let second = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1)), base = lightness - chroma / 2
        let parts: (Double, Double, Double)
        switch hue {
        case ..<60: parts = (chroma, second, 0)
        case ..<120: parts = (second, chroma, 0)
        case ..<180: parts = (0, chroma, second)
        case ..<240: parts = (0, second, chroma)
        case ..<300: parts = (second, 0, chroma)
        default: parts = (chroma, 0, second)
        }
        return Color(red: parts.0 + base, green: parts.1 + base, blue: parts.2 + base)
    }
}

/// 표지 주소별로 뽑은 색을 기억한다. 표지 화면이 이미 받은 이미지는 URLCache에서 다시 읽으므로 데이터를 더 쓰지 않는다.
@MainActor @Observable final class ArtworkTintStore {
    static let shared = ArtworkTintStore()
    private var tints: [URL: ArtworkTint] = [:]
    @ObservationIgnored private var loading: Set<URL> = []
    func tint(for url: URL?) -> ArtworkTint { url.flatMap { tints[$0] } ?? .neutral }
    func load(_ url: URL?) async {
        guard let url, tints[url] == nil, loading.insert(url).inserted else { return }
        defer { loading.remove(url) }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let tint = await Task.detached(priority: .utility) { ArtworkTint.extract(from: data) }.value
        if tints.count > 300 { tints.removeAll() }
        if let tint { tints[url] = tint }
    }
}

/// 블랙 테마 재생 화면 배경: 표지 대표색에서 검정으로 내려간다. 곡이 바뀌면 색이 천천히 넘어간다.
struct ArtworkBackdrop: View {
    let url: URL?
    @Environment(\.swayPalette) private var palette
    var body: some View {
        let tint = ArtworkTintStore.shared.tint(for: url)
        LinearGradient(stops: [.init(color: tint.backdrop, location: 0), .init(color: palette.backdrop, location: 0.94)], startPoint: .top, endPoint: .bottom)
            .animation(.easeInOut(duration: 1), value: tint)
            .ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
            .task(id: url) { await ArtworkTintStore.shared.load(url) }
    }
}
