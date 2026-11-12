package com.tinkerer0.sway

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.ln

 data class ListenStat(val plays: Int, val last: Long)
class ListeningProgress {
    private var previous: Long? = null
    private var heard = 0L
    private var qualified = false
    fun seek(position: Long) { previous = position }
    fun observe(position: Long, playing: Boolean, duration: Long): Boolean {
        val prior = previous; previous = position
        if (!playing || qualified || prior == null) return false
        val delta = position - prior
        if (delta in 1..2000) heard += delta
        val threshold = if (duration > 0) (duration / 2).coerceIn(10000, 30000) else 30000
        if (heard < threshold) return false
        qualified = true; return true
    }
}
object DiscoveryPolicy {
    fun seeds(l: Library, now: Long = System.currentTimeMillis()): List<Track> = (l.recent + l.saved).distinctBy { it.id }
        .filter { it.duration in 30..900 && (it.id in l.stats || l.recent.any { r -> r.id == it.id }) }
        .sortedByDescending { t -> l.stats[t.id]?.let { (1 + ln(1.0 + it.plays)) / (1 + (now - it.last).coerceAtLeast(0).toDouble() / 86400000 / 14) }
            ?: (1.0 / (1 + l.recent.indexOfFirst { it.id == t.id }.coerceAtLeast(0))) }.take(3)
    private fun titleKey(title: String) = title.lowercase().replace(Regex("(?i)\\[(?:official\\s*)?(?:mv|m/v|audio|video|lyrics?)\\]|\\((?:official\\s*)?(?:audio|video|lyrics?)\\)"), "").filter { it.isLetterOrDigit() }
    private fun keys(title: String): Set<String> = buildSet {
        add(titleKey(title)); val prefix = title.substringBefore('(').substringBefore('（'); if (prefix != title && titleKey(prefix).length >= 3) add(titleKey(prefix))
        Regex("[（(]([^）)]+)[）)]").findAll(title).forEach { val v = it.groupValues[1]; if (!Regex("(?i)feat|ft\\.|official|audio|version|remaster|^\\d+$").containsMatchIn(v) && titleKey(v).length >= 3) add(titleKey(v)) }
    }
    fun candidates(pool: List<Track>, l: Library, excluding: Set<String> = emptySet(), limit: Int = 6): List<Track> {
        val known = l.saved + l.recent
        val ids = (known.map { it.id } + l.stats.keys + excluding).toMutableSet()
        val titles = known.flatMap { keys(it.title) }.toMutableSet(); val artists = mutableMapOf<String, Int>()
        val unwanted = Regex("(?i)\\b(live|cover|remix|karaoke|instrumental|slowed|sped up|performance|m/?v)\\b|라이브|커버|리믹스|노래방|직캠|뮤직비디오")
        return pool.filter { t ->
            val key = keys(t.title); val artist = t.artist.lowercase()
            if (t.id in ids || t.duration !in 30..900 || titleKey(t.title).isEmpty() || key.any { it in titles } || unwanted.containsMatchIn(t.title) || artists.getOrDefault(artist, 0) >= 2) false
            else { ids += t.id; titles += key; artists[artist] = artists.getOrDefault(artist, 0) + 1; true }
        }.take(limit)
    }
}
class DiscoveryStore(private val file: File, private val catalog: Catalog) {
    val pool = MutableStateFlow<List<Track>>(emptyList())
    val loading = MutableStateFlow(false)
    val message = MutableStateFlow<String?>(null)
    private var date = 0L
    private var attempted = 0L
    private var generation = 0
    private val shown = mutableSetOf<String>()
    init { runCatching { val o = JSONObject(file.readText()); val a = o.getJSONArray("pool"); pool.value = (0 until a.length()).map { Track.parse(a.getJSONObject(it)) }; date = o.getLong("date") } }
    suspend fun load(library: Library, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (loading.value || DiscoveryPolicy.seeds(library).isEmpty()) return
        if (!force && ((now - date < 86400000 && DiscoveryPolicy.candidates(pool.value, library).isNotEmpty()) || now - attempted < 300000)) return
        val token = ++generation; val previous = DiscoveryPolicy.candidates(pool.value, library).map { it.id }.toSet()
        loading.value = true; attempted = now; message.value = null
        try {
            val results = withContext(Dispatchers.IO) {
                val buckets = DiscoveryPolicy.seeds(library).map { seed -> ensureActive(); runCatching { catalog.mix(seed.id) }.getOrDefault(emptyList()) }
                buildList { for (i in 0 until (buckets.maxOfOrNull { it.size } ?: 0)) for (bucket in buckets) bucket.getOrNull(i)?.let(::add) }
            }
            currentCoroutineContext().ensureActive()
            if (token != generation) return
            val fresh = DiscoveryPolicy.candidates(results, library, shown + if (force) previous else emptySet(), 24)
            if (fresh.isEmpty()) { message.value = "새로운 음악을 찾지 못했어요. 나중에 다시 찾아보세요."; return }
            pool.value = fresh; date = now; shown += previous; if (shown.size > 120) { shown.clear(); shown += previous }
            withContext(Dispatchers.IO) { runCatching { val f = android.util.AtomicFile(file); val s = f.startWrite(); try { s.write(JSONObject().put("date", date).put("pool", JSONArray(fresh.map { it.json() })).toString().toByteArray()); f.finishWrite(s) } catch(e: Exception) { f.failWrite(s); throw e } } }
        } catch (e: CancellationException) { attempted = 0; throw e }
        catch (_: Exception) { if (token == generation) message.value = "추천을 불러오지 못했어요. 연결을 확인해 주세요." }
        finally { if (token == generation) loading.value = false }
    }
}
