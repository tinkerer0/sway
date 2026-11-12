import SwiftUI
import MusicCore
import AVKit

struct PlayerView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Double = 0
    @State private var scrubbing = false
    @State private var showQueue = false
    var body: some View {
        NavigationStack {
            ScrollView {
                if let track = playback.current, theme == .noir {
                    noirPlayer(track)
                } else if let track = playback.current {
                    VStack(spacing: 26) {
                        Artwork(track: track, size: 260)
                            .padding(theme == .standard || theme == .glass ? 0 : 8).themeSurface()
                            .shadow(color: .black.opacity(0.12), radius: theme == .pixel ? 0 : 16, y: 8).padding(.top, 12).padding(.bottom, 4)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(track.title).font(theme.titleFont).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("playerTitle")
                                Text(track.artist).font(.body).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            TrackMenu(track: track)
                        }
                        VStack(spacing: 5) {
                            Slider(value: $position, in: 0...max(playback.duration, 1)) { editing in
                                scrubbing = editing; if !editing { playback.seek(to: position) }
                            }.disabled(playback.duration <= 0).accessibilityLabel("재생 위치")
                            HStack { Text(time(position)).accessibilityIdentifier("elapsed"); Spacer(); Text(time(playback.duration)).accessibilityIdentifier("duration") }
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 38) {
                            Button { playback.previous() } label: { Image(systemName: "backward.end.fill").font(.title) }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("이전 곡")
                            Button { playback.toggle() } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: theme == .pixel ? 4 : theme == .tech ? 18 : 38)
                                        .fill(palette.playFill.gradient).frame(width: 76, height: 76)
                                        .shadow(color: palette.accent.opacity(theme == .tech || theme == .clay ? 0.22 : 0), radius: 12, y: 5)
                                    if playback.isLoading { ProgressView().tint(palette.playForeground) }
                                    else { Image(systemName: playback.showsPause ? "pause.fill" : "play.fill").font(.system(size: 30)).foregroundStyle(palette.playForeground) }
                                }
                            }.accessibilityLabel(playback.showsPause ? "일시정지" : "재생")
                                .accessibilityValue(playback.isLoading ? "로딩 중" : "")
                                .accessibilityIdentifier("playerPlayPause")
                            Button { playback.next() } label: { Image(systemName: "forward.end.fill").font(.title) }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("다음 곡").accessibilityIdentifier("playerNext")
                        }.buttonStyle(.plain)
                        modeLayout {
                            Button { playback.shuffle() } label: {
                                modeLabel("셔플", symbol: "shuffle")
                            }.disabled(playback.queue.remaining < 2)
                                .accessibilityIdentifier("playerShuffle")
                            Button { playback.cycleRepeat() } label: {
                                modeLabel("반복", symbol: playback.repeatMode == .one ? "repeat.1" : "repeat")
                            }.foregroundStyle(playback.repeatMode == .off ? Color.secondary : palette.accent)
                                .disabled(playback.mixActive).accessibilityLabel(repeatLabel)
                                .accessibilityIdentifier("playerRepeat")
                            Button {
                                playback.mixActive ? playback.stopMix() : playback.startMix(track)
                            } label: {
                                modeLabelLayout {
                                    ZStack {
                                        Image(systemName: "sparkles").opacity(playback.isMixLoading ? 0 : 1)
                                        if playback.isMixLoading { ProgressView().tint(palette.accent) }
                                    }.font(.system(size: 19, weight: .medium)).frame(height: 22)
                                    Text("알고리즘").font(theme.captionFont)
                                }.frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
                                    .background(playback.mixActive ? palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16)))
                            }.foregroundStyle(playback.mixActive ? palette.accent : Color.secondary)
                                .disabled(playback.isMixLoading)
                                .accessibilityLabel(playback.mixActive ? "알고리즘 끄기" : "알고리즘 켜기")
                                .accessibilityValue(playback.isMixLoading ? "곡을 불러오는 중" : playback.mixActive ? "켜짐" : "꺼짐")
                                .accessibilityHint("이 곡과 비슷한 음악 이어 듣기")
                                .accessibilityIdentifier("mixToggle")
                            Button { showQueue = true } label: {
                                modeLabel("대기열", symbol: "list.bullet")
                            }
                        }.padding(8).themeSurface(floating: true).foregroundStyle(.secondary).buttonStyle(.plain)
                        HStack {
                            Text(playback.mixActive ? "비슷한 음악 이어 듣는 중" : playback.bitrate > 0 ? "AAC · 약 \(Int((Double(playback.bitrate) / 1000).rounded())) kbps" : "오디오 스트리밍")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(); RoutePicker().frame(width: 40, height: 40).accessibilityLabel("재생 기기 선택")
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }
            }.background { if theme == .noir { ArtworkBackdrop(url: playback.current?.artworkURL) } else { ThemeBackground() } }
                .navigationTitle(theme == .noir ? "" : playback.mixActive ? "알고리즘" : "지금 재생 중").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("닫기", systemImage: "chevron.down") { dismiss() } } }
        }.onAppear { position = playback.elapsed }
            .onChange(of: playback.elapsed) { _, value in if !scrubbing { position = value } }
            .sheet(isPresented: $showQueue) {
                NavigationStack {
                    List {
                        ForEach(Array(playback.queue.tracks.enumerated()), id: \.offset) { index, track in
                            HStack {
                                if index == playback.queue.index { Image(systemName: "speaker.wave.2.fill").foregroundStyle(palette.accent) }
                                TrackRow(track: track) { playback.jump(to: index) }
                            }
                        }
                    }.themedList().navigationTitle("재생 대기열").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { showQueue = false } } }
                }
            }
    }
    /// 블랙 테마 재생 화면: 표지와 제목이 주인공이고, 조작부는 상자·글자 없이 기호만 둔다.
    private func noirPlayer(_ track: MusicCore.Track) -> some View {
        let highlight = ArtworkTintStore.shared.tint(for: track.artworkURL).highlight
        return VStack(spacing: 0) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncImage(url: track.artworkURL) { image in image.resizable().scaledToFill() } placeholder: {
                        ZStack { palette.surface; ThemeIllustration(size: 160) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.artworkRadius, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 22, y: 12)
                .scaleEffect(playback.showsPause || reduceMotion ? 1 : 0.86)
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: playback.showsPause)
                .accessibilityHidden(true).padding(.top, 6)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title).font(theme.titleFont).tracking(-0.4).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("playerTitle")
                    Text(track.artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                TrackMenu(track: track)
            }.padding(.top, 28)
            VStack(spacing: 4) {
                Slider(value: $position, in: 0...max(playback.duration, 1)) { editing in
                    scrubbing = editing; if !editing { playback.seek(to: position) }
                }.tint(.white).disabled(playback.duration <= 0).accessibilityLabel("재생 위치")
                HStack { Text(time(position)).accessibilityIdentifier("elapsed"); Spacer(); Text(time(playback.duration)).accessibilityIdentifier("duration") }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.top, 18)
            HStack(spacing: 0) {
                Button { playback.shuffle() } label: { Image(systemName: "shuffle").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }
                    .foregroundStyle(.secondary).disabled(playback.queue.remaining < 2)
                    .accessibilityLabel("셔플").accessibilityIdentifier("playerShuffle")
                Spacer(minLength: 0)
                Button { playback.previous() } label: { Image(systemName: "backward.end.fill").font(.title).frame(width: 52, height: 52) }.accessibilityLabel("이전 곡")
                Spacer(minLength: 0)
                Button { playback.toggle() } label: {
                    ZStack {
                        Circle().fill(palette.playFill).frame(width: 72, height: 72)
                        if playback.isLoading { ProgressView().tint(palette.playForeground) }
                        else { Image(systemName: playback.showsPause ? "pause.fill" : "play.fill").font(.system(size: 28)).foregroundStyle(palette.playForeground) }
                    }
                }.accessibilityLabel(playback.showsPause ? "일시정지" : "재생")
                    .accessibilityValue(playback.isLoading ? "로딩 중" : "")
                    .accessibilityIdentifier("playerPlayPause")
                Spacer(minLength: 0)
                Button { playback.next() } label: { Image(systemName: "forward.end.fill").font(.title).frame(width: 52, height: 52) }
                    .accessibilityLabel("다음 곡").accessibilityIdentifier("playerNext")
                Spacer(minLength: 0)
                Button { playback.cycleRepeat() } label: {
                    Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                }.foregroundStyle(playback.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(highlight))
                    .disabled(playback.mixActive).accessibilityLabel(repeatLabel).accessibilityIdentifier("playerRepeat")
            }.padding(.top, 14).padding(.horizontal, -10)
            HStack(spacing: 4) {
                RoutePicker().frame(width: 44, height: 44).accessibilityLabel("재생 기기 선택")
                Spacer()
                Button { playback.mixActive ? playback.stopMix() : playback.startMix(track) } label: {
                    ZStack {
                        Image(systemName: "sparkles").font(.system(size: 19, weight: .medium)).opacity(playback.isMixLoading ? 0 : 1)
                        if playback.isMixLoading { ProgressView().tint(highlight) }
                    }.frame(width: 44, height: 44).contentShape(Rectangle())
                }.foregroundStyle(playback.mixActive ? AnyShapeStyle(highlight) : AnyShapeStyle(.secondary)).disabled(playback.isMixLoading)
                    .accessibilityLabel(playback.mixActive ? "알고리즘 끄기" : "알고리즘 켜기")
                    .accessibilityValue(playback.isMixLoading ? "곡을 불러오는 중" : playback.mixActive ? "켜짐" : "꺼짐")
                    .accessibilityHint("이 곡과 비슷한 음악 이어 듣기")
                    .accessibilityIdentifier("mixToggle")
                Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44) }
                    .foregroundStyle(.secondary).accessibilityLabel("대기열")
            }.padding(.top, 22).padding(.horizontal, -10)
        }.buttonStyle(.plain).padding(.horizontal, 26).padding(.bottom, 20)
    }
    private var modeLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    }
    private var modeLabelLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 7))
    }
    private func modeLabel(_ title: String, symbol: String) -> some View {
        modeLabelLayout {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(height: 22)
            Text(title).font(theme.captionFont)
        }.frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
    }
    private var repeatLabel: String { playback.repeatMode == .off ? "반복 끔" : playback.repeatMode == .one ? "한 곡 반복" : "전체 반복" }
    private func time(_ value: Double) -> String { let seconds = value.isFinite ? max(0, Int(value)) : 0; return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

struct RoutePicker: UIViewRepresentable {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { uiView.activeTintColor = UIColor(palette.accent) }
}
