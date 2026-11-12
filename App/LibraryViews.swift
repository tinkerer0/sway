import SwiftUI
import MusicCore

struct LibraryView: View {
    let openSearch: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        ScrollView {
            if theme == .noir { noirHome } else {
            VStack(alignment: .leading, spacing: 30) {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 12) { collections }
                } else {
                    HStack(spacing: 12) { collections }
                }
                VStack(alignment: .leading, spacing: 16) {
                    sectionHeadingLayout {
                        Text("재생목록").font(theme.titleFont)
                        if !typeSize.isAccessibilitySize { Spacer() }
                        Button("만들기", systemImage: "plus") { name = ""; creating = true }
                            .buttonStyle(ThemeButtonStyle())
                            .accessibilityIdentifier("createPlaylist")
                    }
                    if library.snapshot.playlists.isEmpty {
                        VStack(spacing: 14) {
                            ThemeIllustration(size: 100)
                            Text("좋아하는 곡끼리 모아보세요").font(theme.headlineFont)
                            Text("곡 옆의 메뉴에서 재생목록에 추가할 수 있어요.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("노래 검색", action: openSearch).buttonStyle(ThemeButtonStyle())
                        }.frame(maxWidth: .infinity).padding(28)
                            .themeSurface()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(library.snapshot.playlists) { list in
                                NavigationLink { PlaylistView(id: list.id) } label: {
                                    HStack(spacing: 16) {
                                        if let first = library.snapshot.tracks(in: list).first { Artwork(track: first, size: 60) }
                                        else {
                                            RoundedRectangle(cornerRadius: theme.controlRadius).fill(palette.wash).frame(width: 60, height: 60)
                                                .overlay { Image(systemName: "music.note.list").font(.title2).foregroundStyle(palette.accent) }
                                        }
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(list.name).font(theme.headlineFont).foregroundStyle(.primary)
                                            Text("\(list.trackIDs.count)곡").font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }.padding(16).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if list.id != library.snapshot.playlists.last?.id { Divider().padding(.leading, 92) }
                            }
                        }.themeSurface()
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
        }.background { ThemeBackground() }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .alert("새 재생목록", isPresented: $creating) {
                TextField("이름", text: $name)
                Button("취소", role: .cancel) {}
                Button("만들기") { library.change { _ = $0.createPlaylist(name: name) } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
    }
    /// 블랙 테마 홈: 카드 없이 큰 제목과 표지로 구성한다. 구역 제목을 누르면 전체 목록으로 간다.
    private var noirHome: some View {
        VStack(alignment: .leading, spacing: 34) {
            if !library.recent.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    noirHeading("최근 들은 곡") { TrackCollectionView(kind: .recent) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            let recent = Array(library.recent.prefix(12))
                            ForEach(Array(recent.enumerated()), id: \.element.id) { index, track in
                                Button { playback.play(recent, at: index) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Artwork(track: track, size: 136)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(track.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.frame(width: 136, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("\(track.title), \(track.artist), 재생")
                            }
                        }
                    }.contentMargins(.horizontal, 20, for: .scrollContent).padding(.horizontal, -20)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                noirHeading("저장한 곡") { TrackCollectionView(kind: .saved) }
                if library.saved.isEmpty {
                    Text("곡 옆의 메뉴에서 보관함에 추가할 수 있어요.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    let saved = library.saved
                    ForEach(Array(saved.prefix(4).enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track) { playback.play(saved, at: index) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionHeadingLayout {
                    Text("재생목록").font(theme.titleFont).accessibilityAddTraits(.isHeader)
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button("만들기", systemImage: "plus") { name = ""; creating = true }
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 36)
                        .background(Color.white.opacity(0.1), in: Capsule()).buttonStyle(.plain)
                        .accessibilityIdentifier("createPlaylist")
                }
                if library.snapshot.playlists.isEmpty {
                    Text("좋아하는 곡끼리 모아보세요. 곡 옆의 메뉴에서 재생목록에 추가할 수 있어요.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(library.snapshot.playlists) { list in
                        NavigationLink { PlaylistView(id: list.id) } label: {
                            HStack(spacing: 14) {
                                if let first = library.snapshot.tracks(in: list).first { Artwork(track: first, size: 56) }
                                else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surface).frame(width: 56, height: 56)
                                        .overlay { Image(systemName: "music.note.list").font(.title3).foregroundStyle(.secondary) }
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(list.name).font(theme.bodyFont).foregroundStyle(.primary).lineLimit(1)
                                    Text("\(list.trackIDs.count)곡").font(theme.captionFont).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
    }
    private func noirHeading<Destination: View>(_ title: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 6) {
                Text(title).font(theme.titleFont).foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityHint("전체 목록 보기")
    }
    private var sectionHeadingLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
    }
    @ViewBuilder private var collections: some View {
        NavigationLink { TrackCollectionView(kind: .saved) } label: {
            collectionCard("저장한 곡", detail: "\(library.saved.count)곡", icon: "music.note")
        }.buttonStyle(.plain)
        NavigationLink { TrackCollectionView(kind: .recent) } label: {
            collectionCard("최근 들은 곡", detail: "다시 듣고 싶은 순간", icon: "clock.arrow.circlepath")
        }.buttonStyle(.plain)
    }
    private func collectionCard(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: icon).font(.title2).foregroundStyle(palette.accent).frame(minHeight: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(theme.headlineFont).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .themeSurface()
    }
}

struct AboutView: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("좋아하는 음악을, 가볍게.").font(theme.headlineFont)
                    Text("음원은 인터넷으로 스트리밍해요. 보관함에는 곡 정보와 재생목록만 저장해요.")
                    Text("영상 없이 오디오만 재생하며, 원본에서 제공하는 높은 품질을 사용해요.")
                }.font(theme.bodyFont).padding(20).frame(maxWidth: .infinity, alignment: .leading).themeSurface()
                ThemeSettingsGroup(title: "보관함") {
                    Text("앱을 삭제하면 저장한 곡 목록도 사라져요. 업데이트할 때는 기존 앱을 지우지 않고 설치하세요.")
                        .font(theme.bodyFont).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }.background { ThemeBackground() }.themeNavigation("Sway 정보")
    }
}

enum CollectionKind { case saved, recent }
struct TrackCollectionView: View {
    let kind: CollectionKind
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var choosing = false
    /// 고른 순서대로 재생한다.
    @State private var chosen: [String] = []
    @State private var adding = false
    private var tracks: [Track] { kind == .saved ? library.saved : library.recent }
    private var chosenTracks: [Track] { chosen.compactMap { id in tracks.first { $0.id == id } } }
    var body: some View {
        List {
            if tracks.isEmpty {
                ContentUnavailableView(kind == .saved ? "아직 저장한 곡이 없어요" : "들은 곡이 여기에 남아요", systemImage: kind == .saved ? "music.note" : "clock")
                    .listRowBackground(Color.clear)
            } else if choosing {
                ForEach(tracks) { track in
                    TrackChoiceRow(track: track, order: chosen.firstIndex(of: track.id).map { $0 + 1 }) { toggle(track.id) }
                }
            } else {
                Button("전체 재생", systemImage: "play.fill") { playback.play(tracks) }
                    .buttonStyle(ThemeButtonStyle()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track) { playback.play(tracks, at: index) }
                        .swipeActions {
                            if kind == .saved { Button("보관함에서 제거", role: .destructive) { library.removeSaved(track.id) } }
                        }
                }
            }
        }.themedList().navigationTitle(choosing ? (chosen.isEmpty ? "곡 선택" : "\(chosen.count)곡 선택") : kind == .saved ? "저장한 곡" : "최근 들은 곡")
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if choosing { Button("취소") { finishChoosing() }.accessibilityIdentifier("cancelChoosing") }
                    else if !tracks.isEmpty { Button("선택") { choosing = true }.accessibilityIdentifier("chooseTracks") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if choosing {
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout())
                    layout {
                        Button("재생", systemImage: "play.fill") { playback.play(chosenTracks); finishChoosing() }
                            .frame(maxWidth: .infinity).accessibilityIdentifier("playChosen")
                        Button("셔플", systemImage: "shuffle") { playback.play(chosenTracks.shuffled()); finishChoosing() }
                            .frame(maxWidth: .infinity)
                        Button("담기", systemImage: "text.badge.plus") { adding = true }
                            .frame(maxWidth: .infinity).accessibilityLabel("재생목록에 담기").accessibilityIdentifier("addChosenToPlaylist")
                    }.buttonStyle(ThemeButtonStyle()).lineLimit(1).disabled(chosen.isEmpty).padding(.horizontal, 20).padding(.vertical, 8)
                }
            }
            .sheet(isPresented: $adding) { AddToPlaylistView(tracks: chosenTracks) { finishChoosing() } }
    }
    private func toggle(_ id: String) {
        if let index = chosen.firstIndex(of: id) { chosen.remove(at: index) } else { chosen.append(id) }
    }
    private func finishChoosing() { choosing = false; chosen = [] }
}

/// 곡을 골라 담는 행. 고른 순서를 번호로 보여 준다.
struct TrackChoiceRow: View {
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    let track: Track
    let order: Int?
    var note: String? = nil
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: order.map { $0 <= 50 ? "\($0).circle.fill" : "checkmark.circle.fill" } ?? "circle")
                    .font(.title2).foregroundStyle(order == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(palette.accent))
                Artwork(track: track, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(theme.bodyFont).lineLimit(2).foregroundStyle(.primary)
                    Text(note ?? [track.artist, track.durationLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(theme.captionFont).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(TrackRowSurface())
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .accessibilityLabel("\(track.title), \(track.artist)")
            .accessibilityValue(order.map { "\($0)번째로 선택됨" } ?? note ?? "선택 안 됨")
            .accessibilityAddTraits(order == nil ? [] : .isSelected)
    }
}

/// 재생목록에 넣을 곡을 저장한 곡에서 고른다.
struct SavedTrackPicker: View {
    let playlistID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String] = []
    @State private var query = ""
    private var existing: Set<String> { Set(library.snapshot.playlists.first { $0.id == playlistID }?.trackIDs ?? []) }
    private var shown: [Track] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? library.saved : library.saved.filter { $0.title.localizedCaseInsensitiveContains(term) || $0.artist.localizedCaseInsensitiveContains(term) }
    }
    var body: some View {
        NavigationStack {
            List {
                if library.saved.isEmpty {
                    ContentUnavailableView("아직 저장한 곡이 없어요", systemImage: "music.note", description: Text("곡 옆의 메뉴에서 보관함에 추가할 수 있어요."))
                        .listRowBackground(Color.clear)
                }
                ForEach(shown) { track in
                    let added = existing.contains(track.id)
                    TrackChoiceRow(track: track, order: chosen.firstIndex(of: track.id).map { $0 + 1 }, note: added ? "이미 있음" : nil) {
                        if let index = chosen.firstIndex(of: track.id) { chosen.remove(at: index) } else { chosen.append(track.id) }
                    }.disabled(added)
                }
            }.themedList().navigationTitle("저장한 곡에서 추가").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "제목이나 가수")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(chosen.isEmpty ? "추가" : "\(chosen.count)곡 추가") {
                            let tracks = chosen.compactMap { library.snapshot.tracks[$0] }
                            library.change { state in for track in tracks { _ = state.add(track, to: playlistID) } }
                            dismiss()
                        }.disabled(chosen.isEmpty).accessibilityIdentifier("confirmPickedTracks")
                    }
                }
        }
    }
}

struct PlaylistView: View {
    let id: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditMode = .inactive
    @State private var renaming = false
    @State private var deleting = false
    @State private var picking = false
    @State private var name = ""
    private var playlist: Playlist? { library.snapshot.playlists.first { $0.id == id } }
    private var tracks: [Track] { playlist.map(library.snapshot.tracks(in:)) ?? [] }
    var body: some View {
        List {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label("아직 곡이 없어요", systemImage: "music.note.list")
                } description: {
                    Text("저장한 곡에서 고르거나 곡 옆의 메뉴에서 추가하세요.")
                } actions: {
                    Button("저장한 곡에서 고르기") { picking = true }.buttonStyle(ThemeButtonStyle())
                }.listRowBackground(Color.clear)
            } else {
                if !editing.isEditing {
                    HStack {
                        Button("재생", systemImage: "play.fill") { playback.play(tracks) }.frame(maxWidth: .infinity)
                        Button("셔플", systemImage: "shuffle") { playback.play(tracks.shuffled()) }.frame(maxWidth: .infinity)
                    }.buttonStyle(ThemeButtonStyle()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track) { playback.play(tracks, at: index) }
                }
                .onMove { source, target in
                    library.change { state in
                        guard let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
                        state.playlists[index].trackIDs.move(fromOffsets: source, toOffset: target)
                    }
                }
                .onDelete { offsets in
                    let remove = Set(offsets.map { tracks[$0].id })
                    library.change { state in
                        guard let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
                        state.playlists[index].trackIDs.removeAll { remove.contains($0) }
                    }
                }
            }
        }.themedList().navigationTitle(playlist?.name ?? "재생목록").environment(\.editMode, $editing)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if editing.isEditing { Button("완료") { editing = .inactive } }
                    else {
                        Menu {
                            Button("저장한 곡에서 추가", systemImage: "plus") { picking = true }
                            Button("이름 변경", systemImage: "pencil") { name = playlist?.name ?? ""; renaming = true }
                            Button("곡 순서 편집", systemImage: "arrow.up.arrow.down") { editing = .active }.disabled(tracks.isEmpty)
                            Button("재생목록 삭제", systemImage: "trash", role: .destructive) { deleting = true }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("재생목록 메뉴")
                    }
                }
            }
            .sheet(isPresented: $picking) { SavedTrackPicker(playlistID: id) }
            .alert("이름 변경", isPresented: $renaming) {
                TextField("이름", text: $name)
                Button("취소", role: .cancel) {}
                Button("저장") { library.change { _ = $0.renamePlaylist(id: id, name: name) } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("재생목록을 삭제할까요?", isPresented: $deleting) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) { library.change { $0.playlists.removeAll { $0.id == id } }; if playlist == nil { dismiss() } }
            } message: { Text("저장한 곡은 보관함에 그대로 남아요.") }
    }
}

struct AddToPlaylistView: View {
    let tracks: [Track]
    var added: () -> Void = {}
    init(track: Track) { tracks = [track] }
    init(tracks: [Track], added: @escaping () -> Void) { self.tracks = tracks; self.added = added }
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Button("새 재생목록", systemImage: "plus") { creating = true }
                ForEach(library.snapshot.playlists) { list in
                    let missing = tracks.filter { !list.trackIDs.contains($0.id) }
                    Button {
                        library.change { state in for track in missing { _ = state.add(track, to: list.id) } }; added(); dismiss()
                    } label: {
                        HStack {
                            Text(list.name); Spacer()
                            if missing.isEmpty { Label("이미 있음", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                            else if missing.count < tracks.count { Text("\(missing.count)곡 추가").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(missing.isEmpty)
                }
            }.themedList().navigationTitle(tracks.count > 1 ? "\(tracks.count)곡을 재생목록에" : "재생목록에 추가").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
                .alert("새 재생목록", isPresented: $creating) {
                    TextField("이름", text: $name)
                    Button("취소", role: .cancel) {}
                    Button("만들고 추가") {
                        library.change { state in
                            if let id = state.createPlaylist(name: name) { for track in tracks { _ = state.add(track, to: id) } }
                        }; added(); dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
        }
    }
}
