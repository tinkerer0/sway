import Foundation

struct ResolvedAudio: Sendable {
    let url: URL
    let bitrate: Int
    let duration: Double?
    init(url: URL, bitrate: Int, duration: Double? = nil) {
        self.url = url; self.bitrate = bitrate; self.duration = duration
    }
}
enum AudioError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "이 영상의 음원을 재생할 수 없어요. 잠시 후 다시 시도해 주세요." }
}
protocol AudioResolving: Sendable {
    func resolve(_ id: String, refreshing: Bool) async throws -> ResolvedAudio
    func invalidateAll() async
}
extension AudioResolving {
    func resolve(_ id: String) async throws -> ResolvedAudio { try await resolve(id, refreshing: false) }
}

/// 음원 바이트는 저장하지 않는다. 최고 AAC를 선택한 결과와 진행 중 주소 조회만 공유한다.
actor AudioResolver: AudioResolving {
    typealias Loader = @Sendable (String) async throws -> ResolvedAudio
    private struct Entry {
        let audio: ResolvedAudio
        let expiresAt: Date
        var access: UInt64
    }
    private struct Flight {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ResolvedAudio, Error>]
    }
    private let loader: Loader
    private let invalidateSource: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var access: UInt64 = 0
    private var loads = 0, cacheHits = 0, joins = 0
    struct Metrics: Sendable {
        let loads: Int
        let cacheHits: Int
        let joins: Int
        let consumers: Int
    }
    func metrics() -> Metrics {
        Metrics(loads: loads, cacheHits: cacheHits, joins: joins,
                consumers: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    init(capacity: Int = 8, now: @escaping @Sendable () -> Date = { Date() },
         invalidateSource: @escaping @Sendable () -> Void = { YouTubeAudioSource.invalidateSharedContext() },
         loader: @escaping Loader = { try await YouTubeAudioSource.resolve($0) }) {
        self.capacity = max(1, capacity); self.now = now; self.invalidateSource = invalidateSource; self.loader = loader
    }

    func resolve(_ id: String, refreshing: Bool = false) async throws -> ResolvedAudio {
        try Task.checkCancellation()
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                // 갱신은 재생 실패·연결 복구 때만 온다. 공유 player 문맥이 낡았을 수 있으니 함께 버린다.
                if refreshing { invalidate(id); invalidateSource() }
                let date = now()
                entries = entries.filter { $0.value.expiresAt > date }
                if var entry = entries[id] {
                    cacheHits += 1
                    access &+= 1; entry.access = access; entries[id] = entry
                    continuation.resume(returning: entry.audio); return
                }
                if flights[id] != nil {
                    joins += 1
                    flights[id]?.waiters[waiter] = continuation
                    return
                }
                loads += 1
                let token = UUID(), loader = loader
                let task = Task {
                    let result: Result<ResolvedAudio, Error>
                    do {
                        let audio = try await loader(id)
                        try Task.checkCancellation()
                        result = .success(audio)
                    } catch { result = .failure(error) }
                    self.finish(id, token: token, result: result)
                }
                flights[id] = Flight(token: token, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancel(id, waiter: waiter) }
        }
    }

    func invalidateAll() {
        invalidateSource()
        entries.removeAll()
        for id in Array(flights.keys) { invalidate(id) }
    }

    private func invalidate(_ id: String) {
        entries[id] = nil
        guard let flight = flights.removeValue(forKey: id) else { return }
        flight.task.cancel()
        for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
    }

    private func cancel(_ id: String, waiter: UUID) {
        guard let continuation = flights[id]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flights[id]?.waiters.isEmpty == true { invalidate(id) }
    }

    private func finish(_ id: String, token: UUID, result: Result<ResolvedAudio, Error>) {
        // 취소·갱신 이전의 느린 응답은 새 요청이나 캐시를 덮어쓸 수 없다.
        guard let flight = flights[id], flight.token == token else { return }
        flights[id] = nil
        if case .success(let audio) = result {
            let date = now()
            let expiry = URLComponents(url: audio.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "expire" }?.value.flatMap(Double.init)
            let deadline: Date
            if let expiry, expiry.isFinite {
                deadline = min(date.addingTimeInterval(600), Date(timeIntervalSince1970: expiry - 60))
            } else { deadline = date.addingTimeInterval(60) }
            if deadline > date {
                access &+= 1; entries[id] = Entry(audio: audio, expiresAt: deadline, access: access)
                while entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
                    entries[oldest] = nil
                }
            }
        }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }
}
