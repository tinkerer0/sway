import SwiftUI

@main struct SwayApp: App {
    @State private var library: LibraryStore
    @State private var playback: PlaybackController
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // 썸네일과 YouTube player JS(압축 약 0.8 MB, 1년 캐시 헤더)를 디스크에 재사용해 앱을 켤 때마다 다시 받지 않는다.
        // watch 페이지는 no-store라 저장되지 않는다. 음원은 AVPlayer가 받으며 URLCache를 쓰지 않아 영구 보관하지 않는다.
        URLCache.shared = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024, directory: nil)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // 시험은 매번 빈 음원 캐시에서 시작한다. 한도는 저장하지 않고 이번 실행에만 쓴다.
        if arguments.contains("--uitesting") && arguments.contains("--reset-fixture") { AudioCache.shared.removeAll() }
        if let index = arguments.firstIndex(of: "--audio-cache-limit-mb"), index + 1 < arguments.count, let mb = Int(arguments[index + 1]) {
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain[AudioCache.limitKey] = mb
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }
        #endif
        let store = LibraryStore()
        _library = State(initialValue: store)
        #if DEBUG
        let delayed = ProcessInfo.processInfo.arguments.contains("--slow-audio-start")
        let resolver = AudioResolver(loader: { id in
            if delayed { try await Task.sleep(nanoseconds: 3_000_000_000) }
            return try await YouTubeAudioSource.resolve(id)
        })
        _playback = State(initialValue: PlaybackController(library: store, resolver: resolver))
        #else
        _playback = State(initialValue: PlaybackController(library: store))
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(library).environment(playback)
                // 화면은 블랙 하나로 고정한다. 예전에 저장된 테마·색상·화면 모드 값은 읽지 않는다.
                .environment(\.swayTheme, .noir)
                .environment(\.swayPalette, SwayPalette(theme: .noir))
                .font(SwayTheme.noir.bodyFont)
                .tint(SwayPalette(theme: .noir).accent)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: playback.setForeground(true)
                    case .background: playback.setForeground(false)
                    case .inactive: playback.checkpoint()
                    @unknown default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @State private var showPlayer = false
    @State private var showSettings = false
    @State private var searchEditing = false
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    var body: some View {
        @Bindable var library = library
        @Bindable var playback = playback
        VStack(spacing: 0) {
            NavigationStack {
                SearchView(openSettings: { showSettings = true }, onEditingChange: { searchEditing = $0 })
            }
            // 실제 높이를 나눠 보관함·검색 결과가 미니플레이어 뒤로 가려지지 않게 한다.
            bottomDock
        }
        .background { ThemeBackground() }
        .sheet(isPresented: $showPlayer) { PlayerView().preferredColorScheme(.dark).presentationDragIndicator(.visible) }
        .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(.dark).presentationDragIndicator(.visible) }
        .alert("보관함", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("확인", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .alert("재생 안내", isPresented: Binding(get: { playback.message != nil }, set: { if !$0 { playback.message = nil } })) {
            Button("확인", role: .cancel) { playback.message = nil }
        } message: { Text(playback.message ?? "") }
    }
    @ViewBuilder private var bottomDock: some View {
        if !searchEditing { miniPlayer }
    }
    @ViewBuilder private var miniPlayer: some View {
        if let track = playback.current {
            VStack(spacing: 0) {
              HStack(spacing: 12) {
                Button { showPlayer = true } label: {
                    HStack(spacing: 12) {
                        Artwork(track: track, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(theme.headlineFont).lineLimit(1)
                            Text(track.artist).font(theme.captionFont).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("miniPlayer")
                    .accessibilityLabel("재생 화면 열기, \(track.title)")
                Button { playback.toggle() } label: {
                    if playback.isLoading { ProgressView().frame(width: 28, height: 28) }
                    else { Image(systemName: playback.showsPause ? "pause.fill" : "play.fill").font(.title3) }
                }.frame(width: 44, height: 44).accessibilityLabel(playback.showsPause ? "일시정지" : "재생")
                    .accessibilityIdentifier("miniPlayPause")
                Button { playback.next() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                    .frame(width: 44, height: 44).accessibilityLabel("다음 곡")
              }.padding(.horizontal, 12).padding(.vertical, 10)
              GeometryReader { geometry in
                  Capsule().fill(palette.accent.opacity(0.16))
                  Capsule().fill(palette.accent).frame(width: geometry.size.width * min(1, max(0, playback.elapsed / max(1, playback.duration))))
              }.frame(height: 2).padding(.horizontal, 16).padding(.bottom, 8).accessibilityHidden(true)
            }.modifier(MiniPlayerSurface(artworkURL: track.artworkURL))
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6)
        }
    }
}

/// 블랙 테마의 미니플레이어는 재생 중인 곡의 표지 대표색을 면으로 쓴다. 다른 테마는 기존 표면 그대로다.
private struct MiniPlayerSurface: ViewModifier {
    @Environment(\.swayTheme) private var theme
    let artworkURL: URL?
    func body(content: Content) -> some View {
        if theme == .noir {
            let tint = ArtworkTintStore.shared.tint(for: artworkURL)
            content.background(tint.backdrop, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
                .animation(.easeInOut(duration: 1), value: tint)
                .task(id: artworkURL) { await ArtworkTintStore.shared.load(artworkURL) }
        } else {
            content.themeSurface(floating: true)
        }
    }
}

/// 곡 행의 바탕. 블랙 테마는 카드 없이 여백으로만 나눈다.
struct TrackRowSurface: ViewModifier {
    @Environment(\.swayTheme) private var theme
    func body(content: Content) -> some View {
        if theme == .noir { content.padding(.vertical, 7) }
        else { content.padding(12).themeSurface(radius: theme.controlRadius).padding(.vertical, 6) }
    }
}

struct Artwork: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    var track: MusicCore.Track
    var size: CGFloat
    var body: some View {
        AsyncImage(url: track.artworkURL) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack { palette.surface; ThemeIllustration(size: size * 0.85) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size > 100 ? theme.artworkRadius : min(theme.artworkRadius, 8)))
            .accessibilityHidden(true)
    }
}

import MusicCore
struct TrackRow: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(PlaybackController.self) private var playback: PlaybackController?
    let track: Track
    let action: () -> Void
    var body: some View {
        let playing = theme == .noir && playback?.current?.id == track.id
        let highlight = ArtworkTintStore.shared.tint(for: track.artworkURL).highlight
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Artwork(track: track, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(theme.bodyFont).lineLimit(2).foregroundStyle(playing ? AnyShapeStyle(highlight) : AnyShapeStyle(.primary))
                        HStack(spacing: 5) {
                            if playing { Image(systemName: "waveform").font(.caption2.weight(.semibold)).foregroundStyle(highlight).accessibilityHidden(true) }
                            Text([track.artist, track.durationLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(theme.captionFont).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(track.title), \(track.artist), 재생")
            TrackMenu(track: track)
        }.modifier(TrackRowSurface())
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

struct TrackMenu: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @State private var adding = false
    var body: some View {
        Menu {
            if library.contains(track) {
                Label("보관함에 있음", systemImage: "checkmark")
            } else { Button("보관함에 추가", systemImage: "plus") { library.save(track) } }
            Button("재생목록에 추가", systemImage: "text.badge.plus") { adding = true }
            Button("알고리즘 시작", systemImage: "sparkles") { playback.startMix(track) }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel("\(track.title) 메뉴")
            .sheet(isPresented: $adding) { AddToPlaylistView(track: track) }
    }
}
