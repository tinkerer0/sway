@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener

/** 일시적인 403/410은 같은 영상·같은 format의 주소만 새로 받아 1회 재시도한다. */
class RefreshingAudioSource(
    private val upstream: DataSource,
    private val resolve: (DataSpec, Boolean) -> DataSpec
) : DataSource {
    private var reportedUri: Uri? = null
    override fun addTransferListener(listener: TransferListener) = upstream.addTransferListener(listener)
    override fun open(dataSpec: DataSpec): Long {
        reportedUri = dataSpec.uri
        try { return upstream.open(resolve(dataSpec, false)) }
        catch (error: HttpDataSource.InvalidResponseCodeException) {
            if (error.responseCode != 403 && error.responseCode != 410) throw error
            runCatching { upstream.close() }
            return upstream.open(resolve(dataSpec, true))
        }
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int) = upstream.read(buffer, offset, length)
    // CacheDataSource가 만료되는 CDN URL을 redirectedUri 메타데이터에 기록하지 않게 한다.
    override fun getUri(): Uri? = reportedUri
    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders
    override fun close() { try { upstream.close() } finally { reportedUri = null } }
}
