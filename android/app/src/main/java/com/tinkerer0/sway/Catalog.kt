package com.tinkerer0.sway

import okhttp3.Cache
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.localization.ContentCountry
import org.schabi.newpipe.extractor.stream.*
import org.schabi.newpipe.extractor.Page
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap

const val AGENT = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/138.0.0.0 Mobile Safari/537.36"
/** player JS(1년 캐시 헤더)를 앱 재실행 사이에 재사용한다. InnerTube 요청은 POST라 저장되지 않는다. */
class NetworkDownloader(cache: File? = null) : Downloader() {
    private val client = OkHttpClient.Builder().apply { cache?.let { cache(Cache(it, 20L * 1024 * 1024)) } }.connectTimeout(20, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).build()
    override fun execute(request: Request): Response {
        val b = okhttp3.Request.Builder().url(request.url()).header("User-Agent", AGENT)
        request.headers().forEach { (name, values) -> b.removeHeader(name); values.forEach { b.addHeader(name, it) } }
        val body = request.dataToSend()?.toRequestBody() ?: if (request.httpMethod() in listOf("POST", "PUT")) ByteArray(0).toRequestBody() else null
        return client.newCall(b.method(request.httpMethod(), body).build()).execute().use {
            if (it.code == 429) throw IOException("요청이 잠시 제한됐어요. 잠시 후 다시 시도해 주세요.")
            Response(it.code, it.message, it.headers.toMultimap(), it.body?.string(), it.request.url.toString())
        }
    }
}
data class SearchPage(val tracks: List<Track>, val next: Page?, val query: String, val music: Boolean)
data class Audio(val url: String, val formatId: String, val mime: String, val bitrate: Int, val length: Long = -1)

class Catalog(httpCache: File? = null) {
    private val service = ServiceList.YouTube
    init { setup(httpCache) }
    private fun track(item: StreamInfoItem): Track? = runCatching {
        val id = service.streamLHFactory.getId(item.url)
        if (item.streamType != StreamType.VIDEO_STREAM) return null
        Track(id, item.name, item.uploaderName ?: "", item.duration, item.thumbnails.firstOrNull()?.url ?: "")
    }.getOrNull()
    fun search(query: String, music: Boolean, after: Page? = null): SearchPage {
        val term = query.trim(); if (term.isEmpty()) return SearchPage(emptyList(), null, term, music)
        // 익명 Music 검색이 0건을 반환한 실제 관측에 따라 iPhone판과 같은 일반 검색 경로를 쓴다.
        val extractor = service.getSearchExtractor(if (music) "$term \"Provided to YouTube by\"" else term, listOf("videos"), "")
        val page = if (after == null) { extractor.fetchPage(); extractor.initialPage } else extractor.getPage(after)
        if (BuildConfig.DEBUG) android.util.Log.i("SwayTest", "catalog music=$music items=${page.items.size} errors=${page.errors.map { it.javaClass.simpleName }} types=${page.items.filterIsInstance<StreamInfoItem>().map { it.streamType }.distinct()}")
        if (page.items.isEmpty() && page.errors.isNotEmpty()) throw IOException("검색 결과를 읽지 못했어요.")
        val items = page.items.filterIsInstance<StreamInfoItem>().filter { !music || musicMatch(it) }
        return SearchPage(items.mapNotNull(::track).distinctBy { it.id }, page.nextPage, term, music)
    }
    private fun musicMatch(item: StreamInfoItem): Boolean {
        val title = item.name.lowercase()
        val description = item.shortDescription.orEmpty().replace(Regex("<[^>]+>"), "").lowercase()
        val topic = item.uploaderName.orEmpty().lowercase().let { it.endsWith(" - topic") || it.endsWith(" - 주제") }
        val distributed = description.contains("provided to youtube by") && (topic || item.isUploaderVerified)
        val officialAudio = item.isUploaderVerified && (title.contains("official audio") || title.contains("공식 음원"))
        return (distributed || officialAudio) && !Regex("\\bm/?v\\b|music video|뮤직비디오").containsMatchIn(title)
    }
    // 구간 탐색 중 주소를 갱신할 때 같은 오디오 포맷을 유지한다.
    @Synchronized fun audio(id: String, requiredFormat: String? = null): Audio {
        require(Track.validId(id))
        val extractor = service.getStreamExtractor("https://www.youtube.com/watch?v=$id")
        extractor.fetchPage()
        if (extractor.streamType != StreamType.VIDEO_STREAM) throw IOException("실시간 방송은 지원하지 않아요.")
        val candidates = extractor.audioStreams.filter { it.isUrl && it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP &&
            (it.audioTrackType == null || it.audioTrackType == AudioTrackType.ORIGINAL) &&
            (it.itagItem?.audioChannels ?: 2) <= 2 && it.itagItem?.isDrc != true }
        val chosen = if (requiredFormat != null) candidates.firstOrNull { it.id == requiredFormat }
            // 원본은 받았는데 이어 받을 형식만 없으면 저장본·기억한 주소가 낡은 것이다. 연결 실패와 구분한다.
            ?: if (candidates.isNotEmpty()) throw StaleAudioException("이어 받을 오디오 형식이 더 이상 없어요.") else null
        else candidates.maxWithOrNull(compareBy<AudioStream> { if (it.format?.mimeType?.contains("webm") == true) 1 else 0 }.thenBy { it.averageBitrate })
        chosen ?: throw IOException("이 곡의 오디오를 가져올 수 없어요.")
        return Audio(chosen.content, chosen.id, chosen.format?.mimeType ?: "audio/mp4", chosen.averageBitrate, chosen.itagItem?.contentLength?.takeIf { it > 0 } ?: -1)
    }
    /** 정식 음원이 거의 없던 시작 곡 → 대신 쓴 같은 곡의 정식 음원판. */
    private val officialSeeds = ConcurrentHashMap<String, String>()
    fun mix(id: String): List<Track> {
        require(Track.validId(id))
        // 앞서 정식 음원판으로 바꾼 시작점이 있으면 그 곡의 자동 믹스를 이어 받는다.
        officialSeeds[id]?.let { official -> return radio(official).first.filter { it.id != id } }
        val (direct, seed) = radio(id)
        if (BuildConfig.DEBUG) android.util.Log.i("SwayTest", "mix id=$id direct=${direct.size} seed=${seed != null}")
        if (direct.size >= 5 || seed == null) return direct
        // 뮤직비디오로 시작하면 자동 믹스도 뮤직비디오 위주라 정식 음원이 거의 남지 않는다.
        // 같은 곡의 정식 음원판을 음악 검색으로 찾아 그 곡의 자동 믹스로 더 받는다. 재생 중인 곡은 바꾸지 않는다.
        val result = direct.toMutableList()
        try {
            val titles = mutableSetOf<String>()
            val found = search(mixSearchTerm(seed), true).tracks.filter { it.id != id && !ALTERNATE.containsMatchIn(it.title) && titles.add(it.title.lowercase()) }
            if (BuildConfig.DEBUG) android.util.Log.i("SwayTest", "mix fallback found=${found.size}")
            found.firstOrNull()?.let { official ->
                val known = result.map { it.id }.toSet() + id
                val more = radio(official.id).first.filter { it.id !in known }
                if (more.isNotEmpty()) officialSeeds[id] = official.id
                if (BuildConfig.DEBUG) android.util.Log.i("SwayTest", "mix fallback term=${mixSearchTerm(seed)} official=${official.id} more=${more.size}")
                result += more
            }
            // 그래도 없으면 검색에서 찾은 다른 정식 음원을 비슷한 곡으로 쓴다. 첫 곡은 재생 중인 곡의 정식 음원판이라 뺀다.
            if (result.isEmpty()) result += found.drop(1).take(25)
        } catch (e: Exception) {
            if (BuildConfig.DEBUG) android.util.Log.i("SwayTest", "mix fallback failed ${e.javaClass.simpleName}: ${e.message}")
            // 더 받기에 실패해도 이미 고른 정식 음원은 쓴다.
            if (result.isEmpty()) throw e
        }
        return result
    }
    /** `RD + id` 자동 믹스에서 정식 음원만 고른다. 목록 맨 앞의 시작 곡 정보도 돌려준다. */
    private fun radio(id: String): Pair<List<Track>, Track?> {
        val extractor = service.getPlaylistExtractor("https://www.youtube.com/watch?v=$id&list=RD$id")
        extractor.fetchPage()
        val items = extractor.initialPage.items.filterIsInstance<StreamInfoItem>().mapNotNull(::track)
        val candidates = items.filter { it.id != id && !ALTERNATE.containsMatchIn(it.title) }.distinctBy { it.id }.take(20)
        val pool = Executors.newFixedThreadPool(4)
        try {
            return pool.invokeAll(candidates.map { candidate -> Callable {
                runCatching {
                    val details = service.getStreamExtractor("https://www.youtube.com/watch?v=${candidate.id}"); details.fetchPage()
                    val topic = details.uploaderName.lowercase().let { it.endsWith(" - topic") || it.endsWith(" - 주제") }
                    val supplied = details.description.content.contains("Provided to YouTube by", true)
                    if (details.category == "Music" && supplied && (topic || details.isUploaderVerified) && !ALTERNATE.containsMatchIn(details.name))
                        candidate.copy(title = details.name, artist = details.uploaderName) else null
                }.getOrNull()
            } }, 45, TimeUnit.SECONDS).mapNotNull { if (it.isCancelled) null else runCatching { it.get() }.getOrNull() } to items.find { it.id == id }
        } finally { pool.shutdownNow() }
    }
    companion object {
        private var ready = false
        /** NewPipe 설정과 HTTP 캐시는 프로세스에 하나만 둔다(같은 폴더에 OkHttp Cache를 둘 열지 않는다). 처음 만든 Catalog의 httpCache만 쓰인다. */
        @Synchronized private fun setup(httpCache: File?) {
            if (ready) return
            NewPipe.init(NetworkDownloader(httpCache), Localization("ko", "KR"), ContentCountry("KR")); ready = true
        }
        val ALTERNATE = Regex("(?i)\\b(live|cover|remix|karaoke|instrumental|slowed|sped up|performance|m/?v)\\b|라이브|커버|리믹스|노래방|직캠|스케치북|뮤직비디오")
        private const val VIDEO = "m/?v|music\\s+video|official|video|lyrics?|audio|visualizer|4k|hd|뮤직비디오"
        /** 시작 곡의 정식 음원판을 찾는 검색어. 제목의 뮤직비디오·영상 표기를 지운다.
         *  채널은 소속사인 경우가 많아(HYBE LABELS) Topic 채널일 때만 아티스트 이름을 붙인다. */
        fun mixSearchTerm(track: Track): String {
            var term = track.title
                .replace(Regex("(?i)[(\\[【][^)\\]】]*\\b($VIDEO)\\b[^)\\]】]*[)\\]】]"), " ")
                .replace(Regex("(?i)\\b(official\\s+)?(m/?v|music\\s+video|lyric\\s+video|video|audio)\\b|\\b(4k|hd)\\b|뮤직비디오"), " ")
            listOf(" - Topic", " - 주제").firstOrNull { track.artist.endsWith(it) }?.let { term += " " + track.artist.dropLast(it.length) }
            return term.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        }
    }
}
