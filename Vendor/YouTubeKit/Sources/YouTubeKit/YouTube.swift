//
//  YouTube.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 04.09.21.
//

import Foundation
@preconcurrency import os.log

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
public class YouTube {
    
    private var _js: String?
    private var _jsURL: URL?
    
    // NSCache의 URL-keyed 불변 값으로 원본 JS를 공유한다. 별도 URL/String static 쌍의
    // 동시 읽기·쓰기와 서로 다른 player 버전의 잘못된 짝을 방지한다.
    private static let playerScripts: NSCache<NSURL, NSString> = {
        let cache = NSCache<NSURL, NSString>()
        cache.countLimit = 2
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    // Sway: player JS 주소·ytcfg는 영상마다 같다. YouTube 웹 플레이어가 다음 영상으로 넘어갈 때 페이지를
    // 다시 받지 않는 것처럼 일정 시간 공유해 곡마다 watch HTML(압축 약 150 KB)을 받지 않는다.
    // 곡별 응답·재생 URL·로그인 정보는 저장하지 않는다.
    private static let pageContexts = PageContextStore()
    private static let pageContextLifetime: TimeInterval = 60 * 60

    // Sway: 서명 해석에 성공한 player JS 주소를 앱을 다시 켜도 쓴다. 쿠키 없는 watch 페이지는 요청마다 여러
    // player 버전 중 하나를 준다(2026-10-27 아이폰 하루 4개). 페이지를 따르면 다시 켠 앱이 디스크에 전처리본이 없는
    // 버전을 받아 전체 분석을 다시 했고, 곡을 누르고 바로 잠그면 이 분석이 약 20초 걸렸다.
    static let playerPin = PlayerPinStore()
    private var usesPinnedPlayer = false

    private var _videoInfos: [InnerTube.VideoInfo]?

    private var _watchHTML: String?
    private var _embedHTML: String?
    private var playerConfigArgs: [String: Any]?
    private var _ageRestricted: Bool?
    private var _signatureTimestamp: Int?
    private var _ytcfg: Extraction.YtCfg?
    
    private var _fmtStreams: [Stream]?
    
    private var initialData: Data?

    /// Represents a property that provides metadata for a YouTube video.
    ///
    /// This property allows you to retrieve metadata for a YouTube video asynchronously.
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var metadata: YouTubeMetadata? {
        get async throws {
            return .metadata(from: try await videoDetails)
        }
    }

    public let videoID: String
    
    var watchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)")!
    }
    
    private var extendedWatchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1")!
    }
    
    var embedURL: URL {
        URL(string: "https://www.youtube.com/embed/\(videoID)")!
    }
    
    // stream monostate TODO
    
    private var author: String?
    private var title: String?
    private var publishDate: String?
    
    let useOAuth: Bool
    let allowOAuthCache: Bool
    
    let methods: [ExtractionMethod]
    
    private let log = OSLog(YouTube.self)
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public init(videoID: String, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        self.videoID = videoID
        self.useOAuth = useOAuth
        self.allowOAuthCache = allowOAuthCache
        // TODO: install proxies if needed
        
        if methods.isEmpty {
#if canImport(JavaScriptCore)
            self.methods = [.local]
#else
            self.methods = [.remote]
#endif
        } else {
            self.methods = methods.removeDuplicates()
        }
    }
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public convenience init(url: URL, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        let videoID = Extraction.extractVideoID(from: url.absoluteString) ?? ""
        self.init(videoID: videoID, proxies: proxies, useOAuth: useOAuth, allowOAuthCache: allowOAuthCache, methods: methods)
    }
    
    
    private var watchHTML: String {
        get async throws {
            if let cached = _watchHTML {
                return cached
            }
            var request = URLRequest(url: extendedWatchURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _watchHTML = String(data: data, encoding: .utf8) ?? ""
            return _watchHTML!
        }
    }
    
    private var embedHTML: String {
        get async throws {
            if let cached = _embedHTML {
                return cached
            }
            var request = URLRequest(url: embedURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _embedHTML = String(data: data, encoding: .utf8) ?? ""
            return _embedHTML!
        }
    }
    
    
    /// check whether the video is available
    public func checkAvailability() async throws {
        let (status, messages) = try Extraction.playabilityStatus(watchHTML: await watchHTML)

        for reason in messages {
            switch status {
            case .unplayable:
                if reason?.starts(with: "Join this channel to get access to members-only content") ?? false { // TODO: original compared to tuple
                    throw YouTubeKitError.membersOnly
                }
            case .loginRequired:
                if reason.map({ $0.starts(with: "This is a private video") || $0.starts(with: "This video is private") }) ?? false { // TODO: original: reason == ["This is a private video. ", "Please sign in to verify that you may see it."] {
                    throw YouTubeKitError.videoPrivate
                }
            case .error:
                throw YouTubeKitError.videoUnavailable
            case .liveStream:
                let streamingData = try await videoInfos.map { $0.streamingData }
                if streamingData.allSatisfy({ $0?.hlsManifestUrl == nil }) {
                    throw YouTubeKitError.liveStreamError
                }
                continue
            case .ok, .none:
                continue
            }
        }
    }
    
    public var ageRestricted: Bool {
        get async throws {
            if let cached = _ageRestricted {
                return cached
            }
            
            _ageRestricted = try await Extraction.isAgeRestricted(watchHTML: watchHTML)
            return _ageRestricted!
        }
    }
    
    var jsURL: URL {
        get async throws {
            if let cached = _jsURL {
                return cached
            }
            
            if try await ageRestricted {
                _jsURL = try await URL(string: Extraction.jsURL(html: embedHTML))!
            } else if let pinned = Self.playerPin.current() {
                // Sway: 페이지가 다른 버전을 줘도 디스크에 전처리본이 있는 고정 player를 쓴다.
                let page = try? await Extraction.jsURL(html: watchHTML)
                os_log("Sway player pinned=%{public}@ page=%{public}@", log: log, type: .default,
                       pinned.path, page.flatMap(URL.init(string:))?.path ?? "none")
                _jsURL = pinned
                usesPinnedPlayer = true
            } else {
                _jsURL = try await URL(string: Extraction.jsURL(html: watchHTML))!
            }
            return _jsURL!
        }
    }
    
    var js: String {
        get async throws {
            if let cached = _js {
                return cached
            }
            
            let jsURL = try await jsURL
            
            if let cached = Self.playerScripts.object(forKey: jsURL as NSURL) {
                _js = cached as String
            } else {
                let (data, response) = try await URLSession.shared.data(from: jsURL)
                try Task.checkCancellation()
                let source = String(data: data, encoding: .utf8) ?? ""
                // Sway: 고정한 player를 더 받을 수 없으면 고정을 지우고 페이지가 준 player로 다시 받는다.
                if usesPinnedPlayer, (response as? HTTPURLResponse)?.statusCode != 200
                    || Extraction.extractSignatureTimestamp(fromJS: source) == nil {
                    os_log("Sway player pin dropped: %{public}@", log: log, type: .default, jsURL.path)
                    Self.playerPin.remove()
                    usesPinnedPlayer = false
                    _jsURL = nil
                    return try await js
                }
                _js = source
                Self.playerScripts.setObject(source as NSString, forKey: jsURL as NSURL, cost: source.utf8.count)
            }
            return _js!
        }
    }

    var signatureTimestamp: Int? {
        get async throws {
            if let cached = _signatureTimestamp {
                return cached
            }
            
            _signatureTimestamp = try await Extraction.extractSignatureTimestamp(fromJS: js)
            return _signatureTimestamp
        }
    }
    
    var ytcfg: Extraction.YtCfg {
        get async throws {
            if let cached = _ytcfg {
                return cached
            }
            
            _ytcfg = try await Extraction.extractYtCfg(from: watchHTML)
            return _ytcfg!
        }
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /// Returns a list of streams if they have been initialized.
    /// If the streams have not been initialized, finds all relevant streams and initializes them.
    public var streams: [Stream] {
        get async throws {
            try Task.checkCancellation()
#if canImport(JavaScriptCore)
            if _fmtStreams == nil, methods.first == .local, let context = Self.pageContexts.current(),
               let result = try await streamsUsingSharedPageContext(context) {
                _fmtStreams = result
                return result
            }
#endif
            try await checkAvailability()
            try Task.checkCancellation()
            if let cached = _fmtStreams {
                return cached
            }

            let result = try await Task.retry(with: methods) { method in
                switch method {
#if canImport(JavaScriptCore)
                case .local:
                    return try await self.extractLocalStreams()
#endif

                case .remote(let serverURL):
                    let remoteClient = RemoteYouTubeClient(serverURL: serverURL)
                    let remoteStreams = try await remoteClient.extractStreams(forVideoID: videoID)

                    return remoteStreams.compactMap { try? Stream(remoteStream: $0) }
                }
            }

#if canImport(JavaScriptCore)
            rememberPageContext()
#endif
            _fmtStreams = result
            return result
        }
    }

#if canImport(JavaScriptCore)
    private func extractLocalStreams() async throws -> [Stream] {
        let allStreamingData = try await self.streamingData
        let videoInfos = try await self.videoInfos

        var streams = [Stream]()
        var existingITags = Set<Int>()

        func process(streamingData: InnerTube.StreamingData, videoInfo: InnerTube.VideoInfo) async throws {

            try Task.checkCancellation()
            var streamManifest = Extraction.applyDescrambler(streamData: streamingData)

            do {
                try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
            } catch {
                // to force an update to the js file, we clear the cache and retry
                try Task.checkCancellation()
                if let url = _jsURL { Self.playerScripts.removeObject(forKey: url as NSURL) }
                _js = nil
                _jsURL = nil
                // Sway: 고정한 player로 실패했을 수 있으니 고정도 버리고 페이지가 준 player로 다시 한다.
                Self.playerPin.remove()
                usesPinnedPlayer = false
                try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
            }

            // filter out dubbed audio tracks
            streamManifest = Extraction.filterOutDubbedAudio(streamManifest: streamManifest)

            let newStreams = streamManifest.compactMap { try? Stream(format: $0) }

            // make sure only one stream per itag exists
            for stream in newStreams {
                if existingITags.insert(stream.itag.itag).inserted {
                    streams.append(stream)
                }
            }
        }

        for (streamingData, videoInfo) in zip(allStreamingData, videoInfos) {
            try await process(streamingData: streamingData, videoInfo: videoInfo)
        }

        // if no progressive (audio+video) tracks were found, try to do one more call to maybe get them
        if !streams.contains(where: { $0.includesVideoAndAudioTrack }) {
            if let videoInfo = try? await loadAdditionalVideoInfos(forClient: .mediaConnectFrontend), let streamingData = videoInfo.streamingData {
                os_log("Found no progressive streams. Called mediaConnectFrontend client to get additional video infos", log: log, type: .info)
                try await process(streamingData: streamingData, videoInfo: videoInfo)
            }
        }

        return streams
    }

    /// Sway: 공유한 player JS 주소·ytcfg로 InnerTube 응답만 받아 스트림을 만든다(watch 페이지 생략).
    /// 재생 가능(OK) 응답이 없거나 어떤 오류든 나면 nil을 돌려주고 인스턴스 상태를 비운다.
    /// 그러면 호출부가 원래 watch 페이지 경로로 처음부터 판정하므로 불가 영상의 오류 종류가 바뀌지 않는다.
    private func streamsUsingSharedPageContext(_ context: PageContext) async throws -> [Stream]? {
        _jsURL = context.jsURL
        _ytcfg = context.ytcfg
        do {
            let infos = try await videoInfos
            guard infos.contains(where: { $0.playabilityStatus?.status == "OK" && $0.streamingData != nil }) else {
                throw YouTubeKitError.extractError
            }
            let result = try await extractLocalStreams()
            // 서명 실패 복구로 watch 페이지를 새로 받았다면 새 player로 공유 문맥을 갱신한다.
            rememberPageContext()
            return result
        } catch {
            try Task.checkCancellation()
            os_log("Shared page context path failed for %{public}@, falling back to watch page: %{public}@", log: log, type: .info, videoID, error.localizedDescription)
            _js = nil
            _jsURL = nil
            usesPinnedPlayer = false
            _ytcfg = nil
            _videoInfos = nil
            _signatureTimestamp = nil
            return nil
        }
    }

    /// Sway: 이번 추출이 watch 페이지에서 얻은 player JS 주소·ytcfg를 다음 곡과 공유한다.
    /// 연령 제한 영상은 embed 페이지의 player를 쓰므로 공유하지 않는다.
    private func rememberPageContext() {
        guard _watchHTML != nil, _ageRestricted == false, let jsURL = _jsURL, let ytcfg = _ytcfg else { return }
        Self.pageContexts.store(PageContext(jsURL: jsURL, ytcfg: ytcfg, expiresAt: Date().addingTimeInterval(Self.pageContextLifetime)))
        Self.playerPin.pinIfAbsent(jsURL)
    }
#endif

    /// 다음 추출이 watch 페이지부터 다시 받게 한다. 재생 실패 후 주소 갱신·망 변경 때 호출한다.
    /// 고정한 player가 낡아 재생 주소가 거절됐을 수 있으므로 고정도 버린다.
    public static func invalidateSharedPageContext() {
        pageContexts.removeAll()
        playerPin.remove()
    }
    
    /// Returns a list of live streams - currently only HLS supported
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var livestreams: [Livestream] {
        get async throws {
            var livestreams = [Livestream]()
            let hlsURLs = try await streamingData.compactMap { $0.hlsManifestUrl }.compactMap { URL(string: $0) }
            livestreams.append(contentsOf: hlsURLs.map { Livestream(url: $0, streamType: .hls) })
            return livestreams
        }
    }

    /// streaming data from video info
    var streamingData: [InnerTube.StreamingData] {
        get async throws {
            let streamingData = try await videoInfos.compactMap { $0.streamingData }
            if !streamingData.isEmpty {
                return streamingData
            } else {
                if let videoInfo = try? await loadAdditionalVideoInfos(forClient: .webEmbed), let streamingData = videoInfo.streamingData {
                    _videoInfos = [videoInfo]
                    return [streamingData]
                }

                try await bypassAgeGate()
                let streamingData = try await videoInfos.compactMap { $0.streamingData }
                if !streamingData.isEmpty {
                    return streamingData
                } else {
                    throw YouTubeKitError.extractError
                }
            }
        }
    }

    /// Video details from video info.
    var videoDetails: [InnerTube.VideoInfo.VideoDetails] {
        get async throws {
            try await videoInfos.compactMap { $0.videoDetails }
        }
    }
    
    var videoInfos: [InnerTube.VideoInfo] {
        get async throws {
            if let cached = _videoInfos {
                return cached
            }
            
            // try extracting video infos from watch html directly as well
            let watchVideoInfoTask = Task<InnerTube.VideoInfo?, Never> { [log] in
                do {
                    return nil //try await Extraction.getVideoInfo(fromHTML: watchHTML)  // (temporarily disabled)
                } catch let error {
                    os_log("Couldn't extract video info from main watch html: %{public}@", log: log, type: .debug, error.localizedDescription)
                    return nil
                }
            }

            let signatureTimestamp = try await signatureTimestamp
            let ytcfg = try await ytcfg
            
            let innertubeClients: [InnerTube.ClientType] = [.visionOS, .web]
            
            let results: [Result<InnerTube.VideoInfo, Error>] = await innertubeClients.concurrentMap { [videoID, useOAuth, allowOAuthCache] client in
                let innertube = InnerTube(client: client, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
                
                do {
                    let innertubeResponse = try await innertube.player(videoID: videoID)
                    return .success(innertubeResponse)
                } catch let error {
                    return .failure(error)
                }
            }
            
            var videoInfos = [InnerTube.VideoInfo]()
            var errors = [Error]()
            
            for result in results {
                switch result {
                case .success(let innertubeResponse):
                    videoInfos.append(innertubeResponse)
                case .failure(let error):
                    errors.append(error)
                }
            }
            
            // append potentially extracted video info (with least priority)
            if let watchVideoInfo = await watchVideoInfoTask.value {
                videoInfos.append(watchVideoInfo)
            }
            
            // remove video infos with incorrect videoID
            for (i, videoInfo) in videoInfos.enumerated() where videoInfo.videoDetails?.videoId != videoID {
                os_log("Skipping player response from client %{public}i. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, i, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            }
            videoInfos = videoInfos.filter { $0.videoDetails?.videoId == videoID }
            
            if videoInfos.isEmpty {
                throw errors.first ?? YouTubeKitError.extractError
            }
            
            _videoInfos = videoInfos
            return videoInfos
        }
    }
    
    private func loadAdditionalVideoInfos(forClient client: InnerTube.ClientType) async throws -> InnerTube.VideoInfo {
        let signatureTimestamp = try await signatureTimestamp
        let ytcfg = if client == .webEmbed {
            try await Extraction.extractYtCfg(from: embedHTML)
        } else {
            try await ytcfg
        }
        let innertube = InnerTube(client: client, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
        let videoInfo = try await innertube.player(videoID: videoID)
        
        // ignore if incorrect videoID
        if videoInfo.videoDetails?.videoId != videoID {
            os_log("Skipping player response from %{public}@ client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, client.rawValue, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }
        
        return videoInfo
    }
    
    private func bypassAgeGate() async throws {
        let signatureTimestamp = try await signatureTimestamp
        let ytcfg = try await ytcfg
        let innertube = InnerTube(client: .webCreator, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
        let innertubeResponse = try await innertube.player(videoID: videoID)

        if innertubeResponse.playabilityStatus?.status == "UNPLAYABLE" || innertubeResponse.playabilityStatus?.status == "LOGIN_REQUIRED" {
            throw YouTubeKitError.videoAgeRestricted
        }

        if innertubeResponse.videoDetails?.videoId != videoID {
            os_log("Skipping player response from webCreator client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, innertubeResponse.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }

        _videoInfos = [innertubeResponse]
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /*public var streams: StreamQuery {
        get async throws {
            //try await checkAvailability()
            return StreamQuery(fmtStreams: try await fmtStreams)
        }
    }*/
    
}

/// Sway: watch 페이지에서 얻은, 영상과 무관한 player 문맥.
struct PageContext: @unchecked Sendable {
    let jsURL: URL
    let ytcfg: Extraction.YtCfg
    let expiresAt: Date
}

/// Sway: 여러 추출 작업이 동시에 읽고 쓰므로 잠금으로 보호한다.
final class PageContextStore: @unchecked Sendable {
    private let lock = NSLock()
    private var context: PageContext?

    func current(now: Date = Date()) -> PageContext? {
        lock.lock(); defer { lock.unlock() }
        guard let context, context.expiresAt > now else { context = nil; return nil }
        return context
    }

    func store(_ context: PageContext) {
        lock.lock(); defer { lock.unlock() }
        self.context = context
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        context = nil
    }
}

/// Sway: 앱을 다시 켜도 쓰는 player JS 주소 고정. 만든 뒤 `lifetime` 동안만 쓰고 성공해도 늘리지 않아
/// 오래된 player에 머물지 않는다. 서명 해석 실패·고정 player 내려받기 실패·앱의 주소 갱신 때 지운다.
/// 저장하는 것은 YouTube player 주소와 만든 시각뿐이다.
final class PlayerPinStore: @unchecked Sendable {
    private struct Pin: Codable { let url: URL; let pinnedAt: Date }
    private let lock = NSLock()
    private var file: URL?
    let lifetime: TimeInterval

    init(file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YouTubeKit/player-pin.json"),
         lifetime: TimeInterval = 48 * 60 * 60) {
        self.file = file
        self.lifetime = lifetime
    }

    var fileURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return file }
        set { lock.lock(); defer { lock.unlock() }; file = newValue }
    }

    func current(now: Date = Date()) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return load(now: now)
    }

    func pinIfAbsent(_ url: URL, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let file, Self.isPlayerScript(url), load(now: now) == nil,
              let data = try? JSONEncoder().encode(Pin(url: url, pinnedAt: now)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func remove() {
        lock.lock(); defer { lock.unlock() }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func load(now: Date) -> URL? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        guard let pin = try? JSONDecoder().decode(Pin.self, from: data), Self.isPlayerScript(pin.url),
              pin.pinnedAt <= now, now.timeIntervalSince(pin.pinnedAt) < lifetime else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return pin.url
    }

    static func isPlayerScript(_ url: URL) -> Bool {
        url.scheme == "https" && ["www.youtube.com", "youtube.com"].contains(url.host ?? "") && url.path.hasPrefix("/s/player/")
    }
}
