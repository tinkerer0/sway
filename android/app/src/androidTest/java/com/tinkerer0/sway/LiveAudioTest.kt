@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.content.Intent
import android.net.Uri
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import android.os.Build
import android.util.Log
import androidx.media3.common.Player
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.scheduler.Requirements
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** 실제 요청은 공개 Blender CC 영상만. 네트워크 변경은 격리 에뮬레이터에 한정한다. */
@RunWith(AndroidJUnit4::class)
class LiveAudioTest {
    private val inst=InstrumentationRegistry.getInstrumentation()
    private val context=inst.targetContext
    private val device=UiDevice.getInstance(inst)
    private fun main(block:()->Unit)=inst.runOnMainSync(block)
    private fun waitFor(seconds:Int,condition:()->Boolean){val until=System.currentTimeMillis()+seconds*1000;while(System.currentTimeMillis()<until){if(condition())return;Thread.sleep(250)};assertTrue("${seconds}초 초과",condition())}
    private fun graph():AudioGraph {
        assumeTrue(Build.MODEL.contains("sdk") || Build.FINGERPRINT.contains("generic"))
        context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val graph=(context.applicationContext as SwayApp).graph
        waitFor(20){var ready=false;main{ready=graph.player!=null};ready};return graph
    }
    @Test fun upgradeKeepsLibraryAndDoesNotResumeDownloads() {
        val graph=graph();Thread.sleep(3000)
        assertEquals("이전 재생목록",graph.library.state.value.playlists.first().name)
        assertEquals(listOf("YE7VzlLtp-4","aqz-KE-bpKQ"),graph.library.state.value.playlists.first().ids)
        assertEquals("legacy-bytes",File(context.noBackupFilesDir,"audio/legacy-fixture").readText())
        assertEquals(0,graph.audioRequests.get());assertEquals(0,graph.audioBytes.get())
        assertTrue(context.getSystemService(android.app.job.JobScheduler::class.java).allPendingJobs.none{it.id==103})
        main{assertFalse(graph.player!!.playWhenReady);assertEquals(Player.STATE_IDLE,graph.player!!.playbackState)}
        Log.i("SwayStreamTest","upgrade PASS library+playlist+legacy bytes preserved; idle audio requests=0")
    }
    @Test fun searchStreamAndBackgroundControlsWithoutAudioFiles() {
        val graph=graph()
        val all=graph.catalog.search("Big Buck Bunny Blender",false);val music=graph.catalog.search("아이유 밤편지",true)
        assertTrue(all.tracks.isNotEmpty());assertTrue(music.tracks.isNotEmpty())
        val a=Track("YE7VzlLtp-4","Big Buck Bunny","Blender",596)
        val b=Track("aqz-KE-bpKQ","Big Buck Bunny 4K","Blender",596)
        // 이전 실행의 다시 듣기용 저장본을 지워 네트워크에서 받는 경로를 시험한다.
        graph.audioCache.forget(a.id);graph.audioCache.forget(b.id)
        val before=graph.audioRequests.get();val filesBefore=File(context.noBackupFilesDir,"audio").walkTopDown().filter{it.isFile}.associate{it.name to it.readBytes().toList()}
        main{graph.save(a);graph.save(b)};Thread.sleep(1200);assertEquals(before,graph.audioRequests.get())
        main{graph.play(a,listOf(a,b))}
        waitFor(90){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.isPlaying&&graph.player!!.currentPosition>2000};ok}
        val startBytes=graph.audioBytes.get();assertTrue(startBytes>0)
        device.pressHome();device.sleep()
        // Android 9에는 cmd media_session이 없다. 셸의 media dispatch는 빈 패키지 이름으로 보내 Media3 1.8.0이 앱을 멈춘다(2026-10-31 sway28tmp 관측).
        // 이어폰·블루투스 버튼과 같은 입력 장치 경로인 input keyevent로 보낸다.
        fun media(key:String)=device.executeShellCommand(if(Build.VERSION.SDK_INT>=29)"cmd media_session dispatch $key" else "input keyevent KEYCODE_MEDIA_${key.uppercase()}")
        media("pause")
        waitFor(10){var ok=false;main{ok=!graph.player!!.isPlaying};ok}
        media("play")
        waitFor(10){var ok=false;main{ok=graph.player!!.isPlaying};ok}
        main{graph.player!!.seekTo(500_000)}
        waitFor(45){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.isPlaying&&graph.player!!.currentPosition>501_000};ok}
        main{graph.player!!.seekToNextMediaItem()}
        waitFor(90){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.currentMediaItem?.mediaId==b.id&&graph.player!!.isPlaying&&graph.player!!.currentPosition>2000};ok}
        main{graph.player!!.pause()}
        val after=File(context.noBackupFilesDir,"audio").walkTopDown().filter{it.isFile}.associate{it.name to it.readBytes().toList()}
        assertEquals(filesBefore,after)
        assertTrue(File(context.noBackupFilesDir,"playback.json").exists())
        Log.i("SwayStreamTest","stream PASS searches=${all.tracks.size}/${music.tracks.size} save requests=0 audioBytes=${graph.audioBytes.get()} seek500s+screenOff+OSpausePlay+distinctNext; audio files unchanged")
        device.wakeUp();device.executeShellCommand("wm dismiss-keyguard")
    }
    @Test fun restoreQueueWithoutPrefetch() {
        val graph=graph();Thread.sleep(2500)
        main{assertEquals(2,graph.player!!.mediaItemCount);assertEquals("aqz-KE-bpKQ",graph.player!!.currentMediaItem!!.mediaId);assertFalse(graph.player!!.playWhenReady);assertEquals(Player.STATE_IDLE,graph.player!!.playbackState);assertTrue(graph.player!!.currentPosition>=2000)}
        assertEquals(0,graph.audioRequests.get())
        Log.i("SwayStreamTest","restore PASS two tracks+index+position paused; audio requests=0")
    }
    @Test fun offlineNewStreamFailsWithoutPretendingDownloaded() {
        // 다른 시험이 저장하지 않는 곡(Sintel)으로 저장본 없는 곡의 오프라인 실패를 본다.
        val graph=graph();graph.audioCache.forget("eRsGyueVLvQ");device.executeShellCommand("svc wifi disable");device.executeShellCommand("svc data disable")
        try{
            Thread.sleep(2000);main{graph.play(Track("eRsGyueVLvQ","offline probe","Blender",888))}
            waitFor(70){var failed=false;main{failed=graph.player!!.playerError!=null};failed}
            main{assertFalse(graph.player!!.isPlaying);graph.player!!.stop()}
            Log.i("SwayStreamTest","offline PASS new stream reports error; no local audio fallback")
        }finally{
            device.executeShellCommand("svc wifi enable");device.executeShellCommand("svc data enable")
            val cm=context.getSystemService(android.net.ConnectivityManager::class.java)
            waitFor(45){cm.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)==true}
        }
    }
    @Test fun completeCachedTrackPlaysOfflineWithoutNetwork() {
        // 끝까지 들은 곡과 같은 상태를 CacheWriter로 만든 뒤, 인터넷을 끄고 처음과 끝 부근을 재생한다.
        val graph=graph();graph.audioCache.limitMb=AudioCache.DEFAULT_MB
        val id="YE7VzlLtp-4";val track=Track(id,"Big Buck Bunny","Blender",596)
        graph.audioCache.forget(id)
        CacheWriter(graph.cachedFactory.createDataSource(),DataSpec(Uri.parse("https://sway.invalid/$id")),null,null).cache()
        assertTrue(graph.audioCache.isComplete(id));val stored=graph.audioCache.stored(id)!!;assertTrue(stored.formatId.isNotEmpty()&&stored.length>0)
        device.executeShellCommand("svc wifi disable");device.executeShellCommand("svc data disable")
        try{
            Thread.sleep(2000);val bytes=graph.audioBytes.get();val requests=graph.audioRequests.get()
            main{graph.play(track)}
            waitFor(30){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.isPlaying&&graph.player!!.currentPosition>3000};ok}
            main{graph.player!!.seekTo(585_000)}
            waitFor(30){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.playbackState==Player.STATE_ENDED||graph.player!!.currentPosition>590_000};ok}
            assertEquals(bytes,graph.audioBytes.get());assertEquals(requests,graph.audioRequests.get())
            main{graph.player!!.pause()}
            Log.i("SwayStreamTest","cached offline PASS format=${stored.formatId} length=${stored.length} cacheBytes=${graph.audioCache.bytes()} network bytes/requests unchanged=$bytes/$requests start+seek585s")
        }finally{
            device.executeShellCommand("svc wifi enable");device.executeShellCommand("svc data enable")
            val cm=context.getSystemService(android.net.ConnectivityManager::class.java)
            waitFor(45){cm.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)==true}
        }
    }
    @Test fun staleCachedFormatIsDroppedAndRefetchedOnce() {
        // 실제 앞부분 200 KB를 저장한 뒤 형식 기록을 없는 형식(999)으로 바꾼다. 이어 받기에서 낡은 저장본으로 판정해 버리고 다시 받아야 한다.
        val graph=graph();graph.audioCache.limitMb=AudioCache.DEFAULT_MB
        val id="aqz-KE-bpKQ";val track=Track(id,"Big Buck Bunny 4K","Blender",596);graph.audioCache.forget(id)
        CacheWriter(graph.cachedFactory.createDataSource(),DataSpec.Builder().setUri(Uri.parse("https://sway.invalid/$id")).setLength(200_000).build(),null,null).cache()
        graph.audioCache.cache.applyContentMetadataMutations(id,androidx.media3.datasource.cache.ContentMetadataMutations().set("sway-format","999"))
        assertEquals("999",graph.audioCache.stored(id)!!.formatId);assertFalse(graph.audioCache.isComplete(id))
        main{graph.play(track)}
        waitFor(60){var ok=false;main{ok=graph.player!!.playerError==null&&graph.player!!.isPlaying&&graph.player!!.currentPosition>15_000};ok}
        val now=graph.audioCache.stored(id)!!;assertNotEquals("999",now.formatId)
        main{graph.player!!.pause()}
        Log.i("SwayStreamTest","stale PASS cached format 999 dropped, refetched format=${now.formatId} position>15s")
    }
    @Test fun noSaveModeWritesNothingAndDropsPreviousTrack() {
        val graph=graph();val a=Track("YE7VzlLtp-4","Big Buck Bunny","Blender",596);val b=Track("aqz-KE-bpKQ","Big Buck Bunny 4K","Blender",596)
        graph.audioCache.limitMb=AudioCache.DEFAULT_MB;graph.audioCache.forget(a.id);graph.audioCache.forget(b.id)
        CacheWriter(graph.cachedFactory.createDataSource(),DataSpec.Builder().setUri(Uri.parse("https://sway.invalid/${b.id}")).setLength(100_000).build(),null,null).cache()
        assertTrue(graph.audioCache.cache.getCachedSpans(b.id).isNotEmpty())
        graph.audioCache.limitMb=0
        try {
            main{graph.play(b,listOf(b,a))}
            waitFor(60){var ok=false;main{ok=graph.player!!.isPlaying&&graph.player!!.currentPosition>2000};ok}
            main{graph.player!!.seekToNextMediaItem()}
            waitFor(60){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.currentMediaItem?.mediaId==a.id&&graph.player!!.isPlaying&&graph.player!!.currentPosition>3000};ok}
            waitFor(10){graph.audioCache.cache.getCachedSpans(b.id).isEmpty()}
            // 저장 안 함 경로는 저장소에 바이트도 형식 기록도 남기지 않는다.
            assertFalse(a.id in graph.audioCache.cache.keys)
            main{graph.player!!.pause()}
            Log.i("SwayStreamTest","nosave PASS previous track dropped on transition, current track not written")
        } finally { graph.audioCache.limitMb=AudioCache.DEFAULT_MB }
    }
    private val cm get()=context.getSystemService(ConnectivityManager::class.java)
    private fun validated()=cm.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)==true
    /** 모바일 데이터만 켠 상태에서 [id] 한 곡짜리 받아 두기 재생목록을 만들고 [body]를 돌린다. 끝에 재생목록과 받은 곡을 지워
     *  다른 시험이 같은 곡으로 다시 듣기용 경로를 그대로 쓰게 한다. */
    private fun offlineCase(id:String,name:String,body:(AudioGraph,()->Int?)->Unit) {
        val graph=graph();val track=Track(id,name,"Blender",596)
        fun state():Int?{var s:Int?=null;main{s=graph.offline.downloads.value[id]?.state};return s}
        fun cleanup(){
            main{graph.edit{graph.library.update{l->l.copy(playlists=l.playlists.filterNot{it.name==name})}};graph.syncOffline()}
            waitFor(30){state()==null};assertTrue(graph.offline.cache.getCachedSpans(id).isEmpty())
        }
        main{graph.downloadManager};waitFor(15){var ok=false;main{ok=graph.downloadManager.isInitialized};ok}
        cleanup();graph.audioCache.forget(id)
        device.executeShellCommand("svc wifi disable");device.executeShellCommand("svc data enable")
        try{
            waitFor(60){validated()&&cm.isActiveNetworkMetered}
            main{graph.save(track);graph.edit{graph.library.playlist(name)};val pid=graph.library.state.value.playlists.first{it.name==name}.id
                graph.edit{graph.library.addToPlaylist(pid,track)};graph.setOffline(pid,true);graph.syncOffline()}
            waitFor(15){state()==Download.STATE_QUEUED}
            body(graph,::state)
        }finally{
            device.executeShellCommand("svc wifi enable");device.executeShellCommand("svc data enable")
            waitFor(45){validated()}
            main{graph.player?.stop()}
            context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            cleanup()
        }
    }
    @Test fun offlinePlaylistWaitsForWifiThenPlaysWithoutNetwork() = offlineCase("aqz-KE-bpKQ","받아 두기 시험") { graph, state ->
        // 받아 두기는 모바일 데이터(요금 연결)에서는 주소 조회도 받기도 하지 않고 기다리다가 Wi-Fi가 생기면 받는다.
        // 다 받은 곡은 인터넷 없이 받아 둔 저장소에서만 읽는다.
        val id="aqz-KE-bpKQ";val track=Track(id,"Big Buck Bunny 4K","Blender",596)
        val before=graph.offline.downloadBytes.get();val beforeRequests=graph.offline.downloadRequests.get()
        Thread.sleep(10_000)
        var notMet=0;main{notMet=graph.offline.notMet.value}
        assertEquals(Download.STATE_QUEUED,state());assertTrue("요금 연결 대기 플래그",notMet and Requirements.NETWORK_UNMETERED!=0)
        assertEquals(before,graph.offline.downloadBytes.get());assertEquals(beforeRequests,graph.offline.downloadRequests.get())
        // 받아 두지 않은 곡을 요금 연결에서 재생하면 연결마다 한 번 알린다.
        graph.messages.value=null;graph.noticeMetered("YE7VzlLtp-4");waitFor(8){graph.messages.value?.contains("모바일 데이터")==true}
        graph.messages.value=null;graph.noticeMetered("YE7VzlLtp-4");Thread.sleep(3000);assertNull(graph.messages.value)
        device.executeShellCommand("svc wifi enable")
        waitFor(240){state()==Download.STATE_COMPLETED}
        val got=graph.offline.downloadBytes.get()-before;val stored=graph.offline.stored(id)!!
        assertTrue(graph.offline.playable(id));assertTrue(id in graph.offline.cache.keys);assertTrue(stored.formatId.isNotEmpty()&&stored.length>0);assertTrue("받은 바이트 $got",got>=stored.length)
        device.executeShellCommand("svc wifi disable");device.executeShellCommand("svc data disable");Thread.sleep(2000)
        val bytes=graph.audioBytes.get();val requests=graph.audioRequests.get()
        main{graph.play(track)}
        waitFor(30){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.isPlaying&&graph.player!!.currentPosition>3000};ok}
        main{graph.player!!.seekTo(585_000)}
        waitFor(30){var ok=false;main{assertNull(graph.player!!.playerError);ok=graph.player!!.playbackState==Player.STATE_ENDED||graph.player!!.currentPosition>590_000};ok}
        assertEquals(bytes,graph.audioBytes.get());assertEquals(requests,graph.audioRequests.get())
        // 받아 둔 곡은 다시 듣기용 저장을 거치지 않는다.
        assertTrue(graph.audioCache.cache.getCachedSpans(id).isEmpty())
        main{graph.player!!.pause()}
        // 새 요금 연결에서도 받아 둔 곡은 알리지 않는다.
        device.executeShellCommand("svc data enable");waitFor(60){validated()&&cm.isActiveNetworkMetered}
        graph.messages.value=null;graph.noticeMetered(id);Thread.sleep(3000);assertNull(graph.messages.value)
        Log.i("SwayStreamTest","offline playlist PASS metered queued notMet=$notMet bytes+0 requests+0; wifi completed format=${stored.formatId} length=${stored.length} downloaded=$got; no-network play start+seek585s audio bytes/requests unchanged=$bytes/$requests; replay cache untouched; metered notice once, none for downloaded")
    }
    @Test fun offlineResumesOnWifiAfterLeavingApp() = offlineCase("YE7VzlLtp-4","받아 두기 홈 시험") { graph, state ->
        // 모바일 데이터에서 켜고 홈으로 나간 뒤 Wi-Fi가 생기면 앱 화면 없이 받기를 마친다. 서비스는 화면에서 포그라운드로 시작해 둔다.
        // Android 9~11은 기다리는 동안 서비스를 멈추고 데이터 요금이 없는 연결 조건의 예약(job 104)을 건다.
        device.pressHome();Thread.sleep(3000)
        var visible=true;main{visible=graph.visible};assertFalse(visible)
        val jobs=context.getSystemService(android.app.job.JobScheduler::class.java)
        fun scheduled()=jobs.allPendingJobs.any{it.id==OfflineStore.JOB_ID&&it.requiredNetwork?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)==true}
        if(Build.VERSION.SDK_INT<31) waitFor(20){scheduled()} else assertFalse(scheduled())
        device.executeShellCommand("svc wifi enable")
        waitFor(240){state()==Download.STATE_COMPLETED}
        assertTrue(graph.offline.playable("YE7VzlLtp-4"))
        Log.i("SwayStreamTest","offline background PASS sdk=${Build.VERSION.SDK_INT} job104=${Build.VERSION.SDK_INT<31} completed after HOME + wifi, process alive")
    }
    @Test fun liveMixAndDiscoveryCandidates() {
        val graph=graph();val seed=graph.catalog.search("아이유 밤편지",true).tracks.first()
        val mix=graph.catalog.mix(seed.id);assertTrue(mix.isNotEmpty());assertTrue(mix.none{it.id==seed.id})
        val candidates=DiscoveryPolicy.candidates(mix,Library(recent=listOf(seed)))
        assertTrue(candidates.isNotEmpty());assertTrue(candidates.size<=6)
        Log.i("SwayStreamTest","mix+discovery PASS candidates=${mix.size}/${candidates.size}")
    }
    @Test fun liveMixFromMusicVideoFallsBackToOfficialAudio() {
        // 실측 사례: 강남스타일 M/V의 자동 믹스는 정식 음원이 거의 없다. 메타데이터만 받고 음원은 받지 않는다.
        val graph=graph();val before=graph.audioRequests.get()
        val mix=graph.catalog.mix("9bZkp7q19f0")
        assertTrue(mix.isNotEmpty());assertTrue(mix.none{it.id=="9bZkp7q19f0"});assertEquals(mix.size,mix.distinctBy{it.id}.size)
        assertTrue(mix.none{Catalog.ALTERNATE.containsMatchIn(it.title)});assertEquals(before,graph.audioRequests.get())
        Log.i("SwayStreamTest","mv mix PASS tracks=${mix.size} first=${mix.take(3).map{it.title}}")
    }
}
