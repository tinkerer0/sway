import XCTest
import MusicCore
@testable import Sway

private final class ResolverClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private actor ControlledAudioLoader {
    private(set) var calls: [String] = []
    private var pending: [Int: CheckedContinuation<ResolvedAudio, Error>] = [:]
    func load(_ id: String) async throws -> ResolvedAudio {
        let index = calls.count; calls.append(id)
        // 취소에 늦게 응답하는 공급원도 새 캐시를 덮지 못하는지 검사한다.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, _ result: Result<ResolvedAudio, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}

final class AudioResolverTests: XCTestCase {
    private func audio(_ version: Int = 1, expiry: Double? = nil) -> ResolvedAudio {
        let query = expiry.map { "&expire=\($0)" } ?? ""
        return ResolvedAudio(url: URL(string: "https://example.invalid/audio?v=\(version)\(query)")!, bitrate: 131_000)
    }
    private func waitFor(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("조건이 충족되지 않았음", file: file, line: line)
        throw URLError(.timedOut)
    }
    private func expectCancelled(_ task: Task<ResolvedAudio, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("취소를 기대함", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, file: file, line: line) }
    }

    func testRefreshAndNetworkInvalidationDropSharedSourceContextButCacheHitDoesNot() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var value = 0
            func add() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let source = ControlledAudioLoader(), dropped = Counter()
        let resolver = AudioResolver(invalidateSource: { dropped.add() }, loader: { try await source.load($0) })
        let first = Task { try await resolver.resolve("a") }
        try await waitFor { await source.calls.count == 1 }
        await source.finish(0, .success(audio()))
        _ = try await first.value
        _ = try await resolver.resolve("a")
        XCTAssertEqual(dropped.count, 0)
        let renewed = Task { try await resolver.resolve("a", refreshing: true) }
        try await waitFor { await source.calls.count == 2 }
        XCTAssertEqual(dropped.count, 1)
        await source.finish(1, .success(audio(2)))
        _ = try await renewed.value
        await resolver.invalidateAll()
        XCTAssertEqual(dropped.count, 2)
    }

    func testSameSongSharesWorkAndCancelledPrefetchDoesNotCancelPlayback() async throws {
        let source = ControlledAudioLoader()
        let resolver = AudioResolver(loader: { try await source.load($0) })
        let prefetch = Task { try await resolver.resolve("a") }
        try await waitFor { await resolver.metrics().consumers == 1 }
        let playback = Task { try await resolver.resolve("a") }
        try await waitFor { await resolver.metrics().consumers == 2 }
        prefetch.cancel(); await expectCancelled(prefetch)
        let metrics = await resolver.metrics(); XCTAssertEqual(metrics.loads, 1); XCTAssertEqual(metrics.joins, 1)
        await source.finish(0, .success(audio()))
        let played = try await playback.value
        let repeated = try await resolver.resolve("a")
        XCTAssertEqual(played.url, repeated.url)
        let after = await resolver.metrics(); XCTAssertEqual(after.loads, 1); XCTAssertEqual(after.cacheHits, 1)
    }

    func testCancelledLastConsumerReturnsPromptlyAndLateResultCannotReplaceFreshOne() async throws {
        let source = ControlledAudioLoader(), resolver = AudioResolver(loader: { try await source.load($0) })
        let old = Task { try await resolver.resolve("a") }
        try await waitFor { await source.calls.count == 1 }
        old.cancel(); await expectCancelled(old)
        let replacement = Task { try await resolver.resolve("a") }
        try await waitFor { await source.calls.count == 2 }
        await source.finish(1, .success(audio(2)))
        _ = try await replacement.value
        await source.finish(0, .success(audio(1)))
        let cached = try await resolver.resolve("a")
        XCTAssertEqual(cached.url, audio(2).url)
    }

    func testForcedRefreshReplacesBothCachedAndInFlightResults() async throws {
        let source = ControlledAudioLoader(), resolver = AudioResolver(loader: { try await source.load($0) })
        let old = Task { try await resolver.resolve("a") }
        try await waitFor { await source.calls.count == 1 }
        let fresh = Task { try await resolver.resolve("a", refreshing: true) }
        try await waitFor { await source.calls.count == 2 }
        await expectCancelled(old)
        await source.finish(0, .success(audio(1)))
        await source.finish(1, .success(audio(2)))
        let freshValue = try await fresh.value
        XCTAssertEqual(freshValue.url, audio(2).url)
        let newer = Task { try await resolver.resolve("a", refreshing: true) }
        try await waitFor { await source.calls.count == 3 }
        await source.finish(2, .success(audio(3)))
        let newerValue = try await newer.value
        XCTAssertEqual(newerValue.url, audio(3).url)
    }

    func testExpirySafetyMarginUnknownExpiryAndTenMinuteCap() async throws {
        let clock = ResolverClock(), source = ControlledAudioLoader()
        let resolver = AudioResolver(now: { clock.now() }, loader: { try await source.load($0) })
        for (index, lifetime) in [120.0, 60.0, 600.0].enumerated() {
            let id = "song-\(index)"
            let first = Task { try await resolver.resolve(id) }
            try await waitFor { await source.calls.count == index * 2 + 1 }
            let expiry = index == 0 ? clock.now().timeIntervalSince1970 + 180 : index == 2 ? clock.now().timeIntervalSince1970 + 3600 : nil
            await source.finish(index * 2, .success(audio(expiry: expiry)))
            _ = try await first.value
            clock.advance(lifetime - 1)
            _ = try await resolver.resolve(id)
            clock.advance(2)
            let again = Task { try await resolver.resolve(id) }
            try await waitFor { await source.calls.count == index * 2 + 2 }
            await source.finish(index * 2 + 1, .success(audio(2)))
            _ = try await again.value
        }
        let metrics = await resolver.metrics(); XCTAssertEqual(metrics.loads, 6); XCTAssertEqual(metrics.cacheHits, 3)
    }

    func testFailureIsNotCachedAndInvalidationClearsSuccessfulResults() async throws {
        let source = ControlledAudioLoader(), resolver = AudioResolver(loader: { try await source.load($0) })
        let failed = Task { try await resolver.resolve("a") }
        try await waitFor { await source.calls.count == 1 }
        await source.finish(0, .failure(URLError(.badServerResponse)))
        do { _ = try await failed.value; XCTFail("실패를 기대함") } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        let success = Task { try await resolver.resolve("a") }
        try await waitFor { await source.calls.count == 2 }
        await source.finish(1, .success(audio()))
        _ = try await success.value
        await resolver.invalidateAll()
        let next = Task { try await resolver.resolve("a") }
        try await waitFor { await source.calls.count == 3 }
        await source.finish(2, .success(audio(2)))
        _ = try await next.value
    }

    func testLRUEvictsLeastRecentlyUsedURL() async throws {
        let source = ControlledAudioLoader(), resolver = AudioResolver(capacity: 2, loader: { try await source.load($0) })
        for (index, id) in ["a", "b", "c"].enumerated() {
            if id == "c" { _ = try await resolver.resolve("a") }
            let pending = Task { try await resolver.resolve(id) }
            try await waitFor { await source.calls.count == index + 1 }
            await source.finish(index, .success(audio(index)))
            _ = try await pending.value
        }
        _ = try await resolver.resolve("a")
        let evicted = Task { try await resolver.resolve("b") }
        try await waitFor { await source.calls.count == 4 }
        await source.finish(3, .success(audio(4)))
        _ = try await evicted.value
    }
    @MainActor func testNoLaunchWarmupAndNextAddressStartsOnlyAfterActualPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("silence.wav")
        let bytes = 16_000 * 2 * 5
        var wave = Data()
        func word(_ value: UInt32, count: Int) {
            for byte in 0..<count { wave.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        wave.append(contentsOf: "RIFF".utf8); word(UInt32(36 + bytes), count: 4)
        wave.append(contentsOf: "WAVEfmt ".utf8); word(16, count: 4); word(1, count: 2)
        word(1, count: 2); word(16_000, count: 4); word(32_000, count: 4)
        word(2, count: 2); word(16, count: 2); wave.append(contentsOf: "data".utf8)
        word(UInt32(bytes), count: 4); wave.append(Data(count: bytes)); try wave.write(to: file)
        let source = ControlledAudioLoader(), resolver = AudioResolver(loader: { try await source.load($0) })
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let controller = PlaybackController(library: store, resolver: resolver, monitorNetwork: false)
        defer { controller.pause(); controller.setForeground(false) }
        controller.setForeground(true)
        for _ in 0..<10 { await Task.yield() }
        let initial = await resolver.metrics(); XCTAssertEqual(initial.loads, 0)
        let a = Track(id: "aaaaaaaaaaa", title: "A", artist: "Test")
        let b = Track(id: "bbbbbbbbbbb", title: "B", artist: "Test")
        controller.play([a, b])
        try await waitFor { await source.calls.count == 1 }
        controller.shuffle(); controller.shuffle()
        let loading = await resolver.metrics(); XCTAssertEqual(loading.loads, 1)
        await source.finish(0, .success(ResolvedAudio(url: file, bitrate: 131_000)))
        try await waitFor { controller.isPlaying && controller.elapsed > 0.05 }
        try await waitFor { await source.calls.count == 2 }
        controller.shuffle(); controller.shuffle()
        controller.next()
        try await waitFor { await resolver.metrics().consumers == 2 }
        let shared = await resolver.metrics(); XCTAssertEqual(shared.loads, 2); XCTAssertEqual(shared.joins, 1)
        controller.pause()
        await source.finish(1, .success(ResolvedAudio(url: file, bitrate: 131_000)))
        try await waitFor { await resolver.metrics().consumers == 0 }
        XCTAssertFalse(controller.wantsPlayback)
    }

    @MainActor func testFullySavedSongPlaysWithoutAddressLookupEvenOffline() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = AudioCache(directory: cacheDirectory, limitBytes: { 1 << 20 })
        cache.prepare("aaaaaaaaaaa", contentLength: 4, duration: 1, bitrate: 131_000)
        cache.write("aaaaaaaaaaa", offset: 0, data: Data([0, 0, 0, 0]))
        let source = ControlledAudioLoader(), resolver = AudioResolver(loader: { try await source.load($0) })
        let controller = PlaybackController(library: LibraryStore(fileURL: path), resolver: resolver, monitorNetwork: false, audioCache: cache)
        defer { controller.pause(); controller.setForeground(false) }
        controller.networkChanged(true, signature: "wifi")
        controller.networkChanged(false, signature: "offline")
        controller.play([Track(id: "aaaaaaaaaaa", title: "A", artist: "Test")])
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await source.calls.count; XCTAssertEqual(calls, 0)
        // 시험용 4바이트 파일은 재생되지 않지만, 저장본 정보로 재생을 시작했고 주소 조회는 하지 않았다.
        XCTAssertTrue(controller.wantsPlayback)
        XCTAssertEqual(controller.bitrate, 131_000)
    }

    @MainActor func testNetworkChangeRenewsPendingLookupAndOfflinePlayDoesNotFetch() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let source = ControlledAudioLoader(), resolver = AudioResolver(loader: { try await source.load($0) })
        let controller = PlaybackController(library: LibraryStore(fileURL: path), resolver: resolver, monitorNetwork: false)
        defer { controller.pause(); controller.setForeground(false) }
        let a = Track(id: "aaaaaaaaaaa", title: "A", artist: "Test")
        controller.networkChanged(true, signature: "wifi")
        controller.play([a])
        try await waitFor { await source.calls.count == 1 }
        controller.networkChanged(true, signature: "cellular")
        try await waitFor { await source.calls.count == 2 }
        controller.networkChanged(false, signature: "offline")
        controller.play([a])
        for _ in 0..<10 { await Task.yield() }
        let offlineCalls = await source.calls.count; XCTAssertEqual(offlineCalls, 2)
        controller.networkChanged(true, signature: "wifi")
        try await waitFor { await source.calls.count == 3 }
        controller.pause()
        let local = ResolvedAudio(url: URL(fileURLWithPath: "/dev/null"), bitrate: 131_000)
        for index in 0..<3 { await source.finish(index, .success(local)) }
        try await waitFor { await resolver.metrics().consumers == 0 }
        XCTAssertFalse(controller.wantsPlayback); XCTAssertEqual(controller.current?.id, a.id)
    }

}
