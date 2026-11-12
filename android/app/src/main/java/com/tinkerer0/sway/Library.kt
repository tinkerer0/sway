package com.tinkerer0.sway

import android.util.AtomicFile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class Track(val id: String, val title: String, val artist: String, val duration: Long = 0, val artwork: String = "") {
    init { require(validId(id)) }
    fun json() = JSONObject().put("id", id).put("title", title).put("artist", artist).put("duration", duration).put("artwork", artwork)
    companion object {
        fun validId(id: String) = Regex("[a-zA-Z0-9_-]{11}").matches(id)
        fun parse(o: JSONObject) = Track(o.getString("id"), o.getString("title"), o.getString("artist"), o.optLong("duration"), o.optString("artwork"))
    }
}
/** [offline]: 받아 두기. 켜면 데이터 요금이 없는 연결에서 곡을 기기에 받아 둔다. */
data class Playlist(val id: String = UUID.randomUUID().toString(), val name: String, val ids: List<String> = emptyList(), val offline: Boolean = false)
data class Library(val saved: List<Track> = emptyList(), val playlists: List<Playlist> = emptyList(),
                   val recent: List<Track> = emptyList(), val wifiOnly: Boolean = true, val stats: Map<String, ListenStat> = emptyMap())

/** 쓰기 실패·손상 파일을 빈 보관함으로 덮어쓰지 않는다. 음원 URL은 저장하지 않는다. */
class LibraryStore(file: File) {
    private val atomic = AtomicFile(file)
    private val mutable = MutableStateFlow(Library())
    val state = mutable.asStateFlow()
    var readError: String? = null; private set
    init {
        if (file.exists() || File(file.path + ".bak").exists()) {
            try { mutable.value = decode(atomic.openRead().bufferedReader().use { it.readText() }) }
            catch (_: Exception) { readError = "보관함 파일을 읽지 못했어요. 원본을 보존하고 있어요." }
        }
    }
    @Synchronized fun update(change: (Library) -> Library) {
        check(readError == null) { readError ?: "보관함 오류" }
        val next = change(mutable.value)
        val bytes = encode(next).toByteArray(Charsets.UTF_8)
        val stream = atomic.startWrite()
        try { stream.write(bytes); atomic.finishWrite(stream) }
        catch (e: Exception) { atomic.failWrite(stream); throw e }
        mutable.value = next
    }
    fun save(track: Track) = update { it.copy(saved = if (it.saved.any { s -> s.id == track.id }) it.saved else it.saved + track) }
    fun remove(id: String) = update { it.copy(saved = it.saved.filterNot { t -> t.id == id },
        playlists = it.playlists.map { p -> p.copy(ids = p.ids - id) }) }
    fun recent(track: Track) = update { it.copy(recent = (listOf(track) + it.recent.filterNot { t -> t.id == track.id }).take(30)) }
    fun qualify(track: Track) = update { l -> l.copy(stats = l.stats + (track.id to ListenStat((l.stats[track.id]?.plays ?: 0) + 1, System.currentTimeMillis()))) }
    fun playlist(name: String, id: String? = null) = update { l ->
        require(name.trim().isNotEmpty())
        l.copy(playlists = if (id == null) l.playlists + Playlist(name = name.trim()) else l.playlists.map { if (it.id == id) it.copy(name = name.trim()) else it })
    }
    fun addToPlaylist(id: String, track: Track) = addToPlaylist(id, listOf(track))
    /** 고른 순서대로 한 번에 담는다. 이미 있는 곡은 건너뛴다. */
    fun addToPlaylist(id: String, tracks: List<Track>) = update { l -> l.copy(
        saved = l.saved + tracks.filter { t -> l.saved.none { it.id == t.id } }.distinctBy { it.id },
        playlists = l.playlists.map { p -> if (p.id == id) p.copy(ids = (p.ids + tracks.map { it.id }).distinct()) else p }) }
    fun setOffline(id: String, on: Boolean) = update { l -> l.copy(playlists = l.playlists.map { if (it.id == id) it.copy(offline = on) else it }) }
    fun removeFromPlaylist(id: String, trackId: String) = update { l -> l.copy(playlists = l.playlists.map { if (it.id == id) it.copy(ids = it.ids - trackId) else it }) }
    fun move(id: String, trackId: String, delta: Int) = update { l -> l.copy(playlists = l.playlists.map { p ->
        if (p.id != id) p else { val ids = p.ids.toMutableList(); val at = ids.indexOf(trackId); val to = at + delta
            if (at >= 0 && to in ids.indices) { ids.removeAt(at); ids.add(to, trackId) }; p.copy(ids = ids) }
    }) }
    companion object {
        fun encode(l: Library): String = JSONObject().put("version", 1)
            .put("saved", JSONArray(l.saved.map { it.json() })).put("recent", JSONArray(l.recent.map { it.json() }))
            .put("stats", JSONObject().apply { l.stats.forEach { (id, stat) -> put(id, JSONObject().put("plays", stat.plays).put("last", stat.last)) } })
            .put("wifiOnly", l.wifiOnly).put("playlists", JSONArray(l.playlists.map { JSONObject().put("id", it.id).put("name", it.name).put("ids", JSONArray(it.ids)).put("offline", it.offline) })).toString()
        fun decode(text: String): Library {
            val o = JSONObject(text); require(o.getInt("version") == 1) { "지원하지 않는 보관함 버전" }
            fun tracks(key: String): List<Track> { val a = o.getJSONArray(key); return (0 until a.length()).map { Track.parse(a.getJSONObject(it)) }.distinctBy { it.id } }
            val saved = tracks("saved"); val ids = saved.map { it.id }.toSet(); val p = o.getJSONArray("playlists")
            return Library(saved, (0 until p.length()).map { i -> val row = p.getJSONObject(i); val a = row.getJSONArray("ids")
                Playlist(row.getString("id"), row.getString("name"), (0 until a.length()).map { a.getString(it) }.filter { it in ids }.distinct(), row.optBoolean("offline")) },
                tracks("recent"), o.optBoolean("wifiOnly", true), o.optJSONObject("stats")?.let { stats -> stats.keys().asSequence().associateWith { id -> val row = stats.getJSONObject(id); ListenStat(row.optInt("plays").coerceAtLeast(0), row.optLong("last")) } } ?: emptyMap())
        }
    }
}
