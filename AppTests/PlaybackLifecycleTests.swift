import XCTest
import AVFoundation
import MusicCore
@testable import Sway

private actor LifecycleResolver: AudioResolving {
    private(set) var calls = 0
    let url: URL
    init(url: URL) { self.url = url }
    func invalidateAll() {}
    func resolve(_ id: String, refreshing: Bool) async throws -> ResolvedAudio {
        calls += 1
        try await Task.sleep(nanoseconds: 500_000_000)
        return ResolvedAudio(url: url, bitrate: 128_000)
    }
}

@MainActor final class PlaybackLifecycleTests: XCTestCase {
    private let a = Track(id: "aaaaaaaaaaa", title: "Seed", artist: "Artist", duration: 180)
    private let b = Track(id: "bbbbbbbbbbb", title: "Next", artist: "Artist", duration: 200)
    private let c = Track(id: "ccccccccccc", title: "Later", artist: "Artist", duration: 240)
    private func fixture() throws -> (URL, LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, LibraryStore(fileURL: root.appendingPathComponent("library.json")))
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("상태 전환 시간 초과"); throw URLError(.timedOut)
    }
    func testPlayClaimsSessionBeforeLookupAndKeepsBackgroundLeaseUntilCancelled() throws {
        let (_, store) = try fixture()
        try AVAudioSession.sharedInstance().setCategory(.soloAmbient)  // 앱을 처음 켠 상태
        let controller = PlaybackController(library: store, resolver: SlowResolver(), monitorNetwork: false)
        controller.setForeground(true)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        controller.play([a])
        // await 전에 재생 카테고리를 잡아야 곡 선택 직후 잠금도 이어진다.
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(controller.hasBackgroundWork)
        controller.setForeground(false)
        XCTAssertTrue(controller.wantsPlayback); XCTAssertTrue(controller.hasBackgroundWork)
        controller.pause()
        XCTAssertFalse(controller.hasBackgroundWork); XCTAssertFalse(controller.isLoading)
    }
    func testPauseKeepsPlaybackSessionSoSwayStaysNowPlaying() throws {
        let (_, store) = try fixture()
        try AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        let controller = PlaybackController(library: store, resolver: SlowResolver(), monitorNetwork: false)
        defer { controller.setForeground(false) }
        controller.setForeground(true)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        controller.play([a]); controller.pause(); controller.setForeground(true)
        // 섞어 재생으로 돌아가면 iOS가 NowPlaying 앱을 다른 앱으로 넘겨, 다음 곡을 누르고 바로 잠글 때 재생이 거절된다.
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
    }
    func testExpirationStopsPendingStartAndInterruptionNeverResumesWithoutConsent() throws {
        let (_, store) = try fixture()
        let controller = PlaybackController(library: store, resolver: SlowResolver(), monitorNetwork: false)
        controller.play([a]); controller.setForeground(false); controller.expireBackgroundWork()
        XCTAssertFalse(controller.wantsPlayback); XCTAssertFalse(controller.hasBackgroundWork)
        XCTAssertFalse(controller.isLoading); XCTAssertNotNil(controller.message)
        controller.resume(); XCTAssertTrue(controller.hasBackgroundWork)
        controller.handleInterruption(began: true)
        XCTAssertFalse(controller.hasBackgroundWork); XCTAssertFalse(controller.showsPause)
        controller.pause(); controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertFalse(controller.wantsPlayback)
    }
    func testDelayedResolutionStartsAfterBackgroundTransitionAndReleasesLeaseWhenPlaying() async throws {
        let (root, store) = try fixture()
        let file = root.appendingPathComponent("silence.wav")
        let count = 16_000 * 2 * 8
        var wave = Data()
        func word(_ value: UInt32, _ bytes: Int) {
            for byte in 0..<bytes { wave.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        wave.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count), 4)
        wave.append(contentsOf: "WAVEfmt ".utf8); word(16, 4); word(1, 2); word(1, 2)
        word(16_000, 4); word(32_000, 4); word(2, 2); word(16, 2)
        wave.append(contentsOf: "data".utf8); word(UInt32(count), 4); wave.append(Data(count: count))
        try wave.write(to: file)
        let resolver = LifecycleResolver(url: file)
        let controller = PlaybackController(library: store, resolver: resolver, monitorNetwork: false)
        defer { controller.pause(); controller.setForeground(false) }
        controller.setForeground(true); controller.play([a]); controller.setForeground(false)
        XCTAssertTrue(controller.hasBackgroundWork); XCTAssertFalse(controller.isPlaying)
        try await waitFor { controller.isPlaying && controller.elapsed > 0.05 }
        XCTAssertFalse(controller.hasBackgroundWork)
        XCTAssertEqual(controller.current?.id, a.id)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
    }
    func testMixRestoresOriginalSeedQueuePositionAndStaysPausedWithoutNetwork() async throws {
        let (root, store) = try fixture()
        var queue = PlaybackQueue(); queue.start([a], at: 0); queue.enableMix(seed: a, candidates: [b, c]); queue.jump(to: 1)
        store.checkpoint(queue, position: 42)
        let resolver = LifecycleResolver(url: root.appendingPathComponent("unused.wav"))
        let restored = PlaybackController(library: LibraryStore(fileURL: root.appendingPathComponent("library.json")), resolver: resolver, monitorNetwork: false)
        restored.setForeground(true)
        XCTAssertTrue(restored.mixActive); XCTAssertEqual(restored.queue.mixSeed?.id, a.id)
        XCTAssertEqual(restored.queue.tracks.map(\.id), [a.id, b.id, c.id]); XCTAssertEqual(restored.queue.index, 1)
        XCTAssertEqual(restored.current?.id, b.id); XCTAssertEqual(restored.elapsed, 42)
        XCTAssertFalse(restored.wantsPlayback); XCTAssertFalse(restored.hasBackgroundWork)
        for _ in 0..<10 { await Task.yield() }
        let calls = await resolver.calls; XCTAssertEqual(calls, 0)
        restored.stopMix(); restored.setForeground(false)
        let stopped = PlaybackController(library: LibraryStore(fileURL: root.appendingPathComponent("library.json")), resolver: resolver, monitorNetwork: false)
        XCTAssertFalse(stopped.mixActive); XCTAssertEqual(stopped.queue.tracks.map(\.id), [b.id])
    }
    func testMixIntentIsSavedWhileRecommendationsLoadAndNewSelectionClearsIt() async throws {
        let (root, store) = try fixture()
        let controller = PlaybackController(library: store, resolver: SlowResolver(), monitorNetwork: false,
            mixLoader: { _, _, _ in try await Task.sleep(nanoseconds: 60_000_000_000); return [] })
        defer { controller.stopMix(); controller.pause() }
        controller.startMix(a)
        XCTAssertTrue(controller.isMixLoading)
        let restored = PlaybackController(library: LibraryStore(fileURL: root.appendingPathComponent("library.json")), resolver: SlowResolver(), monitorNetwork: false)
        XCTAssertTrue(restored.mixActive); XCTAssertEqual(restored.queue.mixSeed?.id, a.id)
        controller.play([b, c], at: 1)
        let snapshot = try LibraryFile(url: root.appendingPathComponent("library.json")).load()
        XCTAssertNil(snapshot.playbackSession?.mixSeed)
        XCTAssertEqual(snapshot.playbackSession?.index, 1); XCTAssertEqual(snapshot.lastTrackID, c.id)
    }
}
