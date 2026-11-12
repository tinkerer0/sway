import XCTest
@testable import MusicCore

final class DiscoveryTests: XCTestCase {
    let seed = Track(id: "aaaaaaaaaaa", title: "Favorite", artist: "A", duration: 240)
    func testLegacyLibraryAndListeningStatsRoundTrip() throws {
        var state = LibrarySnapshot(); state.record(seed); state.save(seed)
        let original = try JSONEncoder().encode(state)
        let legacy = try JSONDecoder().decode(LibrarySnapshot.self, from: original)
        XCTAssertNil(legacy.listeningStats)
        XCTAssertEqual(DiscoveryPolicy.seeds(in: legacy).map(\.id), [seed.id])
        state.recordQualifiedListen(seed); state.recordQualifiedListen(seed)
        let restored = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.listeningStats?[seed.id]?.plays, 2)
        XCTAssertEqual(restored.savedIDs, [seed.id])
        XCTAssertEqual(restored.history.count, 1)
    }
    func testFrequencyAndRecencyChooseSeedsWithoutSavedOnlyFallback() {
        let now = Date()
        var state = LibrarySnapshot()
        state.save(seed)
        XCTAssertTrue(DiscoveryPolicy.seeds(in: state).isEmpty)
        let recent = Track(id: "bbbbbbbbbbb", title: "Recent", artist: "B", duration: 180)
        state.record(recent)
        for _ in 0..<4 { state.recordQualifiedListen(seed, at: now) }
        XCTAssertEqual(DiscoveryPolicy.seeds(in: state, now: now).first?.id, seed.id)
        state.listeningStats?[seed.id]?.lastPlayedAt = now.addingTimeInterval(-86400 * 365)
        XCTAssertEqual(DiscoveryPolicy.seeds(in: state, now: now).first?.id, recent.id)
    }
    func testKnownIDsTitlesPlaylistsAndNoisyVersionsAreExcluded() throws {
        var state = LibrarySnapshot(); state.record(seed)
        let saved = Track(id: "bbbbbbbbbbb", title: "Saved", artist: "B", duration: 180)
        let playlist = try XCTUnwrap(state.createPlaylist(name: "List")); state.add(saved, to: playlist)
        state.savedIDs = []
        let duplicate = Track(id: "ccccccccccc", title: "FAVORITE (Official Audio)", artist: "A - Topic", duration: 240)
        let noise = Track(id: "ddddddddddd", title: "Remix", artist: "D", duration: 120)
        let fresh = Track(id: "eeeeeeeeeee", title: "Fresh", artist: "E", duration: 120)
        XCTAssertEqual(DiscoveryPolicy.candidates([seed, saved, duplicate, noise, fresh, fresh], in: state).map(\.id), [fresh.id])
        XCTAssertTrue(DiscoveryPolicy.candidates([fresh], in: state, excluding: [fresh.id]).isEmpty)
        state.recordQualifiedListen(fresh)
        XCTAssertTrue(DiscoveryPolicy.candidates([fresh], in: state).isEmpty)
    }
    func testOneArtistCannotFillTheDiscoveryList() {
        let tracks = (0..<8).map { Track(id: String(repeating: "a", count: 10) + String($0), title: "Song \($0)", artist: $0 < 4 ? "A" : "Artist \($0)", duration: 180) }
        let result = DiscoveryPolicy.candidates(tracks, in: LibrarySnapshot())
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.filter { $0.artist == "A" }.count, 2)
    }
    func testBilingualTitleAndMusicVideoDoNotReturnAsANewSong() {
        var state = LibrarySnapshot()
        state.record(Track(id: "aaaaaaaaaaa", title: "[MV] IU(아이유)_밤편지(Through the Night)", artist: "1theK", duration: 254))
        let sameSong = Track(id: "bbbbbbbbbbb", title: "Through the Night (밤편지)", artist: "IU", duration: 254)
        XCTAssertTrue(DiscoveryPolicy.candidates([sameSong], in: state).isEmpty)
    }
    func testSeekingPausingAndRepeatedTicksDoNotCountAsListening() {
        var progress = ListeningProgress()
        XCTAssertFalse(progress.observe(position: 0, playing: true, duration: 240))
        for second in 1...10 { XCTAssertFalse(progress.observe(position: Double(second), playing: true, duration: 240)) }
        progress.seek(to: 200)
        XCTAssertFalse(progress.observe(position: 200, playing: false, duration: 240))
        XCTAssertFalse(progress.observe(position: 220, playing: true, duration: 240))
        for second in 221...239 { XCTAssertFalse(progress.observe(position: Double(second), playing: true, duration: 240)) }
        XCTAssertTrue(progress.observe(position: 240, playing: true, duration: 240))
        XCTAssertFalse(progress.observe(position: 241, playing: true, duration: 240))
    }
}
