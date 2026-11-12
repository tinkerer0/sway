//
//  SolverDiskCacheTests.swift
//  YouTubeKit
//
//  Sway: 전처리 결과를 디스크에 남겨 앱을 다시 켠 뒤에도 쓰는지 확인한다.
//

#if canImport(JavaScriptCore)
import Testing
import Foundation
@testable import YouTubeKit

@Suite(.serialized)
struct SolverDiskCacheTests {

    let playerURL = URL(string: "https://www.youtube.com/s/player/631d3938/tv-player-ias.vflset/tv-player-ias.js")!
    let request = SignatureSolver.SolveRequest(nInputs: ["KBx1qz7jMhxELa8c"], sigInputs: [])
    let expected = "ttPvh7WIptsgSw"

    @Test("앱을 다시 켠 것처럼 메모리 캐시를 비워도 디스크의 전처리 결과를 쓰고, 망가진 파일은 다시 만든다")
    func reusesAndRepairsDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("solver-disk-\(UUID().uuidString)", isDirectory: true)
        let previous = SignatureSolver.diskDirectory
        SignatureSolver.diskDirectory = directory
        SignatureSolver.removeMemoryCache()
        defer { SignatureSolver.diskDirectory = previous; SignatureSolver.removeMemoryCache(); try? FileManager.default.removeItem(at: directory) }

        let (data, _) = try await URLSession.shared.data(from: playerURL)
        let js = try #require(String(data: data, encoding: .utf8))
        let file = directory.appendingPathComponent(SignatureSolver.diskKey(js) + ".js")

        let first = try SignatureSolver(js: js).batchSolve(request: request)
        #expect(SignatureSolver.lastSource == .full)
        #expect(first.nMap[request.nInputs[0]] == expected)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let warm = try SignatureSolver(js: js).batchSolve(request: request)
        #expect(SignatureSolver.lastSource == .memory)
        #expect(warm.nMap == first.nMap)

        SignatureSolver.removeMemoryCache()
        let relaunched = try SignatureSolver(js: js).batchSolve(request: request)
        #expect(SignatureSolver.lastSource == .disk)
        #expect(relaunched.nMap == first.nMap)

        try Data("not a program".utf8).write(to: file)
        SignatureSolver.removeMemoryCache()
        let repaired = try SignatureSolver(js: js).batchSolve(request: request)
        #expect(SignatureSolver.lastSource == .full)
        #expect(repaired.nMap == first.nMap)
        #expect(try String(contentsOf: file, encoding: .utf8) != "not a program")
    }

    @Test("player 버전이 여러 개 쌓이면 최근 네 개만 남긴다")
    func keepsFourNewestPlayers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("solver-disk-\(UUID().uuidString)", isDirectory: true)
        let previous = SignatureSolver.diskDirectory
        SignatureSolver.diskDirectory = directory
        defer { SignatureSolver.diskDirectory = previous; try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, name) in ["oldest", "old", "middle", "recent"].enumerated() {
            let url = directory.appendingPathComponent("\(name).js")
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)], ofItemAtPath: url.path)
        }
        SignatureSolver.writeDisk("newest", "program")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["middle.js", "newest.js", "old.js", "recent.js"])
    }
    // 실제 YouTube로 확인한다. 고정 파일·전처리 폴더는 임시 위치로 바꾸고 끝나면 되돌린다.
    func withIsolatedCaches(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("player-pin-\(UUID().uuidString)", isDirectory: true)
        let previousDisk = SignatureSolver.diskDirectory, previousPin = YouTube.playerPin.fileURL
        SignatureSolver.diskDirectory = root.appendingPathComponent("players", isDirectory: true)
        YouTube.playerPin.fileURL = root.appendingPathComponent("player-pin.json")
        YouTube.invalidateSharedPageContext()
        SignatureSolver.removeMemoryCache()
        defer {
            YouTube.invalidateSharedPageContext()
            SignatureSolver.diskDirectory = previousDisk; YouTube.playerPin.fileURL = previousPin
            SignatureSolver.removeMemoryCache(); try? FileManager.default.removeItem(at: root)
        }
        try await body(root)
    }

    @Test("앱을 다시 켠 것처럼 메모리를 비워도 고정한 player의 디스크 전처리본을 써서 전체 분석을 하지 않는다")
    func relaunchUsesPinnedPlayer() async throws {
        try await withIsolatedCaches { _ in
            let first = try await YouTube(videoID: "9bZkp7q19f0", methods: [.local]).streams
            #expect(!first.filterAudioOnly().isEmpty)
            let pinned = try #require(YouTube.playerPin.current())

            // 다시 켠 앱: 메모리의 공유 문맥·전처리본은 없고 디스크의 고정 파일·전처리본만 남는다.
            YouTube.invalidateSharedPageContext()
            YouTube.playerPin.pinIfAbsent(pinned)
            SignatureSolver.removeMemoryCache()
            let fullBefore = SignatureSolver.fullSolves
            let streams = try await YouTube(videoID: "ZFoNBxpXen4", methods: [.local]).streams
            #expect(SignatureSolver.fullSolves == fullBefore)
            #expect(YouTube.playerPin.current() == pinned)

            // 고정 player로 만든 재생 주소가 실제로 받아지는지 앞 2바이트만 받아 본다.
            let audio = try #require(streams.filterAudioOnly().highestAudioBitrateStream())
            var request = URLRequest(url: audio.url)
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect([200, 206].contains((response as? HTTPURLResponse)?.statusCode ?? 0))
        }
    }

    @Test("고정한 player를 받을 수 없으면 고정을 버리고 페이지가 준 player로 재생 주소를 만든다")
    func brokenPinFallsBackToPagePlayer() async throws {
        try await withIsolatedCaches { _ in
            let broken = URL(string: "https://www.youtube.com/s/player/00000000/player_ias.vflset/en_US/base.js")!
            YouTube.playerPin.pinIfAbsent(broken)
            #expect(YouTube.playerPin.current() == broken)
            let streams = try await YouTube(videoID: "9bZkp7q19f0", methods: [.local]).streams
            #expect(!streams.filterAudioOnly().isEmpty)
            let repinned = try #require(YouTube.playerPin.current())
            #expect(repinned != broken)
        }
    }
}

#endif
