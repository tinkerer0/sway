package com.tinkerer0.sway

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import androidx.compose.ui.graphics.luminance
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StreamingPolicyTest {
    private val a=Track("YE7VzlLtp-4","Through the Night (밤편지)","IU",254)
    private val b=Track("aqz-KE-bpKQ","Other song","Other",240)
    @Test fun listeningCountsRealProgressOnceNotSeekOrPause() {
        val p=ListeningProgress();p.observe(0,true,240000)
        p.seek(100000);assertFalse(p.observe(101000,true,240000));p.observe(200000,false,240000)
        repeat(28){assertFalse(p.observe(201000+it*1000L,true,240000))}
        assertTrue(p.observe(229000,true,240000));assertFalse(p.observe(230000,true,240000))
    }
    @Test fun discoveryExcludesKnownTitlesIdsAndCapsArtists() {
        val pool=listOf(a,a.copy(id="abcdefghijk",title="밤편지"),b,b.copy(id="abcdefghijl",title="Second"),b.copy(id="abcdefghijm",title="Third"),b.copy(id="abcdefghijn",title="Live performance"))
        val fresh=DiscoveryPolicy.candidates(pool,Library(saved=listOf(a)))
        assertEquals(listOf(b.id,"abcdefghijl"),fresh.map{it.id})
        assertTrue(DiscoveryPolicy.candidates(pool,Library(saved=listOf(a)),setOf(b.id,"abcdefghijl","abcdefghijm")).isEmpty())
    }
    @Test fun sessionRoundtripAndLegacyLibraryCompatible() {
        val snapshot=PlaybackSnapshot(listOf(a,b),1,12345,0,false,a)
        assertEquals(snapshot,PlaybackSnapshot.parse(snapshot.json()))
        assertTrue(runCatching{PlaybackSnapshot.parse(snapshot.json().replace("\"index\":1","\"index\":99"))}.isFailure)
        val old="""{"version":1,"saved":[${a.json()}],"recent":[],"playlists":[],"wifiOnly":true}"""
        val l=LibraryStore.decode(old);assertEquals(listOf(a),l.saved);assertTrue(l.stats.isEmpty())
        val counted=l.copy(stats=mapOf(a.id to ListenStat(3,100)))
        assertEquals(counted,LibraryStore.decode(LibraryStore.encode(counted)))
    }
    @Test fun mixSearchTermDropsVideoMarksAndAddsTopicArtist() {
        // iOS CoreTests.testMixSearchTermDropsVideoMarksAndAddsTopicArtist와 같은 사례.
        listOf(Triple("PSY - GANGNAM STYLE(강남스타일) M/V","officialpsy","PSY - GANGNAM STYLE(강남스타일)"),
            Triple("BTS (방탄소년단) 'Dynamite' Official MV","HYBE LABELS","BTS (방탄소년단) 'Dynamite'"),
            Triple("Lady Gaga - Poker Face (Official Music Video)","Lady Gaga","Lady Gaga - Poker Face"),
            Triple("Song [Official Lyric Video] 4K","Label","Song"),
            Triple("Through the Night (밤편지)","IU - Topic","Through the Night (밤편지) IU"),
            Triple("Ending Scene (이런 엔딩)","아이유 - 주제","Ending Scene (이런 엔딩) 아이유"))
            .forEach{(title,artist,expected)->assertEquals(title,expected,Catalog.mixSearchTerm(Track(a.id,title,artist)))}
    }
    @Test fun blackPaletteHasTextContrast() {
        val p=SwayPalette();for(surface in listOf(p.backdrop,p.surface)){val x=p.accent.luminance();val y=surface.luminance();assertTrue((maxOf(x,y)+.05f)/(minOf(x,y)+.05f)>=4.5f)}
    }
    @Test fun artworkTintPicksDominantHueAndFallsBackToNeutral() {
        fun solid(color:Int)=android.graphics.Bitmap.createBitmap(64,48,android.graphics.Bitmap.Config.ARGB_8888).apply{eraseColor(color)}
        val red=ArtworkTint.extract(solid(0xFFD02020.toInt()))
        assertTrue(red.backdrop.red>red.backdrop.green*2 && red.backdrop.red>red.backdrop.blue*2);assertTrue(red.highlight.red>.9f)
        // 검정 바탕에서 읽히는 밝기여야 한다.
        assertTrue((red.highlight.luminance()+.05f)/(SwayPalette().backdrop.luminance()+.05f)>=4.5f)
        assertEquals(ArtworkTint.Neutral,ArtworkTint.extract(solid(0xFF808080.toInt())));assertEquals(ArtworkTint.Neutral,ArtworkTint.extract(solid(0xFF000000.toInt())))
    }
}
