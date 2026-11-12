import XCTest
@testable import Sway

/// 2026-10-20 외부 검토(GPT-6-Astra)가 재현한 로더 결함의 회귀 시험. 네트워크 대신 주입한 응답을 쓴다.
final class CachingAudioLoaderTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private actor Transport {
        enum Mode { case ok, forbidden, wrongStart }
        let mode: Mode
        private(set) var ranges: [String] = []
        private(set) var refreshes = 0
        init(_ mode: Mode) { self.mode = mode }
        func refresh() -> URL { refreshes += 1; return URL(string: "https://example.invalid/audio?clen=1000000")! }
        func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let range = request.value(forHTTPHeaderField: "Range")!
            ranges.append(range)
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let start = mode == .wrongStart ? 0 : bounds[0]
            let body = Data(repeating: 7, count: bounds[1] - bounds[0] + 1)
            let response = HTTPURLResponse(url: request.url!, statusCode: mode == .forbidden ? 403 : 206, httpVersion: nil,
                                           headerFields: ["Content-Range": "bytes \(start)-\(start + body.count - 1)/1000000"])!
            return (body, response)
        }
    }

    private func makeLoader(_ cache: AudioCache, _ transport: Transport) -> CachingAudioLoader {
        // 100초·1,000,000바이트 → 초당 10,000바이트. 40초 고수위 = 400,000바이트.
        let audio = ResolvedAudio(url: URL(string: "https://example.invalid/audio?clen=1000000")!, bitrate: 80_000, duration: 100)
        return CachingAudioLoader(id: "bbbbbbbbbbb", audio: audio, cache: cache,
                                  fetch: { try await transport.fetch($0) }, refresh: { await transport.refresh() })!
    }
    private func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    func testFillsOnlyUpToHighWaterAheadOfPlayhead() async throws {
        let cache = AudioCache(directory: directory, limitBytes: { 1 << 30 }), transport = Transport(.ok)
        let loader = makeLoader(cache, transport); defer { loader.cancel() }
        loader.updatePlayhead(0); try await settle()
        XCTAssertEqual(cache.availableEnd("bbbbbbbbbbb", from: 0), 400_000)
        loader.updatePlayhead(30); try await settle()   // 앞선 양 10초 < 저수위 20초 → 70초까지 채운다.
        XCTAssertEqual(cache.availableEnd("bbbbbbbbbbb", from: 0), 700_000)
    }

    func testDeletedCacheDoesNotRefetchSameRangeForever() async throws {
        let cache = AudioCache(directory: directory, limitBytes: { 1 << 30 }), transport = Transport(.ok)
        let loader = makeLoader(cache, transport); defer { loader.cancel() }
        // 늦게 실행된 정리는 사용 중인 곡을 지우지 않는다.
        cache.removeAll(protecting: ["aaaaaaaaaaa"])
        XCTAssertNotNil(cache.meta("bbbbbbbbbbb"))
        // 명시적으로 지워 쓰기가 실패해도 같은 구간을 반복해 받지 않는다.
        cache.remove("bbbbbbbbbbb")
        for _ in 0..<5 { loader.updatePlayhead(0); try await Task.sleep(nanoseconds: 40_000_000) }
        let fetches = await transport.ranges.count
        XCTAssertEqual(fetches, 1)
    }

    func testRejectsResponseWhoseContentRangeDoesNotMatchRequest() async throws {
        let cache = AudioCache(directory: directory, limitBytes: { 1 << 30 }), transport = Transport(.wrongStart)
        let loader = makeLoader(cache, transport); defer { loader.cancel() }
        loader.updatePlayhead(50); try await settle()
        XCTAssertEqual(cache.meta("bbbbbbbbbbb")?.ranges, [])
    }

    func testExhaustedRefreshStopsUntilNetworkChanges() async throws {
        let cache = AudioCache(directory: directory, limitBytes: { 1 << 30 }), transport = Transport(.forbidden)
        let loader = makeLoader(cache, transport); defer { loader.cancel() }
        loader.updatePlayhead(0); try await settle()
        let refreshes = await transport.refreshes, fetches = await transport.ranges.count
        XCTAssertEqual(refreshes, 2); XCTAssertEqual(fetches, 3)
        for _ in 0..<4 { loader.updatePlayhead(0); try await Task.sleep(nanoseconds: 30_000_000) }
        let afterTicks = await transport.refreshes; XCTAssertEqual(afterTicks, 2)
        loader.markSourceStale(); try await settle()   // 새 망에서는 다시 시도한다.
        let afterNetwork = await transport.refreshes; XCTAssertGreaterThan(afterNetwork, 2)
    }

    func testMalformedSidxDoesNotCrash() {
        XCTAssertEqual(CachingAudioLoader.fragmentOffsets(Data([0, 0, 0, 8, 115, 105, 100, 120])), [])
        XCTAssertEqual(CachingAudioLoader.fragmentOffsets(Data([0, 0, 0, 12, 115, 105, 100, 120, 1, 0, 0, 0])), [])
        XCTAssertEqual(CachingAudioLoader.fragmentOffsets(Data([255, 255, 255, 255, 115, 105, 100, 120])), [])
    }

    func testTruncatedFileIsNotTreatedAsComplete() throws {
        let cache = AudioCache(directory: directory, limitBytes: { 1 << 20 })
        cache.prepare("aaaaaaaaaaa", contentLength: 100, duration: 1, bitrate: 1)
        cache.write("aaaaaaaaaaa", offset: 0, data: Data(repeating: 1, count: 100))
        let handle = try FileHandle(forWritingTo: cache.fileURL("aaaaaaaaaaa"))
        try handle.truncate(atOffset: 40); try handle.close()
        XCTAssertNil(cache.completeFile("aaaaaaaaaaa"))
        XCTAssertEqual(cache.availableEnd("aaaaaaaaaaa", from: 0), 40)
    }
}
