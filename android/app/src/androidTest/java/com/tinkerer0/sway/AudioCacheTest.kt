@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.app.Application
import android.net.Uri
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.SimpleCache
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** 네트워크 없이 다시 듣기용 저장의 정리 규칙만 확인한다. 앱의 캐시 폴더는 쓰지 않는다. */
@RunWith(AndroidJUnit4::class)
class AudioCacheTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun isolated(limit: () -> Long, keep: () -> String?, test: (SimpleCache) -> Unit) {
        val folder = File(context.cacheDir, "audio-cache-test-${System.nanoTime()}")
        val cache = SimpleCache(folder, AudioCacheEvictor(limit, keep), StandaloneDatabaseProvider(context))
        try { test(cache) } finally { cache.release(); SimpleCache.delete(folder, StandaloneDatabaseProvider(context)) }
    }
    private fun write(cache: SimpleCache, key: String, bytes: Int) {
        CacheWriter(CacheDataSource(cache, ByteArrayDataSource(ByteArray(bytes) { it.toByte() })), DataSpec.Builder().setUri(Uri.parse("https://sway.invalid/$key")).setKey(key).build(), null, null).cache()
    }
    private fun read(cache: SimpleCache, key: String) { cache.getCachedSpans(key).forEach { cache.startReadWriteNonBlocking(key, it.position, it.length)?.let { span -> if (!span.isCached) cache.releaseHoleSpan(span) } } }

    @Test fun overLimitDropsLeastRecentlyHeardButKeepsPlaying() {
        val mb = 1024 * 1024; var keep: String? = "playing0001"
        isolated({ 3L * mb }, { keep }) { cache ->
            write(cache, "playing0001", mb); Thread.sleep(5); write(cache, "oldsong0001", mb); Thread.sleep(5); write(cache, "newsong0001", mb)
            Thread.sleep(5); read(cache, "oldsong0001")
            write(cache, "another0001", mb)
            // 재생 중인 곡이 가장 오래됐지만 남고, 그다음 오래된 newsong이 지워진다. 방금 다시 들은 oldsong은 남는다.
            assertEquals(setOf("playing0001", "oldsong0001", "another0001"), cache.keys.filter { cache.getCachedSpans(it).isNotEmpty() }.toSet())
            assertTrue(cache.cacheSpace <= 3L * mb)
            keep = null
        }
    }
    @Test fun mismatchedFormatOrLengthIsStale() {
        // 앱의 다시 듣기용 저장소에 가짜 키로 쓰고 지운다(격리 에뮬레이터 전용).
        val audio=AudioCache.get(context.applicationContext as Application);val id="stalefmt001";audio.forget(id)
        try {
            audio.remember(id,Audio("u","251","audio/webm",160,4096))
            CacheWriter(CacheDataSource(audio.cache,ByteArrayDataSource(ByteArray(4096))),DataSpec.Builder().setUri(Uri.parse("https://sway.invalid/$id")).setKey(id).build(),null,null).cache()
            assertEquals("251",audio.stored(id)!!.formatId);assertEquals(4096L,audio.stored(id)!!.length);assertTrue(audio.isComplete(id))
            audio.remember(id,Audio("u","251","audio/webm",160,4096))
            assertTrue(runCatching{audio.remember(id,Audio("u","140","audio/mp4",130,4096))}.exceptionOrNull() is StaleAudioException)
            assertTrue(runCatching{audio.remember(id,Audio("u","251","audio/webm",160,9999))}.exceptionOrNull() is StaleAudioException)
            assertTrue(stale(java.io.IOException(StaleAudioException("x"))));assertFalse(stale(java.io.IOException("network")))
        } finally { audio.forget(id) }
        assertNull(audio.stored(id))
    }
    @Test fun zeroLimitKeepsOnlyPlayingTrack() {
        isolated({ 0L }, { "playing0001" }) { cache ->
            write(cache, "playing0001", 4096); write(cache, "other000001", 4096)
            assertEquals(4096L, cache.cacheSpace); assertTrue(cache.getCachedSpans("other000001").isEmpty())
        }
    }
}
