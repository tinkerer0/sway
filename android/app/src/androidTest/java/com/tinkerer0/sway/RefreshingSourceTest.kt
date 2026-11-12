@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.*
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RefreshingSourceTest {
    @Test fun expiredAddressIsRefreshedOnceWithoutPersistingItsUrl() {
        val upstream = FakeHttp(1)
        val refreshes = mutableListOf<Boolean>()
        val source = RefreshingAudioSource(upstream) { spec, refresh -> refreshes += refresh; spec.withUri(Uri.parse(if (refresh) "https://example.org/fresh" else "https://example.org/expired")) }
        val synthetic = Uri.parse("https://sway.invalid/YE7VzlLtp-4/251")
        assertEquals(17L, source.open(DataSpec(synthetic)))
        assertEquals(listOf(false, true), refreshes)
        assertEquals(synthetic, source.uri)
        assertEquals(2, upstream.opens)
        source.close()
    }
    @Test fun repeatedDenialStopsAfterOneRefresh() {
        val upstream = FakeHttp(9)
        val source = RefreshingAudioSource(upstream) { spec, _ -> spec }
        assertTrue(runCatching { source.open(DataSpec(Uri.parse("https://sway.invalid/YE7VzlLtp-4/251"))) }.exceptionOrNull() is HttpDataSource.InvalidResponseCodeException)
        assertEquals(2, upstream.opens)
        source.close()
    }
    @Test fun downloadRequestsAreSplitIntoChunksAndReassembled() {
        // 받기 요청은 조각으로 나뉘어야 한다(YouTube가 10 MiB 넘는 요청을 늦춤). 조각 경계·마지막 짧은 조각·정확히 나누어떨어지는 길이,
        // 전체 길이를 알려 주는 응답(Content-Range)과 알려 주지 않는 응답을 본다.
        fun drain(source: DataSource): ByteArray { val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(1_024)
            while (true) { val n = source.read(buffer, 0, buffer.size); if (n == C.RESULT_END_OF_INPUT) break; out.write(buffer, 0, n) }; return out.toByteArray() }
        for (size in listOf(10_000, 9_000, 2_999, 1)) for (header in listOf(false, true)) {
            val data = ByteArray(size) { (it * 31).toByte() }; val upstream = FakeRange(data, header)
            val source = ChunkedSource(upstream, chunk = 3_000)
            assertEquals(if (header) size.toLong() else C.LENGTH_UNSET.toLong(), source.open(DataSpec(Uri.parse("https://sway.invalid/YE7VzlLtp-4"))))
            assertArrayEquals("size $size header $header", data, drain(source)); source.close()
            assertTrue("조각 요청 ${upstream.opens}", upstream.opens.all { it.second in 1..3_000 })
            // 길이를 모르면 짧은 조각이 올 때까지(나누어떨어지면 빈 조각 하나 더), 알면 필요한 만큼만 연다.
            assertEquals(if (header) (size + 2_999) / 3_000 else size / 3_000 + 1, upstream.opens.size)
        }
        val data = ByteArray(7_000) { it.toByte() }; val upstream = FakeRange(data, false)
        val source = ChunkedSource(upstream, chunk = 3_000)
        assertEquals(6_500L, source.open(DataSpec.Builder().setUri("https://sway.invalid/YE7VzlLtp-4").setPosition(500).setLength(6_500).build()))
        assertArrayEquals(data.copyOfRange(500, 7_000), drain(source)); source.close()
        assertEquals(listOf(500L to 3_000L, 3_500L to 3_000L, 6_500L to 500L), upstream.opens)
    }
    /** HTTP 구간 요청처럼 남은 만큼만 돌려준다. [header]면 Content-Range로 전체 길이를 알린다. */
    private class FakeRange(val data: ByteArray, val header: Boolean) : DataSource {
        val opens = mutableListOf<Pair<Long, Long>>(); private var pos = 0; private var left = 0
        override fun addTransferListener(transferListener: TransferListener) {}
        override fun open(dataSpec: DataSpec): Long {
            opens += dataSpec.position to dataSpec.length; pos = dataSpec.position.toInt(); val rest = (data.size - pos).coerceAtLeast(0)
            left = if (dataSpec.length == C.LENGTH_UNSET.toLong()) rest else minOf(rest.toLong(), dataSpec.length).toInt(); return left.toLong()
        }
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int { if (left == 0) return C.RESULT_END_OF_INPUT; val n = minOf(length, left); System.arraycopy(data, pos, buffer, offset, n); pos += n; left -= n; return n }
        override fun getResponseHeaders(): Map<String, List<String>> = if (header) mapOf("content-range" to listOf("bytes $pos-${pos + left - 1}/${data.size}")) else emptyMap()
        override fun getUri(): Uri? = null
        override fun close() {}
    }
    private class FakeHttp(val failures: Int) : DataSource {
        var opens = 0
        override fun open(dataSpec: DataSpec): Long {
            opens++
            if (opens <= failures) throw HttpDataSource.InvalidResponseCodeException(403, "Forbidden", null, emptyMap(), dataSpec, ByteArray(0))
            return 17
        }
        override fun getUri(): Uri = Uri.parse("https://example.org/fresh")
        override fun addTransferListener(listener: TransferListener) {}
        override fun read(buffer: ByteArray, offset: Int, length: Int) = -1
        override fun close() {}
    }
}
