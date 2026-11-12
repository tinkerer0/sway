import AVFoundation
import MediaPlayer
import Network
import Observation
import OSLog
import UIKit
import MusicCore

@MainActor @Observable final class PlaybackController {
    typealias MixLoader = @Sendable (String, String?, Set<String>) async throws -> [Track]
    private(set) var queue = PlaybackQueue()
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var wantsPlayback = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var bitrate = 0
    private(set) var isMixLoading = false
    var message: String?
    var current: Track? { queue.current }
    var mixActive: Bool { queue.mixSeed != nil }
    var repeatMode: RepeatMode { queue.repeatMode }
    var showsPause: Bool { wantsPlayback && !interrupted }
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored let catalog: YouTubeCatalog
    @ObservationIgnored private let resolver: any AudioResolving
    @ObservationIgnored private let mixLoader: MixLoader
    @ObservationIgnored private var player = AVPlayer()
    @ObservationIgnored private let audioCache: AudioCache
    /// 현재 곡을 조금씩 받는 로더. AVURLAsset이 약하게 참조하므로 여기서 붙잡는다.
    @ObservationIgnored private var loader: CachingAudioLoader?
    @ObservationIgnored private let monitorNetwork: Bool
    @ObservationIgnored private let retryDelay: UInt64
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var online = true
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var mixTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var mixGeneration = UUID()
    @ObservationIgnored private var prefetchID: String?
    @ObservationIgnored private var prefetchToken = UUID()
    @ObservationIgnored private var pendingInvalidation: Task<Void, Never>?
    @ObservationIgnored private var networkSignature: String?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var playerObservation: NSKeyValueObservation?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var interruptionResume = false
    private var interrupted = false
    @ObservationIgnored private var resolving = false
    @ObservationIgnored private var networkResume = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var renewed = false
    @ObservationIgnored private var recorded = false
    @ObservationIgnored private var listeningProgress = ListeningProgress()
    @ObservationIgnored private var listeningTrackID: String?
    @ObservationIgnored private var connectionRetries = 0
    @ObservationIgnored private var mixExhausted = false
    @ObservationIgnored private var lastCheckpoint: Double = 0
    @ObservationIgnored private var sourceDuration: Double?
    @ObservationIgnored private var artwork: UIImage?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundGeneration = UUID()
    var hasBackgroundWork: Bool { backgroundTask != .invalid }
    @ObservationIgnored private var isForeground = false

    init(library: LibraryStore, resolver: any AudioResolving = AudioResolver(), monitorNetwork: Bool = true, retryDelay: UInt64 = 2_000_000_000,
         mixLoader: MixLoader? = nil, audioCache: AudioCache = .shared) {
        self.library = library; self.resolver = resolver; self.monitorNetwork = monitorNetwork; self.retryDelay = retryDelay
        self.audioCache = audioCache
        let catalog = YouTubeCatalog(); self.catalog = catalog
        self.mixLoader = mixLoader ?? { try await catalog.mix(seedID: $0, afterID: $1, excluding: $2) }
        if let saved = library.snapshot.playbackSession, let restored = PlaybackQueue(restoring: saved) {
            queue = restored; elapsed = saved.position.isFinite ? max(0, saved.position) : 0
            duration = restored.current?.duration ?? 0
        } else if let id = library.snapshot.lastTrackID, let track = library.snapshot.tracks[id] {
            queue.start([track], at: 0); elapsed = library.snapshot.lastPosition; duration = track.duration ?? 0
        }
        configurePlayer()
        observeSystem(); installRemoteCommands()
        if monitorNetwork {
            network.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                let signature = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                    .map { "\($0.type):\($0.name)" }.sorted().joined(separator: "|")
                Task { @MainActor in self?.networkChanged(available, signature: "\(available)|\(signature)") }
            }
            network.start(queue: DispatchQueue(label: "sway.network"))
        }
    }
    private func configurePlayer() {
        player.automaticallyWaitsToMinimizeStalling = true
        #if targetEnvironment(simulator)
        // 개발 중 Mac 스피커에서 소리가 나지 않게 한다. 실제 iPhone은 정상 음량이다.
        player.isMuted = true
        #endif
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                // 이전 item의 알림이 도착했을 때는 이미 다음 곡으로 바뀌었을 수 있다.
                let status = self.player.timeControlStatus
                self.isPlaying = status == .playing
                self.isLoading = self.wantsPlayback && (self.resolving || status == .waitingToPlayAtSpecifiedRate)
                if status == .playing { self.endBackgroundWork() }
                self.updateNowPlaying()
            }
        }
    }

    func play(_ tracks: [Track], at index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        checkpoint(); stopMixRequest(); queue.start(tracks, at: index)
        failures = 0; connectionRetries = 0; wantsPlayback = true; interrupted = false; startCurrent()
    }
    func toggle() { showsPause ? pause() : resume() }
    func pause() {
        wantsPlayback = false; interruptionResume = false; networkResume = false
        if resolving { loadTask?.cancel(); generation = UUID(); resolving = false }
        endBackgroundWork()
        retryTask?.cancel(); stallTask?.cancel(); cancelPrefetch()
        player.pause(); isPlaying = false; isLoading = false; checkpoint(); updateNowPlaying()
        refreshIdleSession()
    }
    func resume() {
        guard current != nil else { return }
        wantsPlayback = true; interrupted = false; interruptionResume = false; connectionRetries = 0
        // 기기에 끝까지 저장된 곡은 인터넷 없이 재개한다.
        guard online || playsLocalFile || current.map({ audioCache.isComplete($0.id) }) == true else {
            networkResume = true; message = "인터넷에 연결되면 다시 재생할게요."; return
        }
        if player.currentItem == nil || player.currentItem?.status == .failed {
            startCurrent(at: duration > 0 && elapsed >= duration - 0.5 ? 0 : elapsed, refreshing: player.currentItem?.status == .failed)
        }
        else {
            do { try activateSession() } catch { message = "오디오를 시작하지 못했어요."; wantsPlayback = false; return }
            beginBackgroundWork()
            if duration > 0 && elapsed >= duration - 0.5 { seek(to: 0) }
            player.play(); updateNowPlaying()
        }
        replenishMix()
    }
    func next() {
        checkpoint(); if !mixActive { stopMixRequest() }
        if queue.advance() { failures = 0; connectionRetries = 0; wantsPlayback = true; interrupted = false; startCurrent(); replenishMix() }
        else { pause(); if mixActive { message = "알고리즘 추천곡을 모두 들었어요." } }
    }
    func previous() {
        if elapsed > 3 || queue.index == 0 { seek(to: 0); return }
        checkpoint(); queue.previous(); failures = 0; connectionRetries = 0; wantsPlayback = true; interrupted = false; startCurrent()
    }
    func jump(to index: Int) { checkpoint(); queue.jump(to: index); failures = 0; connectionRetries = 0; wantsPlayback = true; interrupted = false; startCurrent(); replenishMix() }
    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        elapsed = min(max(0, seconds), max(duration, 0))
        listeningProgress.seek(to: elapsed)
        loader?.updatePlayhead(elapsed)
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        checkpoint(); updateNowPlaying()
    }
    func cycleRepeat() {
        guard !mixActive else { return }
        queue.repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
        checkpoint(); prepareNext()
    }
    func shuffle() { queue.shuffleRemaining(); checkpoint(); prepareNext() }
    func startMix(_ seed: Track) {
        if current?.id != seed.id { play([seed]) }
        stopMixRequest(); mixExhausted = false
        queue.enableMix(seed: seed, candidates: []); checkpoint()
        let token = UUID(); mixGeneration = token; isMixLoading = true
        mixTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == mixGeneration { isMixLoading = false } }
            do {
                let recent = Set(library.snapshot.history.prefix(20).map(\.trackID)).union([seed.id])
                let tracks = try await mixLoader(seed.id, nil, recent)
                try Task.checkCancellation()
                guard token == mixGeneration, current?.id == seed.id else { return }
                let candidates = MixPolicy.candidates(tracks, excluding: recent).shuffled()
                guard !candidates.isEmpty else { message = "추천할 정식 음원을 찾지 못했어요. 현재 재생은 유지돼요."; isMixLoading = false; return }
                queue.enableMix(seed: seed, candidates: candidates); checkpoint(); isMixLoading = false; prepareNext()
            } catch {
                guard token == mixGeneration, !Task.isCancelled else { return }
                isMixLoading = false; message = "알고리즘 추천곡을 불러오지 못했어요. 현재 재생은 유지돼요."
            }
        }
    }
    func stopMix() { stopMixRequest(); queue.stopMix(); checkpoint(); prepareNext() }
    private func stopMixRequest() {
        mixTask?.cancel(); mixGeneration = UUID(); isMixLoading = false
    }
    private func replenishMix() {
        guard let seed = queue.mixSeed, queue.remaining <= 3, !isMixLoading, !mixExhausted else { return }
        let token = UUID(); mixGeneration = token; isMixLoading = true
        let anchor = queue.tracks.last?.id
        // 원래 seed를 유지한다. 장르가 점점 멀어지는 연쇄 추천을 피한다.
        mixTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == mixGeneration { isMixLoading = false } }
            do {
                let recent = Set(library.snapshot.history.prefix(20).map(\.trackID))
                let candidates = try await mixLoader(seed.id, anchor, recent.union(queue.tracks.map(\.id)))
                try Task.checkCancellation()
                guard token == mixGeneration, queue.mixSeed?.id == seed.id else { return }
                let before = queue.tracks.count
                queue.appendMix(MixPolicy.candidates(candidates, excluding: recent).shuffled())
                mixExhausted = queue.tracks.count == before; checkpoint(); prepareNext()
            } catch {
                guard token == mixGeneration, !Task.isCancelled else { return }
                message = "알고리즘 추천곡을 더 불러오지 못했어요. 남은 곡까지 재생해요."
            }
        }
    }

    private func startCurrent(at position: Double = 0, renewal: Bool = false, refreshing: Bool = false) {
        guard let track = current else { return }
        if listeningTrackID != track.id || (position == 0 && !renewal && !refreshing) {
            listeningTrackID = track.id; listeningProgress = ListeningProgress()
        }
        listeningProgress.seek(to: position)
        // 준비 중인 현재 곡은 유지해 새 재생 요청이 같은 작업에 합류하게 한다.
        if prefetchID != track.id || renewal || refreshing { cancelPrefetch() }
        loadTask?.cancel(); retryTask?.cancel(); stallTask?.cancel(); generation = UUID(); let token = generation
        statusObservation = nil; player.pause(); player.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil
        isPlaying = false; isLoading = wantsPlayback; resolving = true
        elapsed = max(0, position); duration = track.duration ?? 0; sourceDuration = nil; bitrate = 0; recorded = false
        lastCheckpoint = position; if !renewal { renewed = false; artwork = nil; fetchArtwork(track) }
        checkpoint(); updateNowPlaying()
        // 재생 실패 후 다시 받는 경우 저장본이 원인일 수 있으니 버린다. 끝까지 저장된 곡은 주소 조회 없이 재생한다.
        if renewal { audioCache.remove(track.id) }
        let cached = renewal ? nil : audioCache.completeFile(track.id)
        let cache = audioCache, playingID = track.id
        Task.detached(priority: .utility) { cache.enforceLimit(protecting: [playingID]) }
        guard online || cached != nil else { resolving = false; isLoading = false; networkResume = wantsPlayback; endBackgroundWork(); return }
        beginBackgroundWork()
        // 탭한 시점(첫 await 이전)에 재생 세션을 확보한다. 잠긴 뒤 카테고리를 바꾸지 않는다.
        do { try activateSession() }
        catch { pause(); message = "지금은 오디오를 시작할 수 없어요. 통화나 다른 재생이 끝난 뒤 다시 눌러주세요."; return }
        let invalidation = pendingInvalidation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                await invalidation?.value
                try Task.checkCancellation()
                let item: AVPlayerItem, sourceLength: Double?
                if let cached {
                    guard generation == token else { return }
                    item = AVPlayerItem(url: cached.url); bitrate = cached.meta.bitrate; sourceLength = cached.meta.duration
                } else {
                    let audio = try await resolver.resolve(track.id, refreshing: renewal || refreshing)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    // 재생 위치 앞만 조금씩 받으며 저장한다. 길이 정보가 없는 주소는 예전처럼 AVPlayer가 직접 받는다.
                    let resolver = resolver, id = track.id
                    #if DEBUG
                    let log = Logger(subsystem: "com.tinkerer0.solomusic", category: "audio-loader")
                    let onEvent: (@Sendable (String) -> Void)? = { log.info("\(id, privacy: .public) \($0, privacy: .public)") }
                    #else
                    let onEvent: (@Sendable (String) -> Void)? = nil
                    #endif
                    if let made = CachingAudioLoader(id: id, audio: audio, startAt: position, cache: audioCache,
                                                     refresh: { try await resolver.resolve(id, refreshing: true).url }, onEvent: onEvent) {
                        loader = made; item = made.makeItem()
                    } else { item = AVPlayerItem(url: audio.url) }
                    bitrate = audio.bitrate; sourceLength = audio.duration
                }
                item.preferredForwardBufferDuration = 15
                if let exactDuration = sourceLength {
                    sourceDuration = exactDuration; duration = exactDuration
                    // 일부 DASH AAC에서 AVFoundation의 추정 길이가 실제의 두 배로 나왔다.
                    // 스트림이 선언한 길이와 ffprobe가 일치한 값을 표시·종료 경계에 사용한다.
                    item.forwardPlaybackEndTime = CMTime(seconds: exactDuration, preferredTimescale: 44_100)
                }
                statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    if item.status == .failed { Task { @MainActor in self?.itemFailed(token: token) } }
                }
                player.replaceCurrentItem(with: item)
                let restoredPosition = duration > 0 && position >= duration - 0.5 ? 0 : position
                if restoredPosition > 0 { await player.seek(to: CMTime(seconds: restoredPosition, preferredTimescale: 600)) }
                guard generation == token else { return }
                resolving = false; isLoading = false
                if wantsPlayback && !interrupted && (online || cached != nil) {
                    player.play()
                }
                // 주소 조회 완료와 첫 재생은 다르다. 버퍼링까지 보호하고 .playing에서 종료한다.
                updateNowPlaying()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                resolving = false; isLoading = false
                if error is AudioError { failTrack() }
                else { recoverConnection() }
            }
        }
    }
    private func itemFailed(token: UUID) {
        guard generation == token else { return }
        handleItemFailure()
    }
    func handleItemFailure() {
        guard wantsPlayback else { isLoading = false; return }
        if !online || player.currentItem?.error.map(isNetworkError) == true { recoverConnection(); return }
        if !renewed { renewed = true; startCurrent(at: elapsed, renewal: true) } else { recoverConnection() }
    }
    private func recoverConnection() {
        player.pause(); isPlaying = false; isLoading = false
        guard wantsPlayback else { return }
        guard online else { networkResume = true; message = "인터넷 연결을 기다리고 있어요."; return }
        guard connectionRetries < 1 else { pause(); message = "지금 이 곡을 재생할 수 없어요. 잠시 후 다시 시도하거나 다음 곡을 골라주세요."; return }
        connectionRetries += 1; isLoading = true
        let token = generation
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: retryDelay) } catch { return }
            guard token == generation, wantsPlayback, !interrupted else { return }
            startCurrent(at: elapsed, refreshing: true)
        }
    }
    private func failTrack() {
        failures += 1
        guard wantsPlayback, failures < 3, queue.advance() else {
            pause(); message = "이 곡을 재생하지 못했어요. 보관함에는 그대로 남아 있어요."; return
        }
        message = "재생할 수 없는 곡을 건너뛰었어요."; startCurrent()
    }
    private func cancelPrefetch() {
        prefetchTask?.cancel(); prefetchTask = nil; prefetchID = nil; prefetchToken = UUID()
    }
    private func prepareNext() {
        // 실제 재생 진행을 확인한 뒤 주소만 준비한다. 앱 진입·일시정지·로딩에는 실행하지 않는다.
        guard wantsPlayback, !interrupted, online, !resolving, isPlaying, elapsed > 0.05 else { return }
        guard queue.remaining > 0, repeatMode != .one else { cancelPrefetch(); return }
        let next = queue.tracks[queue.index + 1]
        guard prefetchID != next.id, !audioCache.isComplete(next.id) else { return }
        cancelPrefetch(); prefetchID = next.id
        let token = prefetchToken, invalidation = pendingInvalidation
        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await invalidation?.value
            guard !Task.isCancelled else { return }
            _ = try? await resolver.resolve(next.id)
            if prefetchToken == token { prefetchTask = nil }
        }
    }
    private func ended(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        checkpoint()
        guard wantsPlayback else { return }
        if queue.repeatMode == .one { listeningProgress = ListeningProgress(); seek(to: 0); player.play(); return }
        if queue.advance(automatically: true) { connectionRetries = 0; startCurrent(); replenishMix() }
        else { pause(); if mixActive { message = "알고리즘 추천곡을 모두 들었어요." } }
    }
    private func tick() {
        guard player.currentItem != nil else { return }
        let value = player.currentTime().seconds
        if value.isFinite { elapsed = max(0, value); loader?.updatePlayhead(elapsed) }
        if sourceDuration == nil, let value = player.currentItem?.duration.seconds, value.isFinite, value > 0 { duration = value }
        if isPlaying, elapsed > 1, !recorded {
            recorded = true; failures = 0; library.checkpoint(queue, position: elapsed, record: true)
        }
        if listeningProgress.observe(position: elapsed, playing: isPlaying, duration: duration), let track = current {
            library.recordQualifiedListen(track)
        }
        if isPlaying, abs(elapsed - lastCheckpoint) >= 15 { checkpoint() }
        prepareNext(); updateNowPlaying()
    }
    func checkpoint() {
        library.checkpoint(queue, position: elapsed); lastCheckpoint = elapsed
    }
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground { checkpoint() }
        refreshIdleSession()
    }
    private func refreshIdleSession() {
        // 재생·로딩·통화 중에는 기존 세션의 소유권과 재개 의도를 유지한다.
        guard !wantsPlayback, !interrupted else { return }
        do {
            if isForeground {
                // 한 번 재생한 뒤(일시정지)에는 재생 세션을 그대로 둔다. 섞어 재생으로 바꾸면 iOS가 Sway를
                // NowPlaying 앱에서 내리고, 다음에 곡을 누르고 바로 잠그면 화면이 꺼진 채 재생을 시작하지
                // 못한다(2026-10-27 실기기 audiomxd "can't stop others … not the NowPlaying app").
                if Self.holdsPlaybackSession(AVAudioSession.sharedInstance()) { return }
                // 첫 화면에서도 미디어 음량을 준비한다. 앱을 열기만 해서는 다른 앱의 음악을 끊지 않는다.
                try activateSession(mixing: true)
            } else {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            Logger(subsystem: "com.tinkerer0.solomusic", category: "audio-session")
                .error("Idle audio session update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    private func activateSession(mixing: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // 섞어 재생 세션이 켜진 채 카테고리만 바꾸면 활성화가 일어나지 않는다. 먼저 끄고 다시 켜서 화면이 켜진
        // 탭 시점에 재생 세션을 새로 활성화한다(NowPlaying을 가져오는지는 실기기 확인 전, 2026-10-27).
        if !mixing, session.categoryOptions.contains(.mixWithOthers) { try? session.setActive(false) }
        // longFormAudio는 mixWithOthers를 거부한다. 대기할 때만 기본 경로를 쓴다.
        try session.setCategory(.playback, mode: .default, policy: mixing ? .default : .longFormAudio, options: mixing ? .mixWithOthers : [])
        try session.setActive(true)
    }
    /// 이 프로세스가 재생용(섞지 않는) 세션을 잡은 적이 있는지. 첫 실행의 기본 카테고리는 soloAmbient다.
    static func holdsPlaybackSession(_ session: AVAudioSession) -> Bool {
        session.category == .playback && !session.categoryOptions.contains(.mixWithOthers)
    }
    private func observeSystem() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in self?.ended(item) }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in guard let self, item === self.player.currentItem else { return }; self.handleItemFailure() }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.stallTask?.cancel(); let token = self.generation
                self.stallTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                    guard let self, token == self.generation, self.wantsPlayback, !self.isPlaying else { return }
                    self.recoverConnection()
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.handleInterruption(began: type == .began, shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let observer = self.timeObserver { self.player.removeTimeObserver(observer) }
                self.statusObservation = nil; self.playerObservation = nil
                self.player.pause(); self.player = AVPlayer(); self.configurePlayer()
                if self.wantsPlayback { self.startCurrent(at: self.elapsed, refreshing: true) }
                else { self.refreshIdleSession() }
            }
        })
    }
    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        if began {
            interrupted = true; interruptionResume = wantsPlayback; player.pause(); isPlaying = false; cancelPrefetch()
            if resolving { loadTask?.cancel(); generation = UUID(); resolving = false; isLoading = false }
            endBackgroundWork()
        } else {
            guard interrupted else { return }
            interrupted = false
            if interruptionResume && wantsPlayback && shouldResume { resume() } else { pause() }
            interruptionResume = false
        }
    }
    func networkChanged(_ available: Bool, signature: String) {
        let wasOnline = online, changed = networkSignature != nil && networkSignature != signature
        networkSignature = signature; online = available
        if changed {
            cancelPrefetch(); loader?.markSourceStale()
            let previous = pendingInvalidation, resolver = resolver
            pendingInvalidation = Task { await previous?.value; await resolver.invalidateAll() }
        }
        if !available, !resolving, playsLocalFile {
            // 끝까지 저장된 곡은 인터넷 없이 계속 재생한다.
            cancelPrefetch()
        } else if !available {
            networkResume = wantsPlayback; loadTask?.cancel(); retryTask?.cancel(); stallTask?.cancel()
            cancelPrefetch(); generation = UUID(); resolving = false; endBackgroundWork()
            player.pause(); isPlaying = false; isLoading = false
            if wantsPlayback { message = "인터넷 연결을 기다리고 있어요." }
        } else if !wasOnline && networkResume && wantsPlayback {
            networkResume = false; message = nil; startCurrent(at: elapsed, refreshing: true)
        } else if changed && resolving && wantsPlayback {
            startCurrent(at: elapsed, refreshing: true)
        }
    }
    private var playsLocalFile: Bool { (player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true }
    private func isNetworkError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return ![NSURLErrorCancelled, NSURLErrorFileDoesNotExist].contains(error.code) }
        if let nested = error.userInfo[NSUnderlyingErrorKey] as? NSError, nested !== error { return isNetworkError(nested) }
        return false
    }
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in Task { @MainActor in action(event) }; return .success }
            remoteTargets.append((command, target))
        }
        bind(center.playCommand) { [weak self] _ in self?.resume() }
        bind(center.pauseCommand) { [weak self] _ in self?.pause() }
        bind(center.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        bind(center.nextTrackCommand) { [weak self] _ in self?.next() }
        bind(center.previousTrackCommand) { [weak self] _ in self?.previous() }
        bind(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
        center.skipForwardCommand.isEnabled = false; center.skipBackwardCommand.isEnabled = false
    }
    private func updateNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func fetchArtwork(_ track: Track) {
        artworkTask?.cancel()
        guard let url = track.artworkURL else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), data.count < 2_000_000,
                  !Task.isCancelled, let self, current?.id == track.id else { return }
            artwork = UIImage(data: data); updateNowPlaying()
        }
    }
    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        let token = UUID(); backgroundGeneration = token
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sway track transition") { [weak self] in
            Task { @MainActor in
                guard let self, self.backgroundGeneration == token else { return }
                self.expireBackgroundWork()
            }
        }
    }
    func expireBackgroundWork() {
        let pending = wantsPlayback && player.timeControlStatus != .playing
        endBackgroundWork()
        if pending { pause(); message = "재생 준비 시간이 초과했어요. 인터넷 연결을 확인하고 다시 재생해 주세요." }
    }
    private func endBackgroundWork() {
        backgroundGeneration = UUID()
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}
