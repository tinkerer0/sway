import XCTest
import AVFoundation
import MusicCore
@testable import Sway

actor SlowResolver: AudioResolving {
    func invalidateAll() {}
    func resolve(_ id: String, refreshing: Bool) async throws -> ResolvedAudio {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}
actor FailingConnection: AudioResolving {
    func invalidateAll() {}
    func resolve(_ id: String, refreshing: Bool) async throws -> ResolvedAudio { throw URLError(.dataNotAllowed) }
}

@MainActor final class PlaybackTests: XCTestCase {
    let a = Track(id: "aaaaaaaaaaa", title: "A", artist: "Test")
    let b = Track(id: "bbbbbbbbbbb", title: "B", artist: "Test")
    private func store() -> LibraryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
    }
    func testForegroundPreparesMediaSessionWithoutStartingPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false)
        try session.setCategory(.soloAmbient)
        let controller = PlaybackController(library: store(), resolver: SlowResolver(), monitorNetwork: false)
        defer { controller.setForeground(false) }
        controller.setForeground(true)
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertNil(controller.current)
        XCTAssertFalse(controller.wantsPlayback)
        XCTAssertFalse(controller.isPlaying)
    }
    func testForegroundDuringInterruptionDoesNotTakeAudioSession() throws {
        let controller = PlaybackController(library: store(), resolver: SlowResolver(), monitorNetwork: false)
        controller.handleInterruption(began: true)
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false)
        try session.setCategory(.soloAmbient)
        controller.setForeground(true)
        XCTAssertEqual(session.category, .soloAmbient)
        controller.handleInterruption(began: false)
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertFalse(controller.wantsPlayback)
        controller.setForeground(false)
    }
    func testPausedItemFailureDoesNotResume() async {
        let controller = PlaybackController(library: store(), resolver: SlowResolver(), monitorNetwork: false)
        controller.play([a, b]); controller.pause(); controller.handleItemFailure()
        XCTAssertFalse(controller.wantsPlayback); XCTAssertFalse(controller.showsPause)
        XCTAssertEqual(controller.current?.id, a.id)
    }
    func testExplicitPlayRecoversWithoutInterruptionEnd() async {
        let controller = PlaybackController(library: store(), resolver: SlowResolver(), monitorNetwork: false)
        controller.play([a]); controller.handleInterruption(began: true)
        XCTAssertFalse(controller.showsPause)
        controller.resume()
        XCTAssertTrue(controller.wantsPlayback); XCTAssertTrue(controller.showsPause)
        controller.pause()
    }
    func testManualPauseDuringInterruptionPreventsAutoResume() async {
        let controller = PlaybackController(library: store(), resolver: SlowResolver(), monitorNetwork: false)
        controller.play([a]); controller.handleInterruption(began: true); controller.pause()
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertFalse(controller.wantsPlayback)
    }
    func testLateInterruptionEndDoesNotUndoExplicitPlay() async {
        let controller = PlaybackController(library: store(), resolver: SlowResolver(), monitorNetwork: false)
        controller.play([a]); controller.handleInterruption(began: true); controller.resume()
        controller.handleInterruption(began: false, shouldResume: false)
        XCTAssertTrue(controller.wantsPlayback); controller.pause()
    }
    func testConnectionFailureRetriesSameTrackThenStops() async throws {
        let controller = PlaybackController(library: store(), resolver: FailingConnection(), monitorNetwork: false, retryDelay: 1_000_000)
        controller.play([a, b])
        for _ in 0..<100 {
            if !controller.wantsPlayback { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.current?.id, a.id); XCTAssertFalse(controller.wantsPlayback)
        XCTAssertNotNil(controller.message)
    }
    func testCorruptLibraryAutomaticCheckpointIsSilentAndPreserved() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let original = Data("{".utf8); try original.write(to: path)
        let library = LibraryStore(fileURL: path); XCTAssertNotNil(library.error)
        library.error = nil
        var queue = PlaybackQueue(); queue.start([a], at: 0)
        library.checkpoint(queue, position: 30, record: true)
        XCTAssertNil(library.error); XCTAssertEqual(try Data(contentsOf: path), original)
    }
}
