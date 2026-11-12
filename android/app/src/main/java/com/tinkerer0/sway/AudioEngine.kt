@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.app.Application
import android.app.PendingIntent
import android.app.job.JobScheduler
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import androidx.media3.common.*
import androidx.media3.datasource.*
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.session.*
import androidx.core.content.edit
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.disk.DiskCache
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

class SwayApp : Application(), ImageLoaderFactory {
    val graph by lazy { AudioGraph(this) }
    // 썸네일을 앱 재실행 사이에 재사용한다(iOS 판의 디스크 캐시와 같은 목적).
    override fun newImageLoader() = ImageLoader.Builder(this).diskCache { DiskCache.Builder().directory(cacheDir.resolve("images")).maxSizeBytes(50L * 1024 * 1024).build() }.build()
}

/** 음원은 HTTP→Media3 버퍼로 받고, 들은 바이트는 다시 듣기용 저장(AudioCache)에 남긴다. 보관함 저장은 네트워크를 호출하지 않는다.
 *  받아 두기를 켠 재생목록의 곡은 데이터 요금이 없는 연결에서 OfflineStore에 받고, 다 받은 곡은 거기서만 읽는다. */
class AudioGraph(val app: Application, private val mixLoader: ((String) -> List<Track>)? = null) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val library = LibraryStore(File(app.noBackupFilesDir, "library.json"))
    val catalog = Catalog(File(app.cacheDir, "http"))
    val audioCache = AudioCache.get(app)
    val offline = OfflineStore.get(app)
    val messages = MutableStateFlow<String?>(library.readError)
    val mixSeed = MutableStateFlow<Track?>(null)
    val mixing = MutableStateFlow(false)
    val audioBytes = AtomicLong()
    val audioRequests = AtomicLong()
    val discovery = DiscoveryStore(File(app.cacheDir, "discovery.json"), catalog)
    var player: ExoPlayer? = null
    var persistPlayback: () -> Unit = {}
    private val resolved = ConcurrentHashMap<String, Pair<Long, Audio>>()
    private var mixJob: Job? = null
    private var mixGeneration = 0
    private var mixExhausted = false
    init {
        // v1의 부팅/네트워크 재개 작업을 중단한다. 기존 음원은 사용자가 지우기 전까지 보존.
        app.getSystemService(JobScheduler::class.java).cancel(103)
    }
    private fun http(bytes: AtomicLong, requests: AtomicLong) = DefaultHttpDataSource.Factory().setUserAgent(AGENT)
        .setDefaultRequestProperties(mapOf("Range" to "bytes=0-"))
        .setConnectTimeoutMs(20000).setReadTimeoutMs(30000)
        .setTransferListener(object : TransferListener {
            override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) { if (isNetwork) requests.incrementAndGet() }
            override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
            override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) { if (isNetwork) bytes.addAndGet(bytesTransferred.toLong()) }
            override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        })
    private val httpFactory = http(audioBytes, audioRequests)
    /** [store]는 CacheDataSource 아래에서 쓸 때 그 저장소다. 저장을 거치지 않는 경로는 저장소를 건드리지 않는다. */
    private fun upstreamFactory(store: FormatStore?, http: DataSource.Factory = httpFactory) = DataSource.Factory {
        // 이 소스(한 번의 재생 준비·한 곡 받기)가 처음 고른 형식. 저장소에 아직 확정되지 않은 바이트(CacheDataSink는 5 MiB 단위로 확정)나
        // 다른 경로가 같은 곡의 기억한 주소를 다른 형식으로 바꿔도, 다시 열 때(구간 이동·받기 조각) 같은 형식만 쓴다.
        var pinned: String? = null
        RefreshingAudioSource(http.createDataSource()) { spec, force ->
            require(spec.uri.host == "sway.invalid")
            val id = spec.uri.pathSegments.first(); require(Track.validId(id))
            // 일부 저장된 곡은 저장된 바이트와 같은 형식으로만 이어 받는다. 형식 기록이 없는 저장본은 remember가 낡은 것으로 판정한다.
            val required = store?.stored(id)?.formatId?.takeIf { it.isNotEmpty() } ?: pinned
            val old = resolved[id]
            val audio = if (!force && old != null && System.currentTimeMillis() - old.first < 15 * 60_000 && (required == null || required == old.second.formatId)) old.second
            else catalog.audio(id, required ?: if (spec.position > 0) old?.second?.formatId else null).also {
                if (resolved.size > 32) resolved.clear()
                resolved[id] = System.currentTimeMillis() to it
            }
            store?.remember(id, audio)
            pinned = audio.formatId
            spec.withUri(Uri.parse(audio.url))
        }
    }
    private val upstreamFactory = upstreamFactory(null)
    internal val cachedFactory by lazy { CacheDataSource.Factory().setCache(audioCache.cache).setUpstreamDataSourceFactory(upstreamFactory(audioCache))
        .setCacheKeyFactory(AudioCache.KEY).setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR) }
    /** 받아 둔 곡을 읽기만 한다. 상류가 없어 빈 구간이 있으면 네트워크로 채우지 않고 실패한다. */
    private val offlineReader by lazy { CacheDataSource.Factory().setCache(offline.cache).setCacheKeyFactory(AudioCache.KEY).setCacheWriteDataSinkFactory(null) }
    /** 받아 둔 곡과 끝까지 저장된 곡은 주소 조회 없이 기기에서 읽어 인터넷 없이도 재생한다. '저장 안 함'이면 받아 두지 않은 곡은 스트리밍만 한다. */
    fun playbackFactory() = DataSource.Factory {
        OfflineFirstSource(if (audioCache.enabled) cachedFactory.createDataSource() else upstreamFactory.createDataSource()) { spec ->
            spec.uri.lastPathSegment?.takeIf { offline.playable(it) }?.let { offlineReader.createDataSource() }
        }
    }
    /** 받기는 재생과 다른 카운터로 센다. 받기용 주소 조회도 데이터 요금이 없는 연결에서만 일어난다. */
    private val downloadUpstream by lazy { upstreamFactory(offline, http(offline.downloadBytes, offline.downloadRequests)).let { f -> DataSource.Factory { ChunkedSource(f.createDataSource()) } } }
    /** 프로세스에 하나. 처음 부르는 곳(화면·받기 서비스)은 화면 스레드다. */
    val downloadManager: DownloadManager get() = offline.manager { downloadUpstream }
    /** 받아 두기를 켠 재생목록의 곡을 받고 빠진 곡은 지운다. 화면이 보일 때 화면 스레드에서 부른다. */
    fun syncOffline() {
        // 보관함을 읽지 못한 동안은 재생목록이 비어 보이므로 받은 곡을 지우지 않는다.
        if (library.readError != null) return
        try { downloadManager; offline.sync(library.state.value.playlists.filter { it.offline }.flatMapTo(LinkedHashSet()) { it.ids }) }
        catch (e: Exception) { messages.value = "받아 두기를 준비하지 못했어요. 앱을 다시 열어 주세요." }
    }
    /** 재생목록 받아 두기를 켜고 끈다. 지금 요금 연결이거나 연결이 없으면 Wi-Fi에서 받는다고 알린다. */
    fun setOffline(id: String, on: Boolean) {
        if (!edit { library.setOffline(id, on) } || !on) return
        val cm = app.getSystemService(ConnectivityManager::class.java)
        if (cm.activeNetwork == null || cm.isActiveNetworkMetered) messages.value = "Wi-Fi에 연결되면 받아요."
    }
    /** 화면에 보이는 음질 정보. 기기에 있는 곡은 주소를 조회하지 않으므로 저장본의 정보를 쓴다. 화면 스레드에서 부르지 않는다. */
    fun audioFor(id: String): Audio? = offline.stored(id)?.takeIf { it.formatId.isNotEmpty() && offline.playable(id) }
        ?: resolved[id]?.second ?: audioCache.stored(id)?.takeIf { it.formatId.isNotEmpty() }
    /** 낡은 저장본과 그 형식을 기억한 주소를 함께 버린다. 다음 open은 처음부터 다시 고른다. */
    fun dropStale(id: String) { resolved.remove(id); audioCache.forget(id) }
    /** 낡은 저장본 오류는 같은 요청을 반복해도 낫지 않으므로 바로 재생 오류로 넘긴다. */
    val loadErrorPolicy = object : DefaultLoadErrorHandlingPolicy() {
        override fun getRetryDelayMsFor(info: LoadErrorHandlingPolicy.LoadErrorInfo): Long =
            if (stale(info.exception)) C.TIME_UNSET else super.getRetryDelayMsFor(info)
    }
    fun mediaItem(track: Track) = MediaItem.Builder().setMediaId(track.id).setUri("https://sway.invalid/${track.id}")
        .setMediaMetadata(MediaMetadata.Builder().setTitle(track.title).setArtist(track.artist)
            .setArtworkUri(track.artwork.takeIf { it.isNotBlank() }?.let(Uri::parse))
            .setExtras(android.os.Bundle().apply { putLong("duration", track.duration) }).build()).build()
    fun track(item: MediaItem): Track? = if (!Track.validId(item.mediaId)) null else Track(item.mediaId,
        item.mediaMetadata.title?.toString().orEmpty(), item.mediaMetadata.artist?.toString().orEmpty(),
        item.mediaMetadata.extras?.getLong("duration") ?: 0, item.mediaMetadata.artworkUri?.toString().orEmpty())
    fun edit(action: () -> Unit): Boolean = try { action(); true } catch (_: Exception) { messages.value = "변경 내용을 저장하지 못했어요. 기존 보관함은 유지돼요."; false }
    fun save(track: Track, playlist: String? = null) = edit { if (playlist == null) library.save(track) else library.addToPlaylist(playlist, track) }
    fun play(track: Track, queue: List<Track> = listOf(track)) {
        val p = player ?: return
        stopMix(); p.setMediaItems(queue.map(::mediaItem), queue.indexOfFirst { it.id == track.id }.coerceAtLeast(0), 0)
        p.prepare(); p.play()
    }
    fun toggle() { player?.let { if (it.playWhenReady) it.pause() else { if (it.playbackState == Player.STATE_IDLE) it.prepare(); it.play() } } }
    fun stopMix() { mixGeneration++; mixJob?.cancel(); mixJob = null; mixing.value = false; mixSeed.value = null; mixExhausted = false; persistPlayback() }
    fun startMix(seed: Track) {
        val p = player ?: return
        stopMix()
        if (p.currentMediaItem?.mediaId != seed.id) { p.setMediaItem(mediaItem(seed)); p.prepare(); p.play() }
        if (p.currentMediaItemIndex + 1 < p.mediaItemCount) p.removeMediaItems(p.currentMediaItemIndex + 1, p.mediaItemCount)
        p.repeatMode = Player.REPEAT_MODE_OFF; p.shuffleModeEnabled = false
        mixSeed.value = seed; persistPlayback(); replenishMix()
    }
    fun replenishMix() {
        val p = player ?: return; val seed = mixSeed.value ?: return
        if (mixing.value || mixExhausted || p.mediaItemCount - p.currentMediaItemIndex > 4) return
        val token = mixGeneration; val anchor = p.currentMediaItem?.mediaId ?: seed.id
        mixing.value = true
        mixJob = scope.launch {
            try {
                val candidates = withContext(Dispatchers.IO) { (mixLoader ?: catalog::mix).invoke(anchor) }
                if (token != mixGeneration || player !== p) return@launch
                val excluded = (0 until p.mediaItemCount).map { p.getMediaItemAt(it).mediaId }.toSet() + library.state.value.recent.take(20).map { it.id }
                val fresh = candidates.filter { it.id !in excluded }
                mixExhausted = fresh.isEmpty()
                if (fresh.isNotEmpty()) {
                    val ended = p.playbackState == Player.STATE_ENDED && p.playWhenReady
                    p.addMediaItems(fresh.map(::mediaItem))
                    if (ended) { p.seekToNextMediaItem(); p.prepare(); p.play() }
                } else messages.value = "새로운 알고리즘 추천곡을 찾지 못했어요. 현재 대기열까지 재생해요."
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                mixExhausted = true; messages.value = "알고리즘 추천곡을 불러오지 못했어요. 껐다 켜면 다시 시도해요."
            } finally { if (token == mixGeneration) mixing.value = false }
        }
    }
    /** 화면이 보이는지. 보이지 않을 때 쌓인 알림이 나중에 뜨지 않게 한다. */
    @Volatile var visible = false
    private val settings = app.getSharedPreferences("settings", Application.MODE_PRIVATE)
    var meteredNotice: Boolean
        get() = settings.getBoolean("meteredNotice", true)
        set(value) { settings.edit { putBoolean("meteredNotice", value) } }
    @Volatile private var noticed: Network? = null
    /** 받아 두지 않은 곡을 모바일 데이터 같은 요금 연결로 재생하기 시작하면 연결마다 한 번 알린다. */
    fun noticeMetered(id: String) {
        if (!meteredNotice || !visible) return
        scope.launch(Dispatchers.IO) {
            val cm = app.getSystemService(ConnectivityManager::class.java)
            val network = cm.activeNetwork ?: return@launch
            if (!cm.isActiveNetworkMetered || network == noticed) return@launch
            if (offline.playable(id) || (audioCache.enabled && runCatching { audioCache.isComplete(id) }.getOrDefault(false))) return@launch
            noticed = network
            if (visible) messages.value = "모바일 데이터로 듣고 있어요. 받아 둔 곡은 데이터를 쓰지 않아요."
        }
    }
    fun legacyBytes(): Long = File(app.noBackupFilesDir, "audio").walkTopDown().filter { it.isFile }.sumOf { it.length() }
    fun deleteLegacy() = edit { check(File(app.noBackupFilesDir, "audio").let { !it.exists() || it.deleteRecursively() }) }
}

fun stale(error: Throwable?) = generateSequence(error) { it.cause }.any { it is StaleAudioException }

data class PlaybackSnapshot(val tracks: List<Track>, val index: Int, val position: Long, val repeat: Int = 0, val shuffle: Boolean = false, val seed: Track? = null) {
    fun json(): String = JSONObject().put("version", 1).put("tracks", JSONArray(tracks.map { it.json() })).put("index", index)
        .put("position", position.coerceAtLeast(0)).put("repeat", repeat).put("shuffle", shuffle).put("seed", seed?.json()).toString()
    companion object {
        fun parse(text: String): PlaybackSnapshot {
            val o = JSONObject(text); require(o.getInt("version") == 1)
            val a = o.getJSONArray("tracks"); val tracks = (0 until a.length()).map { Track.parse(a.getJSONObject(it)) }
            val index = o.getInt("index"); require(index in tracks.indices)
            return PlaybackSnapshot(tracks, index, o.optLong("position").coerceAtLeast(0), o.optInt("repeat").coerceIn(0, 2), o.optBoolean("shuffle"), o.optJSONObject("seed")?.let(Track::parse))
        }
    }
}

class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private val graph get() = (application as SwayApp).graph
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var stateFile: AtomicFile
    private var restoring = true
    private var progress = ListeningProgress()
    private var retried: String? = null
    private var ticks = 0
    private fun checkpoint() {
        if (restoring) return
        val p = session?.player ?: return
        if (p.mediaItemCount == 0) return
        val snapshot = PlaybackSnapshot((0 until p.mediaItemCount).mapNotNull { graph.track(p.getMediaItemAt(it)) }, p.currentMediaItemIndex,
            p.currentPosition, p.repeatMode, p.shuffleModeEnabled, graph.mixSeed.value)
        runCatching {
            val stream = stateFile.startWrite()
            try { stream.write(snapshot.json().toByteArray()); stateFile.finishWrite(stream) }
            catch (e: Exception) { stateFile.failWrite(stream); throw e }
        }.onFailure { graph.messages.value = "재생 위치를 저장하지 못했어요." }
    }
    override fun onCreate() {
        super.onCreate()
        stateFile = AtomicFile(File(noBackupFilesDir, "playback.json"))
        val player = ExoPlayer.Builder(this).setMediaSourceFactory(DefaultMediaSourceFactory(graph.playbackFactory()).setLoadErrorHandlingPolicy(graph.loadErrorPolicy))
            .setLoadControl(DefaultLoadControl.Builder().setBufferDurationsMs(15000, 30000, 1000, 2500).build()).build()
        graph.player = player
        player.setAudioAttributes(AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).setUsage(C.USAGE_MEDIA).build(), true)
        player.setHandleAudioBecomingNoisy(true); player.setWakeMode(C.WAKE_MODE_NETWORK)
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                graph.audioCache.protectedId = item?.mediaId; retried = null
                // '저장 안 함'에서는 새 구간이 쌓이지 않아 정리가 일어나지 않으므로, 곡이 바뀔 때 앞 곡의 저장본을 지운다.
                if (!graph.audioCache.enabled) graph.scope.launch(Dispatchers.IO) { runCatching { graph.audioCache.trim() } }
                progress = ListeningProgress(); if (!restoring) { checkpoint(); if (player.isPlaying) record(); if (player.playWhenReady) item?.mediaId?.let(graph::noticeMetered) } }
            override fun onIsPlayingChanged(playing: Boolean) { if (!restoring) { if (playing) { record(); graph.replenishMix(); player.currentMediaItem?.mediaId?.let(graph::noticeMetered) }; checkpoint() } }
            override fun onPositionDiscontinuity(old: Player.PositionInfo, new: Player.PositionInfo, reason: Int) { progress.seek(new.positionMs); checkpoint() }
            override fun onRepeatModeChanged(repeatMode: Int) { checkpoint() }
            override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) { checkpoint() }
            override fun onTimelineChanged(timeline: Timeline, reason: Int) { checkpoint() }
            override fun onPlayerError(error: PlaybackException) {
                val id = player.currentMediaItem?.mediaId
                // 저장본이 깨졌거나 원본 형식이 바뀌었으면 저장본과 기억한 주소를 버리고 한 번만 다시 받는다.
                // 연결 오류(2xxx)와 코덱 초기화 같은 기기 쪽 오류는 다시 듣기용 저장본을 지우지 않는다.
                // 받아 둔 사본은 읽기 전용이라 2xxx도 사본 문제다. 사본을 빼고(Wi-Fi에서 다시 받음) 스트리밍으로 한 번 다시 시작한다.
                val corrupt = error.errorCode in 3000..3999 || error.errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED || stale(error)
                if (id != null && (corrupt || error.errorCode in 2000..2999) && retried != id) {
                    graph.scope.launch {
                        val local = withContext(Dispatchers.IO) { graph.offline.playable(id) }
                        // 그사이 다른 곡으로 넘어갔으면 그 곡을 건드리지 않는다. 재생 의사(playWhenReady)는 오류 뒤에도 남아 있다.
                        if (player.currentMediaItem?.mediaId != id) return@launch
                        if (!local && !corrupt) { fail(); return@launch }
                        retried = id
                        if (local) graph.offline.drop(id) else withContext(Dispatchers.IO) { graph.dropStale(id) }
                        if (player.currentMediaItem?.mediaId == id) player.prepare()
                    }
                    return
                }
                fail()
            }
            private fun fail() { player.pause(); graph.messages.value = "재생하지 못했어요. 인터넷 연결을 확인하고 다시 재생해 주세요." }
            override fun onPlaybackStateChanged(state: Int) { if (!restoring && player.playWhenReady) graph.replenishMix() }
            private fun record() { player.currentMediaItem?.let(graph::track)?.let { graph.edit { graph.library.recent(it) } } }
        })
        session = MediaSession.Builder(this, player).setSessionActivity(PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .setCallback(object : MediaSession.Callback {
                override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult =
                    if (controller.packageName == packageName || controller.isTrusted) super.onConnect(session, controller) else MediaSession.ConnectionResult.reject()
                override fun onAddMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo, items: MutableList<MediaItem>): ListenableFuture<MutableList<MediaItem>> =
                    Futures.immediateFuture(items.mapNotNull { graph.track(it)?.let(graph::mediaItem) }.toMutableList())
            }).build()
        val snapshot = runCatching { PlaybackSnapshot.parse(stateFile.openRead().bufferedReader().use { it.readText() }) }.getOrNull()
        if (snapshot != null) {
            player.setMediaItems(snapshot.tracks.map(graph::mediaItem), snapshot.index, snapshot.position)
            player.repeatMode = snapshot.repeat; player.shuffleModeEnabled = snapshot.shuffle; graph.mixSeed.value = snapshot.seed
        } else {
            val prefs = getSharedPreferences("playback", MODE_PRIVATE)
            val track = (graph.library.state.value.saved + graph.library.state.value.recent).find { it.id == prefs.getString("id", null) }
            if (track != null) player.setMediaItem(graph.mediaItem(track), prefs.getLong("position", 0).coerceAtLeast(0))
        }
        // 큐를 복원만 하고 prepare/play는 누를 때만 호출한다.
        graph.audioCache.protectedId = player.currentMediaItem?.mediaId
        restoring = false
        graph.persistPlayback = ::checkpoint
        handler.post(object : Runnable { override fun run() {
            if (progress.observe(player.currentPosition, player.isPlaying, player.duration)) player.currentMediaItem?.let(graph::track)?.let { graph.edit { graph.library.qualify(it) } }
            if (++ticks % 15 == 0) checkpoint()
            if (player.isPlaying) graph.replenishMix()
            handler.postDelayed(this, 1000)
        } })
    }
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session
    override fun onTaskRemoved(rootIntent: Intent?) { if (session?.player?.playWhenReady != true) stopSelf() }
    override fun onDestroy() { checkpoint(); handler.removeCallbacksAndMessages(null); graph.persistPlayback = {}; graph.player = null; graph.stopMix(); session?.run { player.release(); release() }; session = null; super.onDestroy() }
}
