package com.tinkerer0.sway

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LibraryTest {
    private fun isolated(test: (File) -> Unit) {
        val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "library-test-${System.nanoTime()}").apply { mkdirs() }
        try { test(File(folder, "library.json")) } finally { folder.deleteRecursively() }
    }
    @Test fun saveRenameOrderAndRemoveSurviveReload() = isolated { file ->
        val a = Track("YE7VzlLtp-4", "Blender", "Blender")
        val b = Track("aqz-KE-bpKQ", "Bunny", "Blender")
        val store = LibraryStore(file)
        store.save(a); store.save(a); store.save(b)
        store.playlist("첫 목록"); val id = store.state.value.playlists.single().id
        store.addToPlaylist(id, a); store.addToPlaylist(id, a); store.addToPlaylist(id, b)
        store.move(id, b.id, -1); store.playlist("바뀐 이름", id)
        val loaded = LibraryStore(file)
        assertNull(loaded.readError)
        assertEquals(2, loaded.state.value.saved.size)
        assertEquals("바뀐 이름", loaded.state.value.playlists.single().name)
        assertEquals(listOf(b.id, a.id), loaded.state.value.playlists.single().ids)
        loaded.remove(b.id)
        assertEquals(listOf(a.id), LibraryStore(file).state.value.playlists.single().ids)
    }
    @Test fun chosenTracksJoinPlaylistInChosenOrderOnce() = isolated { file ->
        val a = Track("YE7VzlLtp-4", "A", "Blender"); val b = Track("aqz-KE-bpKQ", "B", "Blender"); val c = Track("eRsGyueVLvQ", "C", "Blender")
        val store = LibraryStore(file); store.save(a)
        store.playlist("고른 곡"); val id = store.state.value.playlists.single().id
        store.addToPlaylist(id, listOf(a)); store.addToPlaylist(id, listOf(c, a, b, c))
        val loaded = LibraryStore(file).state.value
        assertEquals(listOf(a.id, c.id, b.id), loaded.playlists.single().ids)
        assertEquals(listOf(a.id, c.id, b.id), loaded.saved.map { it.id })
    }
    @Test fun offlineFlagSurvivesReloadAndOldFilesDefaultOff() = isolated { file ->
        // 0.4.0 이전 파일에는 offline 키가 없다. 꺼진 것으로 읽고, 켜고 끈 값은 다시 읽어도 남는다.
        file.writeText("{\"version\":1,\"saved\":[{\"id\":\"YE7VzlLtp-4\",\"title\":\"a\",\"artist\":\"b\"}],\"recent\":[],\"playlists\":[{\"id\":\"p1\",\"name\":\"old\",\"ids\":[\"YE7VzlLtp-4\"]}]}")
        val store = LibraryStore(file); assertNull(store.readError); assertFalse(store.state.value.playlists.single().offline)
        store.setOffline("p1", true); assertTrue(LibraryStore(file).state.value.playlists.single().offline)
        store.setOffline("p1", false); assertFalse(LibraryStore(file).state.value.playlists.single().offline)
        assertEquals(listOf("YE7VzlLtp-4"), LibraryStore(file).state.value.playlists.single().ids)
    }
    @Test fun corruptedAndFutureLibraryArePreserved() = isolated { file ->
        for (text in listOf("{broken", "{\"version\":99}")) {
            file.writeText(text)
            val store = LibraryStore(file)
            assertNotNull(store.readError)
            assertTrue(runCatching { store.save(Track("YE7VzlLtp-4", "a", "b")) }.isFailure)
            assertEquals(text, file.readText())
        }
    }
    @Test fun atomicBackupRecoversLastGoodLibrary() = isolated { file ->
        val store = LibraryStore(file); store.save(Track("YE7VzlLtp-4", "원본", "Blender"))
        file.copyTo(File(file.path + ".bak")); file.writeText("partial write")
        val restored = LibraryStore(file)
        assertNull(restored.readError); assertEquals("원본", restored.state.value.saved.single().title)
    }
    @Test fun invalidIdsCannotEnterTheLibrary() {
        listOf("../file", "", "https://example.com", "short").forEach { assertTrue(runCatching { Track(it, "x", "y") }.isFailure) }
    }
}
