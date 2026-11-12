import Foundation

public enum SearchMode: String, CaseIterable, Sendable {
    case all, music
}

public struct CatalogPage: Sendable {
    public var tracks: [Track]
    public var continuation: String?
    public var clientVersion: String?
    public var mode: SearchMode
    public var query: String
    public init(tracks: [Track], continuation: String? = nil, clientVersion: String? = nil, mode: SearchMode = .all, query: String = "") {
        self.tracks = tracks; self.continuation = continuation; self.clientVersion = clientVersion
        self.mode = mode; self.query = query
    }
}

public enum CatalogError: Error, LocalizedError {
    case invalidID, invalidResponse, unavailable, missingData
    public var errorDescription: String? {
        switch self {
        case .invalidID: return "올바른 영상 주소가 아니에요."
        case .invalidResponse, .missingData: return "지금은 목록을 불러올 수 없어요. 잠시 후 다시 시도해 주세요."
        case .unavailable: return "연결을 확인하고 다시 시도해 주세요."
        }
    }
}

public actor YouTubeCatalog {
    private let session: URLSession
    private var mixChecks: [String: (date: Date, track: Track?)] = [:]
    /// 정식 음원이 거의 없던 시작 곡 → 대신 쓴 같은 곡의 정식 음원판.
    private var officialSeeds: [String: String] = [:]
    private let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    public func search(_ query: String, mode: SearchMode = .all) async throws -> CatalogPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return CatalogPage(tracks: []) }
        var url = URLComponents(string: "https://www.youtube.com/results")!
        let term = mode == .music ? query + " \"Provided to YouTube by\"" : query
        url.queryItems = [.init(name: "search_query", value: term), .init(name: "hl", value: "ko"), .init(name: "gl", value: "KR")]
        let data = try await request(URLRequest(url: url.url!))
        guard let html = String(data: data, encoding: .utf8) else { throw CatalogError.invalidResponse }
        let root = try CatalogParser.initialData(html)
        return CatalogPage(tracks: mode == .music ? CatalogParser.musicTracks(root, query: query) : CatalogParser.tracks(root, renderer: "videoRenderer"),
                           continuation: CatalogParser.continuation(root), clientVersion: CatalogParser.clientVersion(html), mode: mode, query: query)
    }
    public func more(_ page: CatalogPage) async throws -> CatalogPage {
        guard let token = page.continuation, let version = page.clientVersion else { return CatalogPage(tracks: []) }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": ["clientName": "WEB", "clientVersion": version, "hl": "ko", "gl": "KR"]], "continuation": token])
        let data = try await request(req)
        let root = try JSONSerialization.jsonObject(with: data)
        return CatalogPage(tracks: page.mode == .music ? CatalogParser.musicTracks(root, query: page.query) : CatalogParser.tracks(root, renderer: "videoRenderer"),
                           continuation: CatalogParser.continuation(root), clientVersion: version, mode: page.mode, query: page.query)
    }
    public func mix(seedID: String, afterID: String? = nil, excluding: Set<String> = []) async throws -> [Track] {
        guard Track.validID(seedID) else { throw CatalogError.invalidID }
        if let afterID, !Track.validID(afterID) { throw CatalogError.invalidID }
        let excluded = excluding.union([seedID])
        // 앞서 정식 음원판으로 바꾼 시작점이 있으면 그 곡의 자동 믹스를 이어 받는다.
        if let official = officialSeeds[seedID] {
            return try await radio(seedID: official, afterID: afterID, excluding: excluded.union([official])).tracks
        }
        let direct = try await radio(seedID: seedID, afterID: afterID, excluding: excluded)
        guard direct.tracks.count < 5, let seed = direct.seed else { return direct.tracks }
        // 뮤직비디오로 시작하면 YouTube 자동 믹스도 뮤직비디오 위주라 정식 음원이 거의 남지 않는다(강남스타일 M/V 0곡).
        // 같은 곡의 정식 음원판을 음악 검색으로 찾아 그 곡의 자동 믹스로 더 받는다. 재생 중인 곡은 바꾸지 않는다.
        var result = direct.tracks
        do {
            let page = try await search(CatalogParser.mixSearchTerm(for: seed), mode: .music)
            var titles = Set<String>()
            let found = page.tracks.filter { !excluded.contains($0.id) && !MixPolicy.hasUnwantedVersion($0.title) && titles.insert($0.title.lowercased()).inserted }
            if let official = found.first {
                let more = try await radio(seedID: official.id, afterID: nil, excluding: excluded.union([official.id]).union(result.map(\.id))).tracks
                if !more.isEmpty { officialSeeds[seedID] = official.id }
                result += more
            }
            // 그래도 없으면 검색에서 찾은 다른 정식 음원을 비슷한 곡으로 쓴다. 첫 곡은 재생 중인 곡의 정식 음원판이라 뺀다.
            if result.isEmpty { result = Array(found.dropFirst().prefix(25)) }
        } catch {
            // 더 받기에 실패해도 이미 고른 정식 음원은 쓴다.
            if result.isEmpty || error is CancellationError { throw error }
        }
        return result
    }
    /// `RD + seedID` 자동 믹스에서 정식 음원만 고른다. 목록 맨 앞의 시작 곡 정보도 돌려준다.
    private func radio(seedID: String, afterID: String?, excluding: Set<String>) async throws -> (tracks: [Track], seed: Track?) {
        var url = URLComponents(string: "https://www.youtube.com/watch")!
        url.queryItems = [.init(name: "v", value: afterID ?? seedID), .init(name: "list", value: "RD" + seedID),
                          .init(name: "hl", value: "ko"), .init(name: "gl", value: "KR")]
        let data = try await request(URLRequest(url: url.url!))
        guard let html = String(data: data, encoding: .utf8) else { throw CatalogError.invalidResponse }
        guard let version = CatalogParser.clientVersion(html) else { throw CatalogError.missingData }
        let panel = CatalogParser.tracks(try CatalogParser.initialData(html), renderer: "playlistPanelVideoRenderer")
        let candidates = MixPolicy.candidates(panel, excluding: excluding)
            .filter { !MixPolicy.hasUnwantedVersion($0.title) }
        var result: [Track] = []
        // 추천 목록만으로는 MV/음원을 구별할 수 없다. 오디오 대신 작은 메타데이터 응답만 확인한다.
        // 최대 25곡, 동시 4개. 검증 실패를 일반 영상으로 채우지 않는다.
        for start in stride(from: 0, to: candidates.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(candidates[start..<min(start + 4, candidates.count)])
            let checked = try await withThrowingTaskGroup(of: (Int, Track?).self) { group in
                for (index, track) in batch.enumerated() {
                    group.addTask { (index, try await self.checkedMixTrack(track, version: version)) }
                }
                var rows: [(Int, Track?)] = []
                for try await row in group { rows.append(row) }
                return rows.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
            }
            result.append(contentsOf: checked)
        }
        return (result, panel.first { $0.id == seedID })
    }
    private func checkedMixTrack(_ track: Track, version: String) async throws -> Track? {
        if let cached = mixChecks[track.id], Date().timeIntervalSince(cached.date) < 3600 { return cached.track }
        let fields = "videoDetails(videoId,title,author,shortDescription,lengthSeconds,isLiveContent),microformat(playerMicroformatRenderer(category))"
        var url = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")!
        url.queryItems = [.init(name: "prettyPrint", value: "false"), .init(name: "fields", value: fields)]
        var req = URLRequest(url: url.url!); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": ["clientName": "WEB", "clientVersion": version, "hl": "en", "gl": "KR"]], "videoId": track.id])
        let data = try await request(req)
        let root = try JSONSerialization.jsonObject(with: data)
        let checked = CatalogParser.cleanMixTrack(root, candidate: track)
        if mixChecks.count >= 256 { mixChecks.removeAll() }
        mixChecks[track.id] = (Date(), checked)
        return checked
    }
    private func request(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        var request = request
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("ko-KR,ko;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CatalogError.unavailable }
        guard data.count < 12_000_000 else { throw CatalogError.invalidResponse }
        return data
    }
}

public enum CatalogParser {
    /// 시작 곡의 정식 음원판을 찾는 검색어. 제목의 뮤직비디오·영상 표기를 지운다.
    /// 채널은 소속사인 경우가 많아(HYBE LABELS) Topic 채널일 때만 아티스트 이름을 붙인다.
    public static func mixSearchTerm(for track: Track) -> String {
        let video = #"m/?v|music\s+video|official|video|lyrics?|audio|visualizer|4k|hd|뮤직비디오"#
        var term = track.title
            .replacingOccurrences(of: #"(?i)[\(\[【][^\)\]】]*\b("# + video + #")\b[^\)\]】]*[\)\]】]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(official\s+)?(m/?v|music\s+video|lyric\s+video|video|audio)\b|\b(4k|hd)\b|뮤직비디오"#, with: " ", options: .regularExpression)
        for suffix in [" - Topic", " - 주제"] where track.artist.hasSuffix(suffix) {
            term += " " + track.artist.dropLast(suffix.count)
        }
        return term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func cleanMixTrack(_ root: Any, candidate: Track) -> Track? {
        guard let root = root as? [String: Any], let details = root["videoDetails"] as? [String: Any],
              details["videoId"] as? String == candidate.id,
              let title = details["title"] as? String, !title.isEmpty,
              let author = details["author"] as? String,
              let description = details["shortDescription"] as? String,
              let length = details["lengthSeconds"] as? String, let duration = Double(length),
              duration.isFinite, (30...900).contains(duration), details["isLiveContent"] as? Bool == false,
              let microformat = (root["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any],
              microformat["category"] as? String == "Music" else { return nil }
        let topic = [" - topic", " - 주제"].contains { author.lowercased().hasSuffix($0) }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard topic, text.hasPrefix("provided to youtube by "), text.contains("auto-generated by youtube"),
              !MixPolicy.hasUnwantedVersion(title), !MixPolicy.hasUnwantedVersion(candidate.title) else { return nil }
        return Track(id: candidate.id, title: title, artist: candidate.artist, duration: duration, artworkURL: candidate.artworkURL)
    }
    public static func initialData(_ html: String) throws -> Any {
        for marker in ["var ytInitialData =", "ytInitialData =", "window[\"ytInitialData\"] ="] {
            guard let range = html.range(of: marker), let start = html[range.upperBound...].firstIndex(of: "{") else { continue }
            var depth = 0, quoted = false, escaped = false
            for index in html[start...].indices {
                let char = html[index]
                if quoted {
                    if escaped { escaped = false }
                    else if char == "\\" { escaped = true }
                    else if char == "\"" { quoted = false }
                } else {
                    if char == "\"" { quoted = true }
                    else if char == "{" { depth += 1 }
                    else if char == "}" {
                        depth -= 1
                        if depth == 0 {
                            return try JSONSerialization.jsonObject(with: Data(html[start...index].utf8))
                        }
                    }
                }
            }
        }
        throw CatalogError.missingData
    }
    public static func clientVersion(_ html: String) -> String? {
        let pattern = #""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
    public static func text(_ node: Any?) -> String {
        guard let node = node as? [String: Any] else { return "" }
        if let text = node["simpleText"] as? String { return text }
        return (node["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    public static func tracks(_ root: Any, renderer: String) -> [Track] {
        var tracks: [Track] = [], seen: Set<String> = []
        walk(root) { dictionary in
            guard let node = dictionary[renderer] as? [String: Any], let id = node["videoId"] as? String,
                  Track.validID(id), seen.insert(id).inserted else { return }
            let title = text(node["title"])
            guard !title.isEmpty else { return }
            let author = ["shortBylineText", "ownerText", "longBylineText"].map { text(node[$0]) }.first { !$0.isEmpty } ?? "YouTube"
            let thumbnails = (node["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
            let thumbnail = thumbnails.first { ($0["width"] as? Int ?? 0) >= 240 } ?? thumbnails.last
            let artwork = (thumbnail?["url"] as? String).flatMap(URL.init(string:))
            let durationText = text(node["lengthText"])
            let components = durationText.split(separator: ":").compactMap { Int($0.filter(\.isNumber)) }
            let duration = components.isEmpty ? nil : Double(components.reduce(0) { $0 * 60 + $1 })
            tracks.append(Track(id: id, title: title, artist: author, duration: duration, artworkURL: artwork))
        }
        return tracks
    }
    public static func continuation(_ root: Any) -> String? {
        var token: String?
        walk(root) { node in
            guard token == nil, let renderer = node["continuationItemRenderer"] as? [String: Any],
                  let endpoint = renderer["continuationEndpoint"] as? [String: Any],
                  let command = endpoint["continuationCommand"] as? [String: Any] else { return }
            token = command["token"] as? String
        }
        return token
    }
    public static func musicTracks(_ root: Any, query: String) -> [Track] {
        var candidates: [(track: Track, rank: Int, order: Int)] = []
        var seen: Set<String> = []
        let versionPattern = #"(?i)\b(live|cover|remix|karaoke|instrumental|slowed|sped up|performance)\b|라이브|커버|리믹스|노래방|직캠|스케치북"#
        let requestedVersion = query.range(of: versionPattern, options: .regularExpression) != nil
        walk(root) { dictionary in
            guard let node = dictionary["videoRenderer"] as? [String: Any],
                  let track = tracks(["videoRenderer": node], renderer: "videoRenderer").first,
                  !seen.contains(track.id) else { return }
            let title = track.title.lowercased()
            let snippets = (node["detailedMetadataSnippets"] as? [[String: Any]] ?? []).map { text($0["snippetText"]) }
            let description = ([text(node["descriptionSnippet"])] + snippets).joined(separator: " ").lowercased()
            let badges = node["ownerBadges"] as? [[String: Any]] ?? []
            let artist = badges.contains { ($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String == "BADGE_STYLE_TYPE_VERIFIED_ARTIST" }
            let topic = [" - topic", " - 주제"].contains { track.artist.lowercased().hasSuffix($0) }
            let distributed = description.contains("provided to youtube by") && (artist || topic)
            let officialAudio = artist && (title.contains("official audio") || title.contains("공식 음원"))
            // 제목의 'Official' 또는 복사된 설명만으로 공식 음원이라고 판정하지 않는다.
            guard distributed || officialAudio else { return }
            guard title.range(of: #"\bm/?v\b|music video|뮤직비디오"#, options: .regularExpression) == nil else { return }
            let alternate = title.range(of: versionPattern, options: .regularExpression) != nil
            let rank = (distributed ? 100 : 80) - (!requestedVersion && alternate ? 40 : 0)
            seen.insert(track.id)
            candidates.append((track, rank, candidates.count))
        }
        return candidates.sorted { $0.rank == $1.rank ? $0.order < $1.order : $0.rank > $1.rank }.map(\.track)
    }
    private static func walk(_ node: Any, depth: Int = 0, visit: ([String: Any]) -> Void) {
        guard depth < 80 else { return }
        if let dictionary = node as? [String: Any] {
            visit(dictionary)
            // 배열 순서를 보존하고 dictionary 키 순서의 비결정성을 제거한다.
            for key in dictionary.keys.sorted() { if let child = dictionary[key] { walk(child, depth: depth + 1, visit: visit) } }
        } else if let array = node as? [Any] { for child in array { walk(child, depth: depth + 1, visit: visit) } }
    }
}
