import SwiftUI

/// 형태·화면 모드와 별개로 저장한다. 자동은 기존 테마의 기본색을 유지하는 호환값이다.
enum SwayColor: String, CaseIterable, Identifiable {
    case automatic, monochrome, blue, mint, violet, rose, amber
    var id: String { rawValue }
    static func resolve(_ value: String) -> Self { Self(rawValue: value) ?? .automatic }
    var name: String {
        switch self {
        case .automatic: return "테마 기본색"
        case .monochrome: return "흑백"
        case .blue: return "블루"
        case .mint: return "민트"
        case .violet: return "라벤더"
        case .rose: return "로즈"
        case .amber: return "앰버"
        }
    }
}

struct SwayPalette {
    let color: SwayColor
    let customized: Bool
    /// 블랙 테마 기본색은 색상 설정의 흑백보다 더 어두운 검정을 쓴다.
    private let noir: Bool
    init(theme: SwayTheme = .standard, selection: SwayColor = .automatic) {
        customized = selection != .automatic
        noir = theme == .noir && selection == .automatic
        if selection != .automatic { color = selection }
        else {
            switch theme {
            case .standard: color = .monochrome
            case .glass: color = .blue
            case .tech, .pixel: color = .mint
            case .clay: color = .violet
            case .noir: color = .monochrome
            }
        }
    }
    private var values: (accent: (UInt32, UInt32), backdrop: (UInt32, UInt32), surface: (UInt32, UInt32)) {
        if noir { return ((0xFFFFFF, 0xFFFFFF), (0x0A0A0A, 0x0A0A0A), (0x18181B, 0x18181B)) }
        switch color {
        case .automatic, .monochrome: return ((0x202124, 0xF2F2F4), (0xF2F2F4, 0x111113), (0xFFFFFF, 0x2A2A2F))
        case .blue: return ((0x285C98, 0xA9CEFF), (0xE8EFF8, 0x141E2A), (0xF7FAFF, 0x2C3C50))
        case .mint: return ((0x1C665B, 0x9ADFD0), (0xE7F0ED, 0x14231F), (0xF5FCF8, 0x2B423A))
        case .violet: return ((0x68438E, 0xDBBEFF), (0xEFE8F4, 0x231C2D), (0xFCF7FF, 0x433650))
        case .rose: return ((0x96415F, 0xFFBDD1), (0xF6E9EE, 0x2A1A22), (0xFFF8FB, 0x503441))
        case .amber: return ((0x8B5420, 0xF3C492), (0xF4EDE3, 0x282015), (0xFFF9F1, 0x493E2B))
        }
    }
    var accent: Color { adaptive(values.accent) }
    var backdrop: Color { adaptive(values.backdrop) }
    var surface: Color { adaptive(values.surface) }
    var playFill: Color { accent }
    var playForeground: Color { adaptive((0xFFFFFF, 0x17191B)) }
    /// 생성된 장식 에셋의 조명·질감은 보존하고 사용자 지정 색만 곱한다. 앨범 표지에는 적용하지 않는다.
    var illustrationTint: Color { color == .monochrome ? .white : adaptive((values.accent.1, values.accent.1)) }
    var wash: LinearGradient { LinearGradient(colors: [surface, backdrop], startPoint: .topLeading, endPoint: .bottomTrailing) }
    private func adaptive(_ values: (UInt32, UInt32)) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? values.1 : values.0
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = SwayPalette() }
extension EnvironmentValues {
    var swayPalette: SwayPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
