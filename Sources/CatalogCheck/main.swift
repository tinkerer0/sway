import Foundation
import MusicCore

@main struct CatalogCheck {
    static func main() async throws {
        let catalog = YouTubeCatalog()
        if CommandLine.arguments.contains("--mix") {
            for seed in ["NnRjwEhFU70", "4D7u5KF7SP8", "9bZkp7q19f0"] {
                let tracks = try await catalog.mix(seedID: seed)
                print("CLEAN_MIX seed=\(seed) count=\(tracks.count)")
                for track in tracks { print("TRACK \(track.id) \(track.title) | \(track.artist)") }
                guard !tracks.contains(where: { $0.id == seed || MixPolicy.hasUnwantedVersion($0.title) }) else { exit(1) }
                // 뮤직비디오로 시작해도 같은 곡의 정식 음원판 믹스로 채운다.
                if seed == "9bZkp7q19f0" { guard tracks.count >= 3 else { exit(1) } }
                if seed == "NnRjwEhFU70" {
                    guard tracks.count >= 3, let anchor = tracks.last?.id else { exit(1) }
                    let excluded = Set(tracks.map(\.id))
                    let more = try await catalog.mix(seedID: seed, afterID: anchor, excluding: excluded)
                    print("CLEAN_MIX_MORE count=\(more.count) priorOverlap=\(more.filter { excluded.contains($0.id) }.count)")
                    guard !more.contains(where: { excluded.contains($0.id) }) else { exit(1) }
                }
            }
            return
        }
        if CommandLine.arguments.contains("--music") {
            for query in ["아이유 밤편지", "Daft Punk Get Lucky", "aespa Supernova", "혁오 TOMBOY"] {
                let page = try await catalog.search(query, mode: .music)
                print("MUSIC query=\(query) count=\(page.tracks.count) mode=\(page.mode.rawValue)")
                for track in page.tracks.prefix(3) { print("TRACK \(track.id) \(track.title) | \(track.artist)") }
                guard !page.tracks.isEmpty, page.mode == .music else { exit(1) }
                if query == "아이유 밤편지", page.continuation != nil {
                    let more = try await catalog.more(page)
                    print("MUSIC_MORE count=\(more.tracks.count) mode=\(more.mode.rawValue)")
                    guard more.mode == .music else { exit(1) }
                }
            }
            return
        }
        let page = try await catalog.search("아이유 밤편지")
        print("SEARCH count=\(page.tracks.count) valid=\(page.tracks.allSatisfy { Track.validID($0.id) })")
        for track in page.tracks.prefix(3) { print("TRACK \(track.id) \(track.title)") }
        if page.continuation != nil {
            let next = try await catalog.more(page)
            print("MORE count=\(next.tracks.count)")
        }
        let mix = try await catalog.mix(seedID: "NnRjwEhFU70")
        print("MIX count=\(mix.count) unique=\(Set(mix.map(\.id)).count)")
        if let anchor = mix.last?.id {
            let moreMix = try await catalog.mix(seedID: "NnRjwEhFU70", afterID: anchor)
            let prior = Set(mix.map(\.id))
            print("MIX_MORE count=\(moreMix.count) new=\(moreMix.filter { !prior.contains($0.id) }.count)")
        }
        let english = try await catalog.search("Daft Punk Get Lucky")
        print("ENGLISH_SEARCH count=\(english.tracks.count)")
        guard page.tracks.count >= 3, mix.count >= 3 else { exit(1) }
    }
}
