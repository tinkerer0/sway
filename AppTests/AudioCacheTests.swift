import XCTest
@testable import Sway

final class AudioCacheTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
    }

    func testRangesMergeAndReadOnlyStoredBytes() {
        XCTAssertEqual(AudioCache.merge([[10, 20], [0, 5], [5, 10], [30, 40], [35, 50]]), [[0, 20], [30, 50]])
        let cache = AudioCache(directory: directory, limitBytes: { 1 << 20 })
        cache.prepare("aaaaaaaaaaa", contentLength: 100, duration: 10, bitrate: 128_000)
        cache.write("aaaaaaaaaaa", offset: 0, data: Data(0..<40))
        cache.write("aaaaaaaaaaa", offset: 60, data: Data(60..<80))
        XCTAssertEqual(cache.read("aaaaaaaaaaa", offset: 10, length: 100), Data(10..<40))
        XCTAssertNil(cache.read("aaaaaaaaaaa", offset: 40, length: 5))
        XCTAssertEqual(cache.availableEnd("aaaaaaaaaaa", from: 5), 40)
        XCTAssertEqual(cache.availableEnd("aaaaaaaaaaa", from: 45), 45)
        XCTAssertEqual(cache.nextStoredStart("aaaaaaaaaaa", after: 40), 60)
        XCTAssertFalse(cache.isComplete("aaaaaaaaaaa"))
        cache.write("aaaaaaaaaaa", offset: 40, data: Data(40..<60))
        cache.write("aaaaaaaaaaa", offset: 80, data: Data(80..<100))
        XCTAssertTrue(cache.isComplete("aaaaaaaaaaa"))
        XCTAssertEqual(try Data(contentsOf: cache.completeFile("aaaaaaaaaaa")!.url), Data(0..<100))
    }

    func testDifferentSourceLengthDiscardsOldBytesAndInvalidIDIsRejected() {
        let cache = AudioCache(directory: directory, limitBytes: { 1 << 20 })
        cache.prepare("aaaaaaaaaaa", contentLength: 10, duration: 1, bitrate: 1)
        cache.write("aaaaaaaaaaa", offset: 0, data: Data(repeating: 1, count: 10))
        XCTAssertTrue(cache.isComplete("aaaaaaaaaaa"))
        cache.prepare("aaaaaaaaaaa", contentLength: 12, duration: 1, bitrate: 1)
        XCTAssertEqual(cache.meta("aaaaaaaaaaa")?.stored, 0)
        XCTAssertNil(cache.prepare("../escape", contentLength: 10, duration: 1, bitrate: 1))
        // 범위를 벗어난 쓰기는 무시한다.
        cache.write("aaaaaaaaaaa", offset: 8, data: Data(repeating: 2, count: 8))
        XCTAssertEqual(cache.meta("aaaaaaaaaaa")?.stored, 0)
    }

    func testLimitEvictsLeastRecentlyUsedButKeepsPlayingSong() {
        let clock = Clock()
        let limit = LockedInt(250)
        let cache = AudioCache(directory: directory, limitBytes: { limit.value }, now: { clock.now() })
        for id in ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"] {
            cache.prepare(id, contentLength: 100, duration: 1, bitrate: 1)
            cache.write(id, offset: 0, data: Data(repeating: 0, count: 100))
            clock.advance(10)
        }
        _ = cache.completeFile("aaaaaaaaaaa")   // 다시 들어 가장 최근이 된다.
        cache.enforceLimit(protecting: ["bbbbbbbbbbb"])
        XCTAssertNotNil(cache.meta("aaaaaaaaaaa")); XCTAssertNotNil(cache.meta("bbbbbbbbbbb")); XCTAssertNil(cache.meta("ccccccccccc"))
        XCTAssertEqual(cache.totalBytes, 200)
        limit.value = 0
        XCTAssertFalse(cache.isEnabled)
        cache.enforceLimit(protecting: ["bbbbbbbbbbb"])
        XCTAssertNil(cache.meta("aaaaaaaaaaa")); XCTAssertNotNil(cache.meta("bbbbbbbbbbb"))
    }

    func testFragmentOffsetsFromSidx() {
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        let ftyp = u32(16) + Array("ftyp".utf8) + [UInt8](repeating: 0, count: 8)
        // version 0, flags, reference_ID, timescale, earliest_presentation_time, first_offset, reserved, count=3
        var sidx = Array("sidx".utf8) + [0, 0, 0, 0] + u32(1) + u32(44_100) + u32(0) + u32(0) + [0, 0, 0, 3]
        for size in [100, 200, 300] { sidx += u32(size) + u32(441_000) + u32(0x9000_0000) }
        sidx = u32(sidx.count + 4) + sidx
        let offsets = CachingAudioLoader.fragmentOffsets(Data(ftyp + sidx))
        let start = ftyp.count + sidx.count
        XCTAssertEqual(offsets, [start, start + 100, start + 300])
        XCTAssertEqual(CachingAudioLoader.fragmentOffsets(Data(ftyp)), [])
        XCTAssertEqual(CachingAudioLoader.fragmentOffsets(Data(ftyp + Array(sidx.prefix(20)))), [])
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Int
    init(_ value: Int) { stored = value }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
