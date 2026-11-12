import Foundation

/// 횟수는 실제 진행한 재생 시간으로만 집계한다. 탐색·일시정지로 건너뛴 시간은 제외한다.
public struct ListeningProgress {
    private var previous: Double?
    private var seconds: Double = 0
    private var qualified = false
    public init() {}
    public mutating func seek(to position: Double) { previous = position }
    public mutating func observe(position: Double, playing: Bool, duration: Double) -> Bool {
        defer { previous = position }
        guard position.isFinite, playing, !qualified, let previous else { return false }
        let delta = position - previous
        if delta > 0, delta <= 2 { seconds += delta }
        let threshold = duration.isFinite && duration > 0 ? min(30, max(10, duration / 2)) : 30
        guard seconds >= threshold else { return false }
        qualified = true
        return true
    }
}

public enum DiscoveryPolicy {
    public static func seeds(in library: LibrarySnapshot, now: Date = Date(), limit: Int = 3) -> [Track] {
        let recent = Dictionary(library.history.map { ($0.trackID, $0.playedAt) }, uniquingKeysWith: max)
        let ids = Set(recent.keys).union(library.listeningStats?.keys.map { $0 } ?? [])
        return ids.compactMap { id -> (Track, Double, Date)? in
            guard let track = library.tracks[id], Track.validID(id), let duration = track.duration,
                  duration.isFinite, (30...900).contains(duration) else { return nil }
            let stats = library.listeningStats?[id]
            let date = stats?.lastPlayedAt ?? recent[id] ?? .distantPast
            let days = max(0, now.timeIntervalSince(date) / 86400)
            let score = (1 + log1p(Double(max(0, stats?.plays ?? 0)))) / (1 + days / 14)
            return (track, score, date)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.id < $1.0.id
        }.prefix(max(0, limit)).map { $0.0 }
    }

    /// 영상 ID가 달라도 같은 제목의 재업로드를 새 곡으로 내세우지 않는다.
    public static func titleKey(_ title: String) -> String {
        let withoutTags = title.replacingOccurrences(of: #"(?i)\[(?:official\s*)?(?:mv|m/v|audio|video|lyrics?)\]|\((?:official\s*)?(?:audio|video|lyrics?)\)"#, with: "", options: .regularExpression)
        return withoutTags.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func titleKeys(_ title: String) -> Set<String> {
        var keys: Set<String> = [titleKey(title)]
        if let match = title.range(of: #"[（(]"#, options: .regularExpression) {
            let main = titleKey(String(title[..<match.lowerBound]))
            if main.count >= 3 { keys.insert(main) }
        }
        let regex = try! NSRegularExpression(pattern: #"[（(]([^）)]+)[）)]"#)
        for match in regex.matches(in: title, range: NSRange(title.startIndex..., in: title)) {
            guard let range = Range(match.range(at: 1), in: title) else { continue }
            let value = String(title[range])
            if value.range(of: #"(?i)feat|ft\.|official|audio|version|remaster|^\d+$"#, options: .regularExpression) != nil { continue }
            let key = titleKey(value)
            if key.count >= 3 { keys.insert(key) }
        }
        return keys
    }

    public static func candidates(_ candidates: [Track], in library: LibrarySnapshot, excluding: Set<String> = [], limit: Int = 6) -> [Track] {
        var ids = Set(library.tracks.keys).union(library.savedIDs).union(library.history.map(\.trackID))
            .union(library.playlists.flatMap(\.trackIDs)).union(library.listeningStats?.keys.map { $0 } ?? []).union(excluding)
        var titles = library.tracks.values.reduce(into: Set<String>()) { $0.formUnion(titleKeys($1.title)) }
        var artists: [String: Int] = [:]
        return Array(candidates.filter { track in
            let title = titleKey(track.title)
            let variants = titleKeys(track.title)
            let artist = track.artist.lowercased()
            guard Track.validID(track.id), !ids.contains(track.id), !title.isEmpty, titles.isDisjoint(with: variants),
                  !MixPolicy.hasUnwantedVersion(track.title), let duration = track.duration,
                  duration.isFinite, (30...900).contains(duration), artists[artist, default: 0] < 2 else { return false }
            ids.insert(track.id); titles.formUnion(variants); artists[artist, default: 0] += 1
            return true
        }.prefix(max(0, limit)))
    }
}
