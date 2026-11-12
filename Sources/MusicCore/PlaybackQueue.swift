import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable { case off, all, one }

/// 재생 주소·음원 바이트·자동 재생 의도 없이 대기열과 믹스의 기준만 보존한다.
public struct PlaybackSession: Codable, Sendable {
    public var tracks: [Track]
    public var index: Int
    public var repeatMode: RepeatMode
    public var mixSeed: Track?
    public var position: Double
    public init(queue: PlaybackQueue, position: Double) {
        tracks = queue.tracks; index = queue.index; repeatMode = queue.repeatMode; mixSeed = queue.mixSeed
        self.position = position.isFinite ? max(0, position) : 0
    }
}

public struct PlaybackQueue: Sendable {
    public private(set) var tracks: [Track] = []
    public private(set) var index = 0
    public var repeatMode: RepeatMode = .off
    public private(set) var mixSeed: Track?
    public var current: Track? { tracks.indices.contains(index) ? tracks[index] : nil }
    public var remaining: Int { max(0, tracks.count - index - 1) }
    public init() {}
    public init?(restoring session: PlaybackSession) {
        guard session.tracks.indices.contains(session.index), session.tracks.allSatisfy({ Track.validID($0.id) }),
              session.mixSeed.map({ Track.validID($0.id) }) ?? true else { return nil }
        tracks = session.tracks; index = session.index; mixSeed = session.mixSeed
        repeatMode = mixSeed == nil ? session.repeatMode : .off
    }
    public mutating func start(_ tracks: [Track], at index: Int) {
        self.tracks = tracks; self.index = tracks.indices.contains(index) ? index : 0; mixSeed = nil
    }
    @discardableResult public mutating func advance(automatically: Bool = false) -> Bool {
        guard current != nil else { return false }
        if automatically && repeatMode == .one { return true }
        if index + 1 < tracks.count { index += 1; return true }
        if repeatMode == .all && mixSeed == nil { index = 0; return true }
        return false
    }
    public mutating func previous() { index = max(0, index - 1) }
    public mutating func jump(to position: Int) { if tracks.indices.contains(position) { index = position } }
    public mutating func enableMix(seed: Track, candidates: [Track]) {
        tracks = [current ?? seed] + MixPolicy.candidates(candidates, excluding: [seed.id]); index = 0
        mixSeed = seed; repeatMode = .off
    }
    public mutating func appendMix(_ candidates: [Track]) {
        guard mixSeed != nil else { return }
        tracks.append(contentsOf: MixPolicy.candidates(candidates, excluding: Set(tracks.map(\.id))))
    }
    public mutating func stopMix() {
        if let current { tracks = [current] } else { tracks = [] }
        index = 0; mixSeed = nil
    }
    public mutating func shuffleRemaining() {
        guard remaining > 1 else { return }
        let start = index + 1
        tracks.replaceSubrange(start..., with: tracks[start...].shuffled())
    }
}
