import SwiftUI
import MusicCore

struct SearchView: View {
    let openSettings: () -> Void
    var onEditingChange: (Bool) -> Void = { _ in }
    @Environment(PlaybackController.self) private var playback
    @Environment(\.swayTheme) private var theme
    @Environment(\.swayPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var submitted = ""
    @State private var page: CatalogPage?
    @State private var results: [Track] = []
    @State private var loading = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var mode: SearchMode = .all
    @FocusState private var searchFocused: Bool
    private var showingLibrary: Bool { query.isEmpty && submitted.isEmpty && !searchFocused }
    var body: some View {
        // 검색창의 위치를 고정해 보관함/결과 전환에도 입력 포커스를 유지한다.
        VStack(spacing: 0) {
            if showingLibrary {
                LibraryView(openSearch: { searchFocused = true })
            } else {
                resultsList
            }
        }.listStyle(.plain)
            .themedList()
            .safeAreaInset(edge: .top, spacing: 0) { searchHeader }
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: mode) { _, _ in search() }
            .onChange(of: searchFocused) { _, focused in onEditingChange(focused) }
            .onDisappear {
                request?.cancel(); generation = UUID(); loading = false
                onEditingChange(false)
            }
    }
    private var resultsList: some View {
        List {
            if results.isEmpty {
                if loading { HStack { Spacer(); ProgressView("찾는 중"); Spacer() }.listRowBackground(Color.clear) }
                else if let error {
                    ContentUnavailableView { Label("검색을 불러오지 못했어요", systemImage: "wifi.exclamationmark") }
                    description: { Text(error) }
                    actions: { Button("다시 시도") { search() } }
                        .listRowBackground(Color.clear)
                } else if !submitted.isEmpty {
                    ContentUnavailableView(submitted.isEmpty ? "듣고 싶은 곡을 검색하세요" : "검색 결과가 없어요",
                        systemImage: "magnifyingglass", description: Text(submitted.isEmpty ? (mode == .music ? "곡 제목이나 가수 이름을 입력하세요" : "노래, 가수, 커버나 라이브 영상까지") : (mode == .music ? "찾는 음원이 없다면 전체 검색도 확인해 보세요." : "다른 검색어로 찾아보세요.")))
                        .listRowBackground(Color.clear)
                    if mode == .music, !submitted.isEmpty {
                        Button("전체에서 검색") { mode = .all }.buttonStyle(ThemeButtonStyle())
                    }
                }
            }
            ForEach(results) { track in
                // 검색 결과 전체를 원치 않는 자동 대기열로 만들지 않는다.
                TrackRow(track: track) { playback.play([track]) }
            }
            if page?.continuation != nil {
                Button { more() } label: {
                    HStack { Spacer(); if loading { ProgressView() } else { Text("더 보기") }; Spacer() }
                }.disabled(loading)
            }
            if !results.isEmpty, let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private var searchHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                scopeMenu
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 22).accessibilityHidden(true)
                TextField(typeSize.isAccessibilitySize ? "검색" : "노래, 가수 검색", text: $query)
                    .font(theme.bodyFont).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($searchFocused).accessibilityIdentifier("searchField")
                    .accessibilityLabel("검색어")
                    .onSubmit { searchFocused = false; search() }
                if !query.isEmpty {
                    Button { query = ""; search(); searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }.accessibilityLabel("검색어 지우기").accessibilityIdentifier("clearSearch")
                }
            }.padding(.leading, 8).padding(.trailing, query.isEmpty ? 14 : 0)
                .frame(minHeight: 52).padding(.vertical, 2).themeControl()
            if !showingLibrary {
                Button("취소", action: cancelSearch).font(theme.captionFont).fixedSize().frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("cancelSearch")
            } else {
                Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 20)).frame(width: 48, height: 48).themeControl() }
                    .accessibilityLabel("설정").accessibilityIdentifier("openSettings")
            }
        }.buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
    }
    private var scopeMenu: some View {
        Menu {
            Section("검색 범위") {
                scopeOption("전체", selection: .all)
                scopeOption("음악", selection: .music)
            }
        } label: {
            HStack(spacing: 5) {
                Text(mode == .all ? "전체" : "음악").font(theme.captionFont.weight(.semibold)).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }.foregroundStyle(palette.accent).padding(.horizontal, 5).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel("검색 범위").accessibilityValue(mode == .all ? "전체" : "음악")
            .accessibilityHint("전체 영상 또는 앨범·공식 음원 중심 검색을 선택해요")
            .accessibilityIdentifier("searchScope")
    }
    private func scopeOption(_ title: String, selection: SearchMode) -> some View {
        Button { searchFocused = false; mode = selection } label: {
            Label(title, systemImage: mode == selection ? "checkmark" : selection == .music ? "music.note" : "play.rectangle")
        }.accessibilityAddTraits(mode == selection ? .isSelected : [])
            .accessibilityIdentifier(selection == .all ? "searchMode-all" : "searchMode-music")
    }
    private func cancelSearch() {
        request?.cancel(); request = nil; generation = UUID()
        query = ""; submitted = ""; results = []; page = nil; error = nil; loading = false
        searchFocused = false
    }
    private func search() {
        request?.cancel(); let token = UUID(); generation = token
        submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; page = nil; error = nil
        guard !submitted.isEmpty else { loading = false; return }
        loading = true
        let term = submitted
        let requestedMode = mode
        request = Task {
            do {
                let response = try await playback.catalog.search(term, mode: requestedMode)
                guard !Task.isCancelled, generation == token else { return }
                page = response; results = response.tracks; loading = false
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = "연결을 확인하고 잠시 후 다시 시도해 주세요."; loading = false
            }
        }
    }
    private func more() {
        guard let page, !loading else { return }
        let token = generation; loading = true; error = nil
        request = Task {
            do {
                let response = try await playback.catalog.more(page)
                guard !Task.isCancelled, generation == token else { return }
                let known = Set(results.map(\.id))
                results += response.tracks.filter { !known.contains($0.id) }; self.page = response; loading = false
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = "추가 결과를 불러오지 못했어요. 다시 시도해 주세요."; loading = false
            }
        }
    }
}
