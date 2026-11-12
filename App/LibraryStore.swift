import Foundation
import Observation
import MusicCore

@MainActor @Observable final class LibraryStore {
    private(set) var snapshot = LibrarySnapshot()
    var error: String?
    @ObservationIgnored private let file: LibraryFile
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var lastWriteFailure: Date?
    @ObservationIgnored private var reportedWriteFailure = false
    init(fileURL override: URL? = nil) {
        let root = URL.applicationSupportDirectory.appendingPathComponent("Sway", isDirectory: true)
        #if DEBUG
        let testing = override == nil && ProcessInfo.processInfo.arguments.contains("--uitesting")
        let fileURL = override ?? (testing ? root.appendingPathComponent("ui-test-library.json") : root.appendingPathComponent("library.json"))
        #else
        let fileURL = override ?? root.appendingPathComponent("library.json")
        #endif
        file = LibraryFile(url: fileURL)
        #if DEBUG
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-fixture") { try? FileManager.default.removeItem(at: fileURL) }
        #endif
        do { snapshot = try file.load() } catch { readable = false; self.error = error.localizedDescription }
        #if DEBUG
        if testing && snapshot.savedIDs.isEmpty {
            change { state in
                state.save(Track(id: "YE7VzlLtp-4", title: "Big Buck Bunny", artist: "Blender · 재생 확인용", duration: 596,
                                 artworkURL: URL(string: "https://i.ytimg.com/vi/YE7VzlLtp-4/hqdefault.jpg")))
                _ = state.createPlaylist(name: "테스트 목록")
            }
        }
        if testing && ProcessInfo.processInfo.arguments.contains("--home-layout-fixture") && snapshot.history.isEmpty {
            change { state in
                let seed = Track(id: "NnRjwEhFU70", title: "Through the Night (밤편지)", artist: "IU", duration: 254)
                state.record(seed)
                state.recordQualifiedListen(seed)
            }
        }
        #endif
    }
    var saved: [Track] { snapshot.savedIDs.compactMap { snapshot.tracks[$0] } }
    var recent: [Track] { snapshot.history.compactMap { snapshot.tracks[$0.trackID] } }
    func contains(_ track: Track) -> Bool { snapshot.savedIDs.contains(track.id) }
    func change(_ mutation: (inout LibrarySnapshot) -> Void) {
        guard readable else { error = "보관함 원본을 보존 중이에요. 파일을 복구하기 전에는 변경할 수 없어요."; return }
        var next = snapshot; mutation(&next)
        do { try file.write(next); snapshot = next; lastWriteFailure = nil; reportedWriteFailure = false }
        catch {
            lastWriteFailure = Date()
            if !reportedWriteFailure { self.error = "변경 내용을 저장하지 못했어요. 기존 보관함은 유지돼요."; reportedWriteFailure = true }
        }
    }
    func save(_ track: Track) { change { $0.save(track) } }
    func recordQualifiedListen(_ track: Track) { change { $0.recordQualifiedListen(track) } }
    func removeSaved(_ id: String) {
        change { state in state.savedIDs.removeAll { $0 == id } }
    }
    func checkpoint(_ queue: PlaybackQueue, position: Double, record: Bool = false) {
        guard readable, let track = queue.current else { return }
        if let lastWriteFailure, Date().timeIntervalSince(lastWriteFailure) < 30 { return }
        change { state in
            if record { state.record(track) }
            state.tracks[track.id] = track; state.lastTrackID = track.id
            state.lastPosition = position.isFinite ? max(0, position) : 0
            state.playbackSession = PlaybackSession(queue: queue, position: state.lastPosition)
        }
    }
}
