import AVFoundation
import Foundation

/// 음원을 재생 위치 기준으로 조금씩 받아 AVPlayer에 넘기고, 받은 바이트는 AudioCache에 남긴다.
/// 원본 주소를 AVPlayer에 직접 주면 재생 직후 파일 전체를 받는다(2026-10-20 Mac 실측, docs/DATA_USAGE.md).
///
/// - AVPlayer에는 "필요한 구간을 언제든 받을 수 있다"고 알린다(`isEntireLengthAvailableOnDemand`).
///   그러지 않으면 AVPlayer가 파일 끝까지 이어 받기를 기다리느라 재생 시작이 약 9초 늦었다.
/// - 이때 AVPlayer는 재생 전에 약 20초 간격 조각들의 머리말을 몇 바이트씩 읽는다. 작은 요청은
///   작은 덩어리만 받아, 머리말을 읽느라 파일 대부분을 받지 않게 한다.
/// - 재생 위치보다 앞선 양은 YouTube 웹 플레이어 실측(약 17~37초)에 맞춰, 20초 아래로 내려가면
///   40초까지 미리 채운다.
/// 모든 상태는 queue에서만 바꾼다.
final class CachingAudioLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Refresh = @Sendable () async throws -> URL

    static let scheme = "sway-audio"
    static let lowWaterSeconds = 20.0
    static let highWaterSeconds = 40.0
    static let chunkBytes = 256 * 1024
    /// 머리말 읽기(수 바이트~수 KB 요청)에는 이만큼만 받는다. 실측 조각 머리말은 1,824바이트였다.
    static let probeBytes = 4 * 1024
    static let headerConcurrency = 6
    static let probeRequestBytes = 4 * 1024
    /// 이보다 큰 요청(파일 끝까지 등)은 재생 위치 앞 고수위 안에서만 받아 파일 전체 수신으로 번지지 않게 한다.
    static let largeRequestBytes = 1024 * 1024
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    enum LoaderError: Error { case sourceExpired, badResponse(Int), lengthChanged }

    let id: String
    let contentLength: Int
    let duration: Double
    private let cache: AudioCache
    private let fetch: Fetch
    private let refresh: Refresh
    private let onEvent: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "sway.audio-loader")
    private var source: URL
    private var sourceStale = false
    /// 망이 바뀔 때마다 늘린다. 바뀌기 전에 시작한 갱신 결과가 낡음 표시를 지우지 못하게 한다.
    private var sourceEpoch = 0
    /// 재시도를 다 쓴 오류. 망이 바뀌기 전까지 새 요청을 받지 않고 이 오류로 끝낸다.
    private var failure: Error?
    /// 캐시에 쓰지 못했을 때(지워짐·공간 부족) 받은 바이트를 바로 넘기고 미리 받기를 멈춘다.
    private var passthrough = false
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var task: Task<Void, Never>?
    private var filling = true
    private var playhead: Double
    private var expiredRetries = 0
    private var networkRetries = 0
    private var cancelled = false
    private var networkBytes = 0
    private var headerTask: Task<Void, Never>?

    init?(id: String, audio: ResolvedAudio, startAt position: Double = 0, cache: AudioCache = .shared,
          fetch: @escaping Fetch = CachingAudioLoader.urlSessionFetch, refresh: @escaping Refresh,
          onEvent: (@Sendable (String) -> Void)? = nil) {
        let length = URLComponents(url: audio.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "clen" }?.value.flatMap(Int.init)
        guard let length, length > 0, let duration = audio.duration, duration > 0,
              cache.prepare(id, contentLength: length, duration: duration, bitrate: audio.bitrate) != nil else { return nil }
        self.id = id; self.contentLength = length; self.duration = duration; self.cache = cache
        self.fetch = fetch; self.refresh = refresh; self.onEvent = onEvent
        self.source = audio.url; self.playhead = max(0, position)
        super.init()
        cache.beginUse(id)
    }
    deinit { if !cancelled { cache.endUse(id) } }

    /// 로더는 AVURLAsset이 약하게 참조하므로 호출부가 item과 함께 붙잡아 둬야 한다.
    func makeItem() -> AVPlayerItem {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://\(id).m4a")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayerItem(asset: asset)
    }

    func updatePlayhead(_ seconds: Double) {
        guard seconds.isFinite else { return }
        queue.async { self.playhead = max(0, seconds); self.pump() }
    }
    /// 망이 바뀌면 원본 주소가 거부될 수 있다. 다음 요청 전에 새 주소를 받는다.
    /// 새 망에서는 실패했던 요청도 다시 시도한다.
    func markSourceStale() {
        queue.async {
            self.sourceStale = true; self.sourceEpoch += 1
            self.failure = nil; self.expiredRetries = 0; self.networkRetries = 0
            self.pump()
        }
    }
    func cancel() {
        queue.async {
            guard !self.cancelled else { return }
            self.cancelled = true; self.task?.cancel(); self.task = nil; self.headerTask?.cancel(); self.requests.removeAll()
            self.cache.endUse(self.id)
            if !self.cache.isEnabled { self.cache.remove(self.id) }
        }
    }
    /// 이 로더가 네트워크에서 받은 음원 바이트(진단용).
    func receivedBytes() -> Int { queue.sync { networkBytes } }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !cancelled, loadingRequest.request.url?.scheme == Self.scheme else { return false }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = AVFileType.m4a.rawValue
            info.contentLength = Int64(contentLength)
            info.isByteRangeAccessSupported = true
            info.isEntireLengthAvailableOnDemand = true
        }
        guard let data = loadingRequest.dataRequest else { loadingRequest.finishLoading(); return true }
        onEvent?("request offset=\(data.requestedOffset) length=\(data.requestedLength) toEnd=\(data.requestsAllDataToEndOfResource)")
        requests.append(loadingRequest)
        pump()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        onEvent?("cancel offset=\(loadingRequest.dataRequest?.currentOffset ?? -1)")
        requests.removeAll { $0 === loadingRequest }
    }

    // MARK: 공급과 수신 (queue)

    private func end(of data: AVAssetResourceLoadingDataRequest) -> Int {
        data.requestsAllDataToEndOfResource ? contentLength : min(contentLength, Int(data.requestedOffset) + data.requestedLength)
    }

    private func serve() {
        for request in requests where !request.isFinished && !request.isCancelled {
            guard let data = request.dataRequest else { continue }
            let end = end(of: data)
            var offset = Int(data.currentOffset)
            while offset < end, let chunk = cache.read(id, offset: offset, length: min(end - offset, Self.chunkBytes)) {
                data.respond(with: chunk); offset += chunk.count
            }
            if offset >= end { request.finishLoading() }
        }
        requests.removeAll { $0.isFinished || $0.isCancelled }
    }

    private var bytesPerSecond: Double { Double(contentLength) / duration }

    /// 다음에 받을 구간. AVPlayer가 기다리는 요청이 먼저이고, 없으면 재생 위치 앞을 미리 채운다.
    private func nextRange() -> (offset: Int, length: Int)? {
        let head = min(contentLength, Int(playhead * bytesPerSecond))
        for request in requests where !request.isFinished && !request.isCancelled {
            guard let data = request.dataRequest else { continue }
            let end = end(of: data)
            let missing = passthrough ? Int(data.currentOffset) : cache.availableEnd(id, from: Int(data.currentOffset))
            guard missing < end else { continue }
            if passthrough { return (missing, min(end - missing, Self.chunkBytes)) }
            let probe = !data.requestsAllDataToEndOfResource && data.requestedLength <= Self.probeRequestBytes
            if !probe, end - missing > Self.largeRequestBytes, Double(missing - head) / bytesPerSecond >= Self.highWaterSeconds { continue }
            return block(at: missing, size: probe ? Self.probeBytes : Self.chunkBytes)
        }
        guard !passthrough else { return nil }
        let filled = cache.availableEnd(id, from: head)
        guard filled < contentLength else { return nil }
        let ahead = Double(filled - head) / bytesPerSecond
        if ahead >= Self.highWaterSeconds || (!filling && ahead >= Self.lowWaterSeconds) { filling = false; return nil }
        filling = true
        // 고수위를 크게 넘지 않게 필요한 만큼만 받는다.
        let needed = Int((Self.highWaterSeconds - ahead) * bytesPerSecond)
        return block(at: filled, size: min(Self.chunkBytes, max(Self.probeBytes, needed)))
    }

    /// 이미 받아 둔 다음 구간 앞에서 멈춘다.
    private func block(at offset: Int, size: Int) -> (offset: Int, length: Int) {
        let limit = min(contentLength, cache.nextStoredStart(id, after: offset) ?? contentLength)
        return (offset, max(1, min(size, limit - offset)))
    }

    private func pump() {
        guard !cancelled else { return }
        serve()
        if let failure { failAll(failure); return }
        guard task == nil, let range = nextRange() else { return }
        let url = source, stale = sourceStale, epoch = sourceEpoch, fetch = fetch, refresh = refresh, length = contentLength
        task = Task { [weak self] in
            let result: Result<(Data, URL?), Error>
            do {
                var fresh: URL?
                if stale {
                    let renewed = try await refresh()
                    let clen = URLComponents(url: renewed, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "clen" }?.value.flatMap(Int.init)
                    guard clen == nil || clen == length else { throw LoaderError.lengthChanged }
                    fresh = renewed
                }
                var request = URLRequest(url: fresh ?? url)
                request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
                let (data, response) = try await fetch(request)
                switch response.statusCode {
                case 206 where Self.matches(response, data, offset: range.offset, length: range.length, total: length):
                    result = .success((data, fresh))
                case 200 where range.offset == 0 && data.count == length: result = .success((data, fresh))
                case 403, 410: throw LoaderError.sourceExpired
                default: throw LoaderError.badResponse(response.statusCode)
                }
            } catch { result = .failure(error) }
            self?.queue.async { self?.finish(range.offset, epoch, result) }
        }
    }

    /// AVPlayer는 재생 전에 모든 조각의 머리말을 하나씩 읽는다. 한 번에 하나씩 받으면 조각 수만큼
    /// 왕복이 쌓이므로, 파일 앞 sidx 색인으로 조각 위치를 알아내 머리말 블록을 동시에 받아 둔다.
    private func prefetchFragmentHeaders(from head: Data) {
        let starts = Self.fragmentOffsets(head).filter { $0 < contentLength && cache.availableEnd(id, from: $0) == $0 }
        guard !starts.isEmpty else { return }
        let url = source, fetch = fetch, length = contentLength, size = Self.probeBytes, limit = Self.headerConcurrency
        headerTask = Task { [weak self] in
            await withTaskGroup(of: (Int, Data?).self) { group in
                var pending = starts[...]
                func add() {
                    guard let offset = pending.popFirst() else { return }
                    group.addTask {
                        var request = URLRequest(url: url)
                        request.setValue("bytes=\(offset)-\(min(length, offset + size) - 1)", forHTTPHeaderField: "Range")
                        guard let (data, response) = try? await fetch(request), response.statusCode == 206,
                              Self.matches(response, data, offset: offset, length: min(length, offset + size) - offset, total: length) else { return (offset, nil) }
                        return (offset, data)
                    }
                }
                for _ in 0..<limit { add() }
                for await (offset, data) in group {
                    if let data, let self { self.queue.async { self.storeHeader(offset, data) } }
                    add()
                }
            }
        }
    }

    private func storeHeader(_ offset: Int, _ data: Data) {
        guard !cancelled, !passthrough else { return }
        networkBytes += data.count
        if !cache.write(id, offset: offset, data: data) { startPassthrough() }
        pump()
    }

    /// 206 응답의 Content-Range가 요청한 시작 위치·전체 길이와 맞고 본문 길이가 일치하는지 확인한다.
    static func matches(_ response: HTTPURLResponse, _ data: Data, offset: Int, length: Int, total: Int) -> Bool {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else { return false }
        let parts = header.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).map { Int($0) }
        guard parts.count == 3, let start = parts[0], let end = parts[1], let size = parts[2] else { return false }
        return start == offset && size == total && end - start + 1 == data.count && !data.isEmpty && data.count <= length
    }

    private func startPassthrough() {
        guard !passthrough else { return }
        passthrough = true; headerTask?.cancel()
        onEvent?("cache write failed; streaming without cache")
    }

    /// 캐시를 거치지 않고 받은 바이트를 기다리는 요청에 바로 넘긴다.
    private func deliver(_ offset: Int, _ data: Data) {
        for request in requests where !request.isFinished && !request.isCancelled {
            guard let dataRequest = request.dataRequest else { continue }
            let current = Int(dataRequest.currentOffset), end = min(end(of: dataRequest), offset + data.count)
            guard current >= offset, current < end else { continue }
            dataRequest.respond(with: data.subdata(in: (current - offset)..<(end - offset)))
            if Int(dataRequest.currentOffset) >= self.end(of: dataRequest) { request.finishLoading() }
        }
        requests.removeAll { $0.isFinished || $0.isCancelled }
    }

    private func failAll(_ error: Error) {
        for request in requests where !request.isFinished && !request.isCancelled { request.finishLoading(with: error) }
        requests.removeAll()
    }

    /// ISO BMFF 상위 상자 중 sidx를 찾아 각 조각의 시작 위치를 돌려준다. 해석할 수 없으면 빈 배열.
    /// 모든 읽기를 상자 끝 안으로 제한해, 잘못된 입력이 앱을 멈추지 않고 빈 배열이 되게 한다.
    static func fragmentOffsets(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        func read(_ i: Int, _ count: Int, before limit: Int) -> Int? {
            guard i >= 0, i + count <= limit else { return nil }
            return bytes[i..<i + count].reduce(0) { $0 << 8 | Int($1) }
        }
        var box = 0
        while let size = read(box, 4, before: bytes.count), box + 8 <= bytes.count {
            guard size >= 8 else { return [] }                // 0(끝까지)·1(64비트 크기)은 지원하지 않는다.
            let (boxEnd, overflow) = box.addingReportingOverflow(size)
            guard !overflow else { return [] }
            if bytes[box + 4..<box + 8].elementsEqual("sidx".utf8) {
                guard boxEnd <= bytes.count, let version = read(box + 8, 1, before: boxEnd) else { return [] }
                var i = box + 12 + 8                          // version/flags, reference_ID, timescale
                let firstOffset = version == 0 ? read(i + 4, 4, before: boxEnd) : read(i + 8, 8, before: boxEnd)
                i += version == 0 ? 8 : 16                    // earliest_presentation_time, first_offset
                guard let firstOffset, firstOffset >= 0, let count = read(i + 2, 2, before: boxEnd), count > 0,
                      i + 4 + count * 12 <= boxEnd else { return [] }
                i += 4
                var (offset, overflowed) = boxEnd.addingReportingOverflow(firstOffset)
                var result: [Int] = []
                for k in 0..<count {
                    guard !overflowed, let reference = read(i + k * 12, 4, before: boxEnd) else { return [] }
                    result.append(offset)
                    (offset, overflowed) = offset.addingReportingOverflow(reference & 0x7fff_ffff)
                }
                return result
            }
            box = boxEnd
        }
        return []
    }

    private func finish(_ offset: Int, _ epoch: Int, _ result: Result<(Data, URL?), Error>) {
        task = nil
        guard !cancelled else { return }
        switch result {
        case .success(let (data, fresh)):
            if let fresh { source = fresh; if epoch == sourceEpoch { sourceStale = false } }
            expiredRetries = 0; networkRetries = 0; networkBytes += data.count
            if passthrough || !cache.write(id, offset: offset, data: data) {
                // 저장하지 못한 바이트는 바로 넘긴다. 저장된 줄 알고 같은 구간을 다시 받지 않는다.
                startPassthrough(); deliver(offset, data)
            }
            onEvent?("received offset=\(offset) bytes=\(data.count) playhead=\(String(format: "%.1f", playhead))")
            if offset == 0, headerTask == nil, !passthrough { prefetchFragmentHeaders(from: data) }
            pump()
        case .failure(LoaderError.sourceExpired) where expiredRetries < 2:
            // 만료·망 변경으로 거부되면 새 주소로 같은 위치부터 다시 받는다.
            expiredRetries += 1; sourceStale = true
            onEvent?("source expired, refreshing (\(expiredRetries))")
            pump()
        case .failure(let error) where !(error is CancellationError) && networkRetries < 1 && !(error is LoaderError):
            networkRetries += 1
            onEvent?("network error, retrying: \(error.localizedDescription)")
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pump() }
        case .failure(let error):
            // 재시도를 다 썼다. 망이 바뀌기 전까지 다시 받지 않고, 지금과 이후 요청을 이 오류로 끝내
            // PlaybackController의 갱신·연결 복구 경로에 넘긴다.
            onEvent?("failed: \(error)")
            failure = error; failAll(error)
        }
    }
}
