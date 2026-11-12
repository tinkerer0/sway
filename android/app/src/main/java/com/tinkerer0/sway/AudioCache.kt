@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.app.Application
import android.content.Context
import androidx.core.content.edit
import androidx.media3.common.C
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.*
import java.io.File
import java.io.IOException
import java.util.TreeSet

/** 저장된 바이트와 원본이 달라 이어 받을 수 없다. 재생 실패 처리에서 저장본을 버린다. */
class StaleAudioException(message: String) : IOException(message)

/** Media3 저장소들이 같이 쓰는 SQLite 연결. 같은 파일에 helper를 여러 개 열지 않는다. */
object SwayDatabase {
    @Volatile private var provider: StandaloneDatabaseProvider? = null
    fun get(app: Application) = provider ?: synchronized(this) { provider ?: StandaloneDatabaseProvider(app).also { provider = it } }
}

/**
 * 영상 ID를 키로 음원 바이트를 담는 저장소. 저장된 바이트의 형식·음질·길이를 기록해, 이어 받을 때 같은 원본만 쓴다.
 * 다시 듣기용 저장(AudioCache)과 받아 두기(OfflineStore)가 같이 쓴다.
 */
interface FormatStore {
    val cache: Cache
    /** 일부라도 저장된 곡이면 그 바이트의 형식·음질. 형식 기록이 없으면 formatId가 빈 값이다.
     *  저장소를 열거나 읽지 못하면 저장본이 없는 것으로 본다. */
    fun stored(id: String): Audio? = try {
        val c = cache
        if (c.getCachedSpans(id).isEmpty()) null else {
            val meta = c.getContentMetadata(id)
            Audio("", meta.get(FORMAT_KEY, null as String?) ?: "", meta.get(MIME_KEY, null as String?) ?: "", meta.get(BITRATE_KEY, 0L).toInt(), ContentMetadata.getContentLength(meta))
        }
    } catch (e: Exception) { null }
    /** 새로 받은 주소가 저장본과 같은 원본인지 확인하고, 처음 받는 곡이면 형식을 기록한다. 기록하지 못해도 재생은 막지 않는다. */
    fun remember(id: String, audio: Audio) {
        val stored = stored(id)
        if (stored != null) {
            if (stored.formatId != audio.formatId || (stored.length > 0 && audio.length > 0 && stored.length != audio.length))
                throw StaleAudioException("저장된 음원과 원본이 달라요.")
            return
        }
        try { cache.applyContentMetadataMutations(id, ContentMetadataMutations().set(FORMAT_KEY, audio.formatId).set(MIME_KEY, audio.mime).set(BITRATE_KEY, audio.bitrate.toLong())) }
        catch (_: Exception) { }
    }
    fun isComplete(id: String): Boolean {
        val c = cache
        val length = ContentMetadata.getContentLength(c.getContentMetadata(id))
        return length > 0 && c.isCached(id, 0, length)
    }
    /** 저장본을 버린다. 버린 바이트가 있었으면 true. */
    fun forget(id: String): Boolean {
        val c = cache
        val had = c.getCachedSpans(id).isNotEmpty()
        c.removeResource(id)
        return had
    }
    fun bytes(): Long = cache.cacheSpace
}
private const val FORMAT_KEY = "sway-format"
private const val MIME_KEY = "sway-mime"
private const val BITRATE_KEY = "sway-bitrate"

/**
 * 재생하며 받은 음원을 남겨 다시 들을 때 데이터를 쓰지 않게 한다(iOS 판의 '다시 듣기용 저장').
 * 앱 안에서만 쓰는 임시 캐시다. 한도를 넘으면 오래 안 들은 구간부터 지우고 재생 중인 곡은 남긴다.
 * cacheDir라 저장 공간이 부족하면 Android가 비울 수 있다. SimpleCache는 폴더당 하나만 열 수 있어 프로세스에 하나만 둔다.
 * 0.1.0의 다운로드 폴더(noBackupFilesDir/audio)와는 다른 폴더다.
 */
class AudioCache private constructor(private val app: Application) : FormatStore {
    companion object {
        const val DEFAULT_MB = 1024
        val OPTIONS = listOf(0, 500, 1024, 2048)
        fun label(mb: Int) = when (mb) { 0 -> "저장 안 함"; 1024 -> "1 GB"; 2048 -> "2 GB"; else -> "$mb MB" }
        /** 캐시 키는 만료되는 CDN 주소가 아니라 영상 ID다. */
        val KEY = CacheKeyFactory { it.uri.lastPathSegment ?: it.uri.toString() }
        @Volatile private var instance: AudioCache? = null
        fun get(app: Application) = instance ?: synchronized(this) { instance ?: AudioCache(app).also { instance = it } }
    }
    private val prefs = app.getSharedPreferences("audio_cache", Context.MODE_PRIVATE)
    /** 지금 재생 중인 곡. 한도 정리와 전체 지우기에서 남긴다. */
    @Volatile var protectedId: String? = null
    var limitMb: Int
        get() = prefs.getInt("limitMB", DEFAULT_MB).takeIf { it in OPTIONS } ?: DEFAULT_MB
        set(value) { prefs.edit { putInt("limitMB", value) } }
    val enabled get() = limitMb > 0
    private val evictor = AudioCacheEvictor({ limitMb * 1024L * 1024L }, { protectedId })
    /** 처음 쓰는 스레드에서 폴더를 읽는다. 이 클래스의 함수는 화면 스레드에서 부르지 않는다. */
    override val cache: SimpleCache by lazy { SimpleCache(File(app.cacheDir, "audio"), evictor, SwayDatabase.get(app)) }

    /** 한도에 맞춰 정리한다. 한도를 바꾼 뒤 부른다. */
    fun trim() { val c = cache; synchronized(c) { evictor.evict(c, 0) } }
    /** 재생 중인 곡을 빼고 모두 지운다. */
    fun clear() { val c = cache; val keep = protectedId; c.keys.filter { it != keep }.forEach(c::removeResource) }
}

/** 마지막으로 읽은 시각이 오래된 구간부터 지운다. 재생 중인 곡의 구간은 건너뛴다. */
internal class AudioCacheEvictor(private val limit: () -> Long, private val keep: () -> String?) : CacheEvictor {
    private val spans = TreeSet<CacheSpan> { a, b -> if (a.lastTouchTimestamp != b.lastTouchTimestamp) a.lastTouchTimestamp.compareTo(b.lastTouchTimestamp) else a.compareTo(b) }
    private var size = 0L
    override fun requiresCacheSpanTouches() = true
    override fun onCacheInitialized() {}
    override fun onStartFile(cache: Cache, key: String, position: Long, length: Long) { if (length != C.LENGTH_UNSET.toLong()) evict(cache, length) }
    override fun onSpanAdded(cache: Cache, span: CacheSpan) { spans.add(span); size += span.length; evict(cache, 0) }
    override fun onSpanRemoved(cache: Cache, span: CacheSpan) { if (spans.remove(span)) size -= span.length }
    override fun onSpanTouched(cache: Cache, oldSpan: CacheSpan, newSpan: CacheSpan) { onSpanRemoved(cache, oldSpan); onSpanAdded(cache, newSpan) }
    /** SimpleCache 잠금 안에서만 부른다. */
    fun evict(cache: Cache, required: Long) {
        val limit = limit(); val keep = keep()
        while (size + required > limit) {
            val victim = spans.firstOrNull { it.key != keep } ?: return
            cache.removeSpan(victim)
            // removeSpan이 알리지 않은 경우에도 같은 구간을 다시 고르지 않는다.
            if (spans.remove(victim)) size -= victim.length
        }
    }
}
