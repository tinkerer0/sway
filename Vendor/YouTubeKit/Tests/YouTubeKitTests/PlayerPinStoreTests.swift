//
//  PlayerPinStoreTests.swift
//  YouTubeKit
//
//  Sway: 앱을 다시 켜도 쓰는 player 주소 고정의 만료·거부·덮어쓰기 규칙을 확인한다(망 없이).
//

import Testing
import Foundation
@testable import YouTubeKit

struct PlayerPinStoreTests {

    let a = URL(string: "https://www.youtube.com/s/player/6b2fce74/player_ias.vflset/en_US/base.js")!
    let b = URL(string: "https://www.youtube.com/s/player/dce23b30/player_ias.vflset/en_US/base.js")!

    func makeStore(lifetime: TimeInterval = 100) -> (PlayerPinStore, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)/player-pin.json")
        return (PlayerPinStore(file: file, lifetime: lifetime), file)
    }

    @Test("이미 고정이 있으면 다른 player로 덮어쓰지 않고, 지우면 새로 고정한다")
    func keepsFirstPinUntilRemoved() {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = Date()
        store.pinIfAbsent(a, now: start)
        store.pinIfAbsent(b, now: start.addingTimeInterval(1))
        #expect(store.current(now: start.addingTimeInterval(2)) == a)
        store.remove()
        #expect(store.current(now: start.addingTimeInterval(3)) == nil)
        store.pinIfAbsent(b, now: start.addingTimeInterval(4))
        #expect(store.current(now: start.addingTimeInterval(5)) == b)
    }

    @Test("만든 뒤 수명이 지나거나 시각이 뒤로 가면 쓰지 않고 파일을 지운다")
    func expiresByCreationTime() {
        let (store, file) = makeStore(lifetime: 100)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = Date()
        store.pinIfAbsent(a, now: start)
        #expect(store.current(now: start.addingTimeInterval(99)) == a)
        #expect(store.current(now: start.addingTimeInterval(100)) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        store.pinIfAbsent(a, now: start)
        #expect(store.current(now: start.addingTimeInterval(-1)) == nil)
    }

    @Test("YouTube player 주소가 아니거나 파일이 망가지면 쓰지 않는다")
    func rejectsForeignURLsAndCorruptFiles() throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for url in ["http://www.youtube.com/s/player/x/base.js", "https://example.com/s/player/x/base.js",
                    "https://www.youtube.com/watch?v=abc"] {
            store.pinIfAbsent(URL(string: url)!)
            #expect(store.current() == nil, "\(url)")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(store.current() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
