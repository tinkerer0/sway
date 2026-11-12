import Foundation
import MusicCore

/// 재생하며 받은 음원 바이트를 곡별 파일에 남겨 다시 들을 때 데이터를 쓰지 않게 한다.
/// 앱 안에서만 쓰는 임시 캐시다. 총량이 상한을 넘으면 오래 안 들은 곡부터 지우고,
/// Caches 폴더라 기기 저장 공간이 부족하면 iOS가 비울 수 있다.
final class AudioCache: @unchecked Sendable {
    struct Meta: Codable, Equatable {
        var contentLength: Int
        var duration: Double
        var bitrate: Int
        /// 받은 구간 [start, end). 겹치거나 맞닿은 구간은 합쳐 둔다.
        var ranges: [[Int]]
        var lastAccess: Date
        var stored: Int { ranges.reduce(0) { $0 + $1[1] - $1[0] } }
        var isComplete: Bool { ranges.count == 1 && ranges[0] == [0, contentLength] }
    }
    static let limitKey = "sway.audioCacheLimitMB"
    static let defaultLimitMB = 1024
    static let shared = AudioCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SwayAudio", isDirectory: true))

    private let lock = NSLock()
    /// 지금 로더가 쓰고 있는 곡. 정리 작업이 늦게 실행돼도 지우지 않는다.
    private var active: [String: Int] = [:]
    private let directory: URL
    private let limitBytes: @Sendable () -> Int
    private let now: @Sendable () -> Date

    init(directory: URL, limitBytes: @escaping @Sendable () -> Int = {
            let mb = UserDefaults.standard.object(forKey: AudioCache.limitKey) as? Int ?? AudioCache.defaultLimitMB
            return max(0, mb) * 1024 * 1024
         }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.limitBytes = limitBytes; self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var isEnabled: Bool { limitBytes() > 0 }
    func fileURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).m4a") }
    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    func meta(_ id: String) -> Meta? {
        lock.lock(); defer { lock.unlock() }
        return readMeta(id)
    }
    private func readMeta(_ id: String) -> Meta? {
        guard Track.validID(id), let data = try? Data(contentsOf: metaURL(id)),
              var meta = try? JSONDecoder().decode(Meta.self, from: data),
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(id).path))?[.size] as? Int else { return nil }
        // 파일이 밖에서 잘렸으면 실제 크기를 넘는 구간 정보를 버린다.
        if meta.ranges.contains(where: { $0[1] > size }) {
            meta.ranges = meta.ranges.compactMap { $0[0] < size ? [$0[0], min($0[1], size)] : nil }
        }
        return meta
    }
    private func writeMeta(_ id: String, _ meta: Meta) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL(id), options: .atomic)
    }

    /// 끝까지 받은 곡이면 로컬 파일과 정보를 돌려주고 마지막 접근 시각을 갱신한다.
    func completeFile(_ id: String) -> (url: URL, meta: Meta)? {
        lock.lock(); defer { lock.unlock() }
        guard var meta = readMeta(id), meta.isComplete else { return nil }
        meta.lastAccess = now(); writeMeta(id, meta)
        return (fileURL(id), meta)
    }
    func isComplete(_ id: String) -> Bool { meta(id)?.isComplete == true }

    /// 재생 시작 때 부른다. 길이가 다르면(다른 원본) 이전 캐시를 버린다.
    @discardableResult func prepare(_ id: String, contentLength: Int, duration: Double, bitrate: Int) -> Meta? {
        lock.lock(); defer { lock.unlock() }
        guard Track.validID(id), contentLength > 0 else { return nil }
        if var meta = readMeta(id), meta.contentLength == contentLength {
            meta.lastAccess = now(); meta.duration = duration; meta.bitrate = bitrate
            writeMeta(id, meta); return meta
        }
        removeLocked(id)
        guard FileManager.default.createFile(atPath: fileURL(id).path, contents: nil) else { return nil }
        let meta = Meta(contentLength: contentLength, duration: duration, bitrate: bitrate, ranges: [], lastAccess: now())
        writeMeta(id, meta); return meta
    }

    /// offset부터 이어서 받아 둔 바이트를 최대 length만큼 돌려준다.
    func read(_ id: String, offset: Int, length: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard length > 0, let meta = readMeta(id),
              let range = meta.ranges.first(where: { $0[0] <= offset && offset < $0[1] }) else { return nil }
        let count = min(length, range[1] - offset)
        guard let handle = try? FileHandle(forReadingFrom: fileURL(id)) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    /// offset 이후 받아 둔 연속 구간의 끝. 없으면 offset 그대로.
    func availableEnd(_ id: String, from offset: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return readMeta(id)?.ranges.first { $0[0] <= offset && offset < $0[1] }?[1] ?? offset
    }

    /// offset 뒤에서 처음 받아 둔 구간이 시작하는 위치. 없으면 nil.
    func nextStoredStart(_ id: String, after offset: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return readMeta(id)?.ranges.map { $0[0] }.filter { $0 > offset }.min()
    }

    /// 파일에 먼저 쓰고 동기화한 뒤 구간 정보를 저장한다. 중간에 끊겨도 기록된 구간은 실제 바이트와 맞는다.
    /// 저장하지 못하면(지워짐·공간 부족) false를 돌려 호출부가 같은 구간을 다시 받지 않게 한다.
    @discardableResult func write(_ id: String, offset: Int, data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty, var meta = readMeta(id), offset >= 0, offset + data.count <= meta.contentLength,
              let handle = try? FileHandle(forWritingTo: fileURL(id)) else { return false }
        do {
            try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        } catch { try? handle.close(); return false }
        meta.ranges = Self.merge(meta.ranges + [[offset, offset + data.count]])
        guard let encoded = try? JSONEncoder().encode(meta), (try? encoded.write(to: metaURL(id), options: .atomic)) != nil else { return false }
        return true
    }

    func beginUse(_ id: String) { lock.lock(); active[id, default: 0] += 1; lock.unlock() }
    func endUse(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if let count = active[id], count > 1 { active[id] = count - 1 } else { active[id] = nil }
    }

    static func merge(_ ranges: [[Int]]) -> [[Int]] {
        var result: [[Int]] = []
        for range in ranges.filter({ $0.count == 2 && $0[0] < $0[1] }).sorted(by: { $0[0] < $1[0] }) {
            if let last = result.last, range[0] <= last[1] { result[result.count - 1][1] = max(last[1], range[1]) }
            else { result.append(range) }
        }
        return result
    }

    var totalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return entries().reduce(0) { $0 + $1.meta.stored }
    }

    /// 상한을 넘으면 마지막 접근이 오래된 곡부터 지운다. 재생 중인 곡은 지우지 않는다.
    func enforceLimit(protecting: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        let limit = limitBytes()
        var items = entries().sorted { $0.meta.lastAccess < $1.meta.lastAccess }
        var total = items.reduce(0) { $0 + $1.meta.stored }
        while total > limit, let index = items.firstIndex(where: { !protecting.contains($0.id) && active[$0.id] == nil }) {
            let item = items.remove(at: index); total -= item.meta.stored; removeLocked(item.id)
        }
    }
    func remove(_ id: String) { lock.lock(); removeLocked(id); lock.unlock() }
    func removeAll(protecting: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        for item in entries() where !protecting.contains(item.id) && active[item.id] == nil { removeLocked(item.id) }
    }
    private func removeLocked(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(id)); try? FileManager.default.removeItem(at: metaURL(id))
    }
    private func entries() -> [(id: String, meta: Meta)] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { name in
            let id = String(name.dropLast(5))
            return readMeta(id).map { (id, $0) }
        }
    }
}
