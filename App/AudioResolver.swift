import Foundation
import YouTubeKit

enum YouTubeAudioSource {
    static func resolve(_ id: String) async throws -> ResolvedAudio {
        let streams: [YouTubeKit.Stream]
        do { streams = try await YouTube(videoID: id, useOAuth: false, allowOAuthCache: false, methods: [.local]).streams }
        catch let error as YouTubeKitError {
            switch error {
            case .videoUnavailable, .videoPrivate, .videoAgeRestricted, .membersOnly, .videoRegionBlocked, .recordingUnavailable, .liveStreamError: throw AudioError.unavailable
            default: throw error
            }
        }
        try Task.checkCancellation()
        let audio = streams.filterAudioOnly().filter { $0.isNativelyPlayable }
        // MP4 AAC를 우선한다. 영상이 섞인 스트림을 대체 수단으로 받지 않는다.
        let aac = audio.filter {
            let itag = URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "itag" }?.value
            return ["139", "140", "141"].contains(itag ?? "")
        }
        guard let best = aac.highestAudioBitrateStream() else { throw AudioError.unavailable }
        let rawDuration = URLComponents(url: best.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dur" }?.value
        let duration = rawDuration.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 && $0 < 604800 ? $0 : nil }
        return ResolvedAudio(url: best.url, bitrate: best.bitrate ?? 0, duration: duration)
    }
    /// 곡 사이에 공유하는 player 문맥을 버린다. 다음 조회는 watch 페이지부터 다시 받는다.
    static func invalidateSharedContext() { YouTube.invalidateSharedPageContext() }
}
