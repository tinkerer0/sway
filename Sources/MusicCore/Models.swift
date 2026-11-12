import Foundation

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var duration: Double?
    public var artworkURL: URL?
    public init(id: String, title: String, artist: String, duration: Double? = nil, artworkURL: URL? = nil) {
        self.id = id; self.title = title; self.artist = artist
        self.duration = duration; self.artworkURL = artworkURL
    }
    public static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
    public var durationLabel: String {
        guard let duration, duration.isFinite, duration > 0 else { return "" }
        let seconds = Int(duration)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

public struct Playlist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var trackIDs: [String]
    public init(id: UUID = UUID(), name: String, trackIDs: [String] = []) {
        self.id = id; self.name = name; self.trackIDs = trackIDs
    }
}

public struct ListeningEntry: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var trackID: String
    public var playedAt: Date
    public init(trackID: String, playedAt: Date = Date()) { self.trackID = trackID; self.playedAt = playedAt }
}

public struct ListeningStats: Codable, Sendable {
    public var plays: Int
    public var lastPlayedAt: Date
    public init(plays: Int = 0, lastPlayedAt: Date = Date()) { self.plays = plays; self.lastPlayedAt = lastPlayedAt }
}

public struct LibrarySnapshot: Codable, Sendable {
    public var schemaVersion = 1
    public var tracks: [String: Track] = [:]
    public var savedIDs: [String] = []
    public var playlists: [Playlist] = []
    public var history: [ListeningEntry] = []
    public var lastTrackID: String?
    public var lastPosition: Double = 0
    // Optional로 추가해 기존 schema 1 보관함을 그대로 읽는다.
    public var playbackSession: PlaybackSession?
    // Optional로 추가해 기존 보관함을 읽고, 실제 청취 횟수는 업데이트 이후부터 집계한다.
    public var listeningStats: [String: ListeningStats]?
    public init() {}
    public mutating func save(_ track: Track) {
        tracks[track.id] = track
        if !savedIDs.contains(track.id) { savedIDs.insert(track.id, at: 0) }
    }
    @discardableResult public mutating func createPlaylist(name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let playlist = Playlist(name: String(name.prefix(100)))
        playlists.append(playlist)
        return playlist.id
    }
    @discardableResult public mutating func renamePlaylist(id: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return false }
        playlists[index].name = String(name.prefix(100)); return true
    }
    @discardableResult public mutating func add(_ track: Track, to id: UUID) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == id }), !playlists[index].trackIDs.contains(track.id) else { return false }
        save(track); playlists[index].trackIDs.append(track.id); return true
    }
    public mutating func record(_ track: Track) {
        tracks[track.id] = track
        history.removeAll { $0.trackID == track.id }
        history.insert(ListeningEntry(trackID: track.id), at: 0)
        history = Array(history.prefix(200))
        lastTrackID = track.id
    }
    public mutating func recordQualifiedListen(_ track: Track, at date: Date = Date()) {
        tracks[track.id] = track
        var stats = listeningStats ?? [:]
        let previous = stats[track.id]?.plays ?? 0
        stats[track.id] = ListeningStats(plays: min(previous, 999_999) + 1, lastPlayedAt: date)
        listeningStats = stats
    }
    public func tracks(in playlist: Playlist) -> [Track] { playlist.trackIDs.compactMap { tracks[$0] } }
}

public enum LibraryError: Error, LocalizedError {
    case unsupportedVersion, unreadable
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "더 새로운 버전에서 저장한 보관함이에요. 앱을 업데이트해 주세요."
        case .unreadable: return "보관함을 읽지 못했어요. 원본은 보존했어요."
        }
    }
}

public struct LibraryFile {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibrarySnapshot() }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (envelope?["schemaVersion"] as? Int) == 1 else { throw LibraryError.unsupportedVersion }
            return try JSONDecoder().decode(LibrarySnapshot.self, from: data)
        } catch let error as LibraryError { throw error }
        catch { throw LibraryError.unreadable }
    }
    public func write(_ snapshot: LibrarySnapshot) throws {
        // 읽지 못한 기존 파일을 빈 데이터로 덮지 않는다.
        if FileManager.default.fileExists(atPath: url.path) { _ = try load() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

public enum MixPolicy {
    public static func hasUnwantedVersion(_ title: String) -> Bool {
        let pattern = #"(?ix)\b(m/?v|music\s+video|official\s+video|lyric\s+video|visualizer|concert|performance|fancam|reaction|interview|teaser|trailer|karaoke|cover|remix|mashup|bootleg|slowed|sped[\s-]*up|nightcore|bass[\s-]*boosted|8d|sfx|asmr|sound[\s-]*effects?|white\s+noise|rain\s+sounds?|intro|outro|skit)\b|\blive\s+(at|from|in|on|version|ver\b)|[\[(]\s*live\b|\blive\s*$|뮤직비디오|라이브|직캠|공연|리액션|인터뷰|효과음|빗소리|백색소음|커버|리믹스|매시업|노래방|배속|나이트코어|티저|예고편|인트로|아웃트로"#
        return title.range(of: pattern, options: .regularExpression) != nil
    }
    public static func candidates(_ tracks: [Track], excluding ids: Set<String>, limit: Int = 25) -> [Track] {
        var seen = ids
        return Array(tracks.filter { Track.validID($0.id) && seen.insert($0.id).inserted }.prefix(limit))
    }
}
