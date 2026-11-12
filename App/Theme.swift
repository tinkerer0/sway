import SwiftUI

/// 화면은 블랙 하나로 고정한다(2026-11-11). 나머지 테마 값은 고르는 화면 없이 코드에만 남아 있다.
enum SwayTheme: String, CaseIterable, Identifiable {
    case standard, glass, tech, pixel, clay, noir
    var id: String { rawValue }
    var name: String {
        switch self {
        case .standard: return "기본"
        case .glass: return "글래스"
        case .tech: return "테크"
        case .pixel: return "레트로"
        case .clay: return "클레이"
        case .noir: return "블랙"
        }
    }
    var detail: String {
        switch self {
        case .standard: return "단정한 여백과 간결한 형태"
        case .glass: return "투명한 깊이와 부드러운 빛"
        case .tech: return "정밀한 선과 은은한 발광"
        case .pixel: return "픽셀 글꼴과 선명한 테두리"
        case .clay: return "폭신한 형태와 입체적인 질감"
        case .noir: return "검정 바탕과 표지에서 가져온 색"
        }
    }
    var illustration: String { "Theme-\(rawValue)" }
    var cornerRadius: CGFloat { switch self { case .standard: return 22; case .glass: return 28; case .tech: return 12; case .pixel: return 3; case .clay: return 30; case .noir: return 12 } }
    var controlRadius: CGFloat { switch self { case .standard: return 14; case .glass: return 24; case .tech: return 8; case .pixel: return 2; case .clay: return 22; case .noir: return 10 } }
    var artworkRadius: CGFloat { switch self { case .pixel: return 2; case .tech: return 8; case .clay: return 28; case .noir: return 8; default: return 20 } }
    var titleFont: Font {
        switch self {
        case .pixel: return .custom("Galmuri11-Regular", size: 26, relativeTo: .title2)
        case .tech: return .system(.title2, design: .monospaced, weight: .semibold)
        case .clay: return .system(.title2, design: .rounded, weight: .bold)
        case .noir: return .system(.title2, weight: .heavy)
        default: return .title2.bold()
        }
    }
    var headlineFont: Font {
        switch self {
        case .pixel: return .custom("Galmuri11-Regular", size: 16, relativeTo: .headline)
        case .tech: return .system(.headline, design: .monospaced)
        case .clay: return .system(.headline, design: .rounded)
        default: return .headline
        }
    }
    var captionFont: Font { self == .pixel ? .custom("Galmuri11-Regular", size: 13, relativeTo: .caption) : self == .tech ? .system(.caption, design: .monospaced) : .caption }
    var bodyFont: Font {
        switch self {
        case .pixel: return .custom("Galmuri11-Regular", size: 16, relativeTo: .body)
        case .tech: return .system(.body, design: .monospaced)
        case .clay: return .system(.body, design: .rounded)
        default: return .body
        }
    }

}
private struct ThemeKey: EnvironmentKey { static let defaultValue = SwayTheme.standard }
extension EnvironmentValues {
    var swayTheme: SwayTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct ThemeIllustration: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    var size: CGFloat
    var body: some View {
        if theme == .noir {
            Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(theme.illustration).resizable().interpolation(theme == .pixel ? .none : .high)
                .scaledToFit().saturation(palette.customized ? 0 : 1)
                .colorMultiply(palette.customized ? palette.illustrationTint : .white)
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct ThemeBackground: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            palette.backdrop
            if theme == .glass, !reduceTransparency {
                GeometryReader { geometry in
                    Image("Glass-Caustics").resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .blendMode(scheme == .dark ? .screen : .multiply)
                        .opacity(scheme == .dark ? 0.09 : 0.38)
                }
                RadialGradient(colors: [palette.accent.opacity(scheme == .dark ? 0.14 : 0.12), .clear], center: .topTrailing, startRadius: 10, endRadius: 440)
            } else if theme == .clay {
                RadialGradient(colors: [palette.surface, .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            } else if theme == .tech {
                Canvas { context, size in
                    var path = Path()
                    for x in stride(from: 0.0, through: size.width, by: 28) { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
                    for y in stride(from: 0.0, through: size.height, by: 28) { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
                    context.stroke(path, with: .color(palette.accent.opacity(0.035)), lineWidth: 0.5)
                }
            }
        }.ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// Liquid Glass는 떠 있는 조작부에만 사용하고 콘텐츠 카드에는 표준 material을 쓴다.
private struct ThemeSurface: ViewModifier {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var floating: Bool
    var radius: CGFloat?
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? theme.cornerRadius, style: .continuous)
        switch theme {
        case .standard:
            content.background(palette.surface, in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.3 : 0.05), lineWidth: 0.5) }
        case .glass:
            if floating, !reduceTransparency, #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(palette.accent.opacity(0.08)).interactive(), in: shape)
            } else if reduceTransparency {
                content.background(palette.surface, in: shape).overlay { shape.strokeBorder(palette.accent.opacity(0.25), lineWidth: 1) }
            } else {
                content.background {
                    // 콘텐츠는 표준 material을 유지하되 배경을 가리던 두꺼운 프로스트를 줄인다.
                    shape.fill(contrast == .increased ? .regularMaterial : .ultraThinMaterial)
                        .opacity(contrast == .increased ? 1 : scheme == .dark ? 0.36 : 0.28)
                    shape.fill(LinearGradient(stops: [
                        .init(color: .white.opacity(scheme == .dark ? 0.12 : 0.22), location: 0),
                        .init(color: .white.opacity(0.015), location: 0.28),
                        .init(color: .clear, location: 0.62),
                        .init(color: palette.accent.opacity(0.045), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.055), radius: 10, y: 5)
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(stops: [
                        .init(color: .white.opacity(scheme == .dark ? 0.65 : 0.98), location: 0),
                        .init(color: .white.opacity(0.08), location: 0.45),
                        .init(color: .white.opacity(scheme == .dark ? 0.3 : 0.8), location: 0.8),
                        .init(color: palette.accent.opacity(0.2), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.3)
                    shape.inset(by: 2).strokeBorder(LinearGradient(colors: [.white.opacity(0.04), .clear, .white.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                }
            }
        case .tech:
            content.background {
                shape.fill(palette.surface).shadow(color: palette.accent.opacity(scheme == .dark ? 0.08 : 0.02), radius: 12, y: 2)
            }.overlay { shape.strokeBorder(palette.accent.opacity(contrast == .increased ? 0.6 : 0.26), lineWidth: 1) }
        case .pixel:
            content.background {
                shape.fill(palette.surface).shadow(color: palette.accent.opacity(0.28), radius: 0, x: 4, y: 4)
            }.overlay { shape.strokeBorder(palette.accent.opacity(0.75), lineWidth: 2) }
        case .clay:
            content.background {
                shape.fill(palette.wash
                    .shadow(.inner(color: .white.opacity(scheme == .dark ? 0.22 : 0.95), radius: 4, x: 4, y: 5))
                    .shadow(.inner(color: .black.opacity(scheme == .dark ? 0.32 : 0.12), radius: 7, x: -6, y: -7)))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.12), radius: 9, x: 5, y: 8)
                    .shadow(color: .white.opacity(scheme == .dark ? 0.025 : 0.75), radius: 5, x: -4, y: -4)
            }
            .overlay { shape.inset(by: 1).strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.16 : 0.7), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5) }
        case .noir:
            // 테두리·그림자 없이 면의 밝기 차이로만 구분한다.
            content.background(floating ? AnyShapeStyle(Color.white.opacity(contrast == .increased ? 0.2 : 0.1)) : AnyShapeStyle(palette.surface), in: shape)
        }
    }
}
extension View {
    func themeSurface(floating: Bool = false, radius: CGFloat? = nil) -> some View { modifier(ThemeSurface(floating: floating, radius: radius)) }
    func themeControl(selected: Bool = false) -> some View { modifier(ThemeControl(selected: selected)) }
    func themedList() -> some View { scrollContentBackground(.hidden).background { ThemeBackground() } }
}

/// 입력·선택·짧은 동작도 콘텐츠와 같은 테마 토큰을 사용한다.
private struct ThemeControl: ViewModifier {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    var selected: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius)
        content.background(selected ? palette.accent.opacity(0.14) : .clear, in: shape)
            .themeSurface(floating: true, radius: theme.controlRadius)
            .overlay { if selected { shape.strokeBorder(palette.accent, lineWidth: theme == .pixel ? 2 : 1.5) } }
    }
}

struct ThemeButtonStyle: ButtonStyle {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(theme.headlineFont).padding(.horizontal, 16).frame(minHeight: 44)
            .contentShape(Rectangle()).themeControl()
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
    }
}

struct ThemeSettingsGroup<Content: View>: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(theme.captionFont).foregroundStyle(.secondary).padding(.horizontal, 8).accessibilityAddTraits(.isHeader) }
            VStack(spacing: 0) { content }.themeSurface()
        }
    }
}

struct ThemeSettingsRow: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    var title: String
    var symbol: String
    var detail: String? = nil
    var chevron = true
    var selected = false
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 32, height: 32)
                .background(palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: theme.controlRadius / 2))
                .accessibilityHidden(true)
            textLayout {
                Text(title).font(theme.bodyFont).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(detail).font(theme.captionFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(palette.accent).accessibilityHidden(true) }
            else if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }.padding(16).frame(minHeight: 56).contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(detail ?? "")
    }
    private var textLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
    }
}

private struct ThemeNavigation: ViewModifier {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    let title: String
    func body(content: Content) -> some View {
        content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Text(title).font(theme.headlineFont).accessibilityAddTraits(.isHeader) } }
    }
}
extension View {
    func themeNavigation(_ title: String) -> some View { modifier(ThemeNavigation(title: title)) }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @AppStorage(AudioCache.limitKey) private var cacheLimit = AudioCache.defaultLimitMB
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ThemeSettingsGroup(title: "재생") {
                        NavigationLink { StorageSettingsView() } label: {
                            ThemeSettingsRow(title: "다시 듣기용 저장", symbol: "internaldrive", detail: AudioCacheLimit.resolve(cacheLimit).name)
                        }.accessibilityIdentifier("storageSettings")
                    }
                    ThemeSettingsGroup(title: "앱 정보") {
                        NavigationLink { AboutView() } label: { ThemeSettingsRow(title: "Sway 정보", symbol: "info.circle") }
                        Divider().padding(.horizontal, 16)
                        NavigationLink { LicensesView() } label: { ThemeSettingsRow(title: "오픈소스 라이선스", symbol: "doc.text") }
                        Divider().padding(.horizontal, 16)
                        ThemeSettingsRow(title: "버전", symbol: "app.badge", detail: appVersion, chevron: false)
                    }
                }.buttonStyle(.plain).padding(20)
            }.background { ThemeBackground() }.themeNavigation("설정")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() }.font(theme.headlineFont) } }
        }
    }
    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
}

enum AudioCacheLimit: Int, CaseIterable, Identifiable {
    case off = 0, small = 500, standard = 1024, large = 2048
    var id: Int { rawValue }
    var name: String {
        switch self { case .off: "저장 안 함"; case .small: "500 MB"; case .standard: "1 GB"; case .large: "2 GB" }
    }
    static func resolve(_ value: Int) -> AudioCacheLimit { AudioCacheLimit(rawValue: value) ?? .standard }
}

struct StorageSettingsView: View {
    @Environment(\.swayTheme) private var theme
    @Environment(PlaybackController.self) private var playback
    @AppStorage(AudioCache.limitKey) private var limit = AudioCache.defaultLimitMB
    @State private var used: Int?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ThemeSettingsGroup {
                    ForEach(AudioCacheLimit.allCases) { option in
                        Button { limit = option.rawValue; trim(all: false) } label: {
                            ThemeSettingsRow(title: option.name, symbol: option == .off ? "nosign" : "internaldrive", chevron: false,
                                             selected: AudioCacheLimit.resolve(limit) == option)
                        }.accessibilityAddTraits(AudioCacheLimit.resolve(limit) == option ? .isSelected : [])
                            .accessibilityIdentifier("audioCache-\(option.rawValue)")
                        if option != AudioCacheLimit.allCases.last { Divider().padding(.horizontal, 16) }
                    }
                }
                ThemeSettingsGroup {
                    ThemeSettingsRow(title: "사용 중", symbol: "chart.bar", detail: usedText, chevron: false)
                    Divider().padding(.horizontal, 16)
                    Button { trim(all: true) } label: { ThemeSettingsRow(title: "저장된 음원 지우기", symbol: "trash", chevron: false) }
                        .accessibilityIdentifier("clearAudioCache")
                }
                Text("들은 곡을 이 iPhone에 남겨 다시 들을 때 데이터를 쓰지 않아요. 한도를 넘으면 오래 안 들은 곡부터 지우고, 저장 공간이 부족하면 iOS가 비울 수도 있어요. 지금 재생 중인 곡은 남겨 둬요.")
                    .font(theme.captionFont).foregroundStyle(.secondary).padding(.horizontal, 8)
            }.buttonStyle(.plain).padding(20)
        }.background { ThemeBackground() }.themeNavigation("다시 듣기용 저장")
            .task { await measure() }
    }
    private var usedText: String {
        used.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "계산 중"
    }
    private func trim(all: Bool) {
        let keep = Set([playback.current?.id].compactMap { $0 })
        Task {
            await Task.detached(priority: .userInitiated) {
                if all { AudioCache.shared.removeAll(protecting: keep) } else { AudioCache.shared.enforceLimit(protecting: keep) }
            }.value
            await measure()
        }
    }
    private func measure() async {
        used = await Task.detached(priority: .utility) { AudioCache.shared.totalBytes }.value
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            ThemeSettingsGroup {
                NavigationLink { LicenseText(name: "ThirdPartyNotices", title: "YouTubeKit") } label: { ThemeSettingsRow(title: "YouTubeKit", symbol: "play.rectangle") }
                Divider().padding(.horizontal, 16)
                NavigationLink { LicenseText(name: "Galmuri-License", title: "Galmuri11") } label: { ThemeSettingsRow(title: "Galmuri11", symbol: "textformat") }
            }.buttonStyle(.plain).padding(20)
        }.background { ThemeBackground() }.themeNavigation("라이선스")
    }
}
private struct LicenseText: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    let name: String
    let title: String
    var body: some View {
        ScrollView { Text(notice).font(theme.bodyFont).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20).themeSurface().padding(20) }
            .background { ThemeBackground() }.themeNavigation(title)
    }
    private var notice: String {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}
