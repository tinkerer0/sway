@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.app.Application
import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.MainThread
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.offline.*
import androidx.media3.exoplayer.scheduler.PlatformScheduler
import androidx.media3.exoplayer.scheduler.Requirements
import androidx.media3.exoplayer.scheduler.Scheduler
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * 재생목록 '받아 두기'. Wi-Fi처럼 데이터 요금이 없는 연결에서만 받고, 자동으로 지우지 않는 폴더(noBackupFilesDir/offline)에 둔다.
 * 다 받은 곡은 재생할 때 이 폴더에서만 읽는다. 받는 형식은 실제로 받기 시작할 때 고르므로 모바일 데이터에서는 주소도 조회하지 않는다.
 * 다운로드 ID·캐시 키는 영상 ID다. SimpleCache와 DownloadManager는 폴더·인덱스당 하나만 열 수 있어 프로세스에 하나만 둔다.
 * 0.1.0의 다운로드 폴더(noBackupFilesDir/audio)·인덱스와는 따로 둔다.
 */
class OfflineStore private constructor(private val app: Application) : FormatStore {
    companion object {
        /** 0.1.0의 job 103은 AudioGraph가 시작할 때 취소하므로 다른 번호를 쓴다. */
        const val JOB_ID = 104
        val REQUIREMENTS = Requirements(Requirements.NETWORK_UNMETERED or Requirements.DEVICE_STORAGE_NOT_LOW)
        fun request(id: String) = DownloadRequest.Builder(id, Uri.parse("https://sway.invalid/$id")).setCustomCacheKey(id).build()
        @Volatile private var instance: OfflineStore? = null
        fun get(app: Application) = instance ?: synchronized(this) { instance ?: OfflineStore(app).also { instance = it } }
    }
    override val cache: SimpleCache by lazy { SimpleCache(File(app.noBackupFilesDir, "offline"), NoOpCacheEvictor(), SwayDatabase.get(app)) }
    /** 받기로 받은 바이트·요청 수. 재생 카운터(AudioGraph.audioBytes)와 따로 센다. */
    val downloadBytes = AtomicLong()
    val downloadRequests = AtomicLong()
    /** 곡별 받기 상태. 화면 스레드에서만 바꾼다. */
    val downloads = MutableStateFlow<Map<String, Download>>(emptyMap())
    /** 받기를 막고 있는 조건(Requirements 플래그). 0이면 받을 수 있다. */
    val notMet = MutableStateFlow(0)
    /** 받아 둔 사본이 재생 중 깨진 곡. 다시 받을 때까지 재생에서 뺀다. */
    val broken: MutableSet<String> = ConcurrentHashMap.newKeySet()
    /** 받기로 한 곡. 처음 sync 전에는 null이라 아무것도 지우지 않는다. */
    private var wanted: Set<String>? = null
    private val staleRetried = mutableSetOf<String>()
    private var manager: DownloadManager? = null
    private val main = Handler(Looper.getMainLooper())

    /** 다 받은 곡이면 재생할 때 이 저장소에서만 읽는다. 화면 스레드에서 부르지 않는다. */
    fun playable(id: String) = id !in broken && runCatching { isComplete(id) }.getOrDefault(false)

    /** 처음 부를 때 받기용 상류(주소 조회) factory로 만든다. 화면 스레드에서 부른다. */
    @MainThread fun manager(upstream: () -> DataSource.Factory): DownloadManager = manager ?: run {
        val factory = CacheDataSource.Factory().setCache(cache).setCacheKeyFactory(AudioCache.KEY).setUpstreamDataSourceFactory(upstream())
        DownloadManager(app, DefaultDownloadIndex(SwayDatabase.get(app), "offline"), DefaultDownloaderFactory(factory, Runnable::run)).apply {
            // 주소 조회(Catalog.audio)는 한 번에 하나라 동시에 많이 받아도 빨라지지 않고 재생 시작만 늦어진다.
            maxParallelDownloads = 2
            requirements = REQUIREMENTS
            addListener(object : DownloadManager.Listener {
                override fun onInitialized(downloadManager: DownloadManager) {
                    downloads.value = downloadManager.downloadIndex.getDownloads().use { c -> buildMap { while (c.moveToNext()) put(c.download.request.id, c.download) } }
                    notMet.value = downloadManager.notMetRequirements
                    wanted?.let(::sync)
                    verify(downloadManager)
                }
                override fun onDownloadChanged(downloadManager: DownloadManager, download: Download, finalException: Exception?) {
                    val id = download.request.id
                    downloads.value = downloads.value + (id to download)
                    if (download.state == Download.STATE_COMPLETED) broken.remove(id)
                    // 받는 중 원본 형식이 사라졌으면 받은 부분을 버리고 처음부터 한 번 다시 받는다(지우면 onDownloadRemoved가 다시 넣는다).
                    if (download.state == Download.STATE_FAILED && stale(finalException) && staleRetried.add(id)) downloadManager.removeDownload(id)
                }
                override fun onDownloadRemoved(downloadManager: DownloadManager, download: Download) {
                    val id = download.request.id
                    downloads.value = downloads.value - id
                    if (wanted?.contains(id) == true) { downloadManager.addDownload(request(id)); kick(downloadManager) }
                }
                override fun onRequirementsStateChanged(downloadManager: DownloadManager, requirements: Requirements, notMetRequirements: Int) { notMet.value = notMetRequirements }
            })
        }.also { manager = it }
    }

    /**
     * 받기로 한 곡을 맞춘다. 빠진 곡은 지우고, 새 곡과 받지 못한 곡은 다시 넣는다. 화면이 보일 때 화면 스레드에서 부른다.
     * 받을 곡이 있으면 받기 서비스를 포그라운드로 시작한다. 백그라운드에서 시작한 서비스가 나중에 포그라운드로 바뀌면 Android 12 이상에서 막히기 때문이다.
     */
    @MainThread fun sync(want: Set<String>) {
        wanted = want
        val m = manager ?: return
        if (!m.isInitialized) return
        val have = downloads.value
        (have.keys - want).forEach(m::removeDownload)
        val add = want.filter { id -> have[id]?.state.let { it == null || it == Download.STATE_FAILED } }
        add.forEach { m.addDownload(request(it)) }
        val pending = have.filterKeys { it in want }.values.any { it.state == Download.STATE_QUEUED || it.state == Download.STATE_DOWNLOADING || it.state == Download.STATE_RESTARTING }
        if (add.isNotEmpty() || pending) kick(m)
    }
    /**
     * 받을 곡이 생기면 받기를 다시 켜고 서비스를 포그라운드로 시작한다. DownloadManager는 일시정지 상태로 만들어지고
     * 서비스 onCreate가 풀어 주므로, 서비스를 시작할 수 없는 때(Android 12 이상 백그라운드)에도 프로세스 안에서는 받게 한다.
     * 백그라운드에서 포그라운드 시작이 막히면 예외만 삼키고, 남은 곡은 앱을 열 때 이어 받는다.
     */
    @MainThread private fun kick(m: DownloadManager) {
        m.resumeDownloads()
        runCatching { DownloadService.startForeground(app, AudioDownloadService::class.java) }
    }
    /** 인덱스는 다 받았다고 하는데 파일이 없어진 곡을 앱 시작 때 한 번 찾아 지운다. 아직 받기로 한 곡이면 onDownloadRemoved가 다시 넣는다. */
    @MainThread private fun verify(m: DownloadManager) {
        val completed = downloads.value.filterValues { it.state == Download.STATE_COMPLETED }.keys
        if (completed.isEmpty()) return
        Thread {
            val missing = completed.filter { id -> runCatching { !isComplete(id) }.getOrDefault(false) }
            if (missing.isNotEmpty()) main.post { missing.forEach { id -> if (downloads.value[id]?.state == Download.STATE_COMPLETED) m.removeDownload(id) } }
        }.start()
    }
    /** 깨진 사본을 지운다. 아직 받기로 한 곡이면 onDownloadRemoved가 다시 넣어 데이터 요금이 없는 연결에서 다시 받는다. */
    @MainThread fun drop(id: String) { broken += id; manager?.removeDownload(id) }
}

/**
 * 받아 둔 곡은 기기에서만 읽고, 아니면 스트리밍 경로로 넘긴다. 처음 open에서 고른 경로를 이 소스(한 번의 재생 준비)가 끝날 때까지 쓴다.
 * 스트리밍 중 받기가 끝난 뒤 구간 이동으로 다시 열 때 다른 형식의 받은 사본으로 바뀌면 바이트 위치가 맞지 않기 때문이다.
 */
class OfflineFirstSource(private val stream: DataSource, private val local: (DataSpec) -> DataSource?) : DataSource {
    private val listeners = mutableListOf<TransferListener>()
    private var route: DataSource? = null
    private var current: DataSource? = null
    override fun addTransferListener(transferListener: TransferListener) { listeners += transferListener; stream.addTransferListener(transferListener) }
    override fun open(dataSpec: DataSpec): Long {
        val source = route ?: (local(dataSpec)?.also { s -> listeners.forEach(s::addTransferListener) } ?: stream).also { route = it }
        // open이 실패해도 close가 같은 소스를 닫도록 먼저 기억한다.
        current = source
        return source.open(dataSpec)
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int) = checkNotNull(current).read(buffer, offset, length)
    override fun getUri(): Uri? = current?.uri
    override fun getResponseHeaders(): Map<String, List<String>> = current?.responseHeaders ?: emptyMap()
    override fun close() { val source = current; current = null; source?.close() }
}

/**
 * 받기 요청을 4 MiB씩 나눈다. YouTube는 한 번에 10 MiB가 넘는 구간을 요청하면 재생 속도 수준으로 늦춘다
 * (yt-dlp도 같은 이유로 10 MiB씩 나눈다. 2026-11-04 Android 9 에뮬레이터에서 15 MB 곡을 한 번에 요청하면 약 32 KB/s).
 * 재생은 15–30초 앞까지만 받아 나누지 않는다. 첫 응답의 Content-Range로 전체 길이를 알면 그 길이를 돌려준다.
 */
class ChunkedSource(private val upstream: DataSource, private val chunk: Long = 4L shl 20) : DataSource {
    private val unset = C.LENGTH_UNSET.toLong()
    private lateinit var spec: DataSpec
    private var position = 0L
    private var end = unset
    private var want = 0L
    private var got = 0L
    private var opened = false
    override fun addTransferListener(transferListener: TransferListener) = upstream.addTransferListener(transferListener)
    override fun open(dataSpec: DataSpec): Long {
        spec = dataSpec; position = dataSpec.position
        end = if (dataSpec.length != unset) dataSpec.position + dataSpec.length else unset
        next()
        if (end == unset) upstream.responseHeaders.entries.firstOrNull { it.key.equals("Content-Range", true) }?.value?.firstOrNull()
            ?.substringAfterLast('/')?.toLongOrNull()?.let { end = it }
        return if (end == unset) unset else end - dataSpec.position
    }
    private fun next() {
        want = if (end == unset) chunk else minOf(chunk, end - position); got = 0
        // open이 실패해도 close가 상류를 닫도록 먼저 표시한다.
        opened = true
        upstream.open(spec.subrange(position - spec.position, want))
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        while (true) {
            if (end != unset && position >= end) return C.RESULT_END_OF_INPUT
            val n = upstream.read(buffer, offset, length)
            if (n != C.RESULT_END_OF_INPUT) { position += n; got += n; return n }
            // 이 조각이 끝났다. 요청한 만큼 다 왔으면 다음 조각을 열고, 덜 왔으면 파일 끝이다(전체 길이를 알면 일찍 끊긴 것).
            if (got < want) { if (end != unset) throw java.io.EOFException("받기 조각이 일찍 끝났어요."); return C.RESULT_END_OF_INPUT }
            upstream.close(); opened = false
            next()
        }
    }
    override fun getUri(): Uri? = upstream.uri
    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders
    override fun close() { if (opened) { opened = false; upstream.close() } }
}

class AudioDownloadService : DownloadService(102, DEFAULT_FOREGROUND_NOTIFICATION_UPDATE_INTERVAL, "sway-offline", R.string.offline_channel, R.string.offline_channel_description) {
    private val graph get() = (application as SwayApp).graph
    override fun getDownloadManager() = graph.downloadManager
    /** Media3가 Android 12 이상에서는 예약을 쓰지 않는다. Android 9~11에서는 앱이 꺼져 있어도 Wi-Fi가 생기면 다시 시작한다. */
    override fun getScheduler(): Scheduler = PlatformScheduler(this, OfflineStore.JOB_ID)
    override fun getForegroundNotification(downloads: MutableList<Download>, notMetRequirements: Int): Notification =
        DownloadNotificationHelper(this, "sway-offline").buildProgressNotification(this, android.R.drawable.stat_sys_download,
            PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE),
            when {
                notMetRequirements and (Requirements.NETWORK or Requirements.NETWORK_UNMETERED) != 0 -> "Wi-Fi에 연결되면 받아요"
                notMetRequirements != 0 -> "저장 공간이 부족해 기다리는 중"
                else -> "재생목록 곡을 받아 두는 중"
            }, downloads, notMetRequirements)
    /** 프로세스가 죽은 뒤 시스템이 다시 띄운 서비스는 백그라운드에서 시작한 셈이라, Wi-Fi가 생겨 포그라운드로 바꾸는 순간 Android 12 이상에서 예외로 앱이 멈춘다
     *  (Media3 1.8.0 Util.setForegroundServiceNotification은 예외를 잡지 않는다). 다시 띄우지 않고, 남은 곡은 앱을 열 때(Android 9~11은 예약으로) 이어 받는다. */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int { super.onStartCommand(intent, flags, startId); return START_NOT_STICKY }
    /** Android 15 이상에서 dataSync 포그라운드 서비스는 하루 6시간까지다. 넘으면 받기를 멈추고(서비스만 멈추면 프로세스 안에서 계속 받는다)
     *  서비스를 끝낸다. 남은 곡은 다음에 앱을 열 때 sync가 다시 켜서 이어 받는다. */
    override fun onTimeout(startId: Int, fgsType: Int) { graph.downloadManager.pauseDownloads(); stopSelf() }
}
