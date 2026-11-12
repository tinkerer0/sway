@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class UiSmokeTest {
    private val inst=InstrumentationRegistry.getInstrumentation();private val context=inst.targetContext;private val device=UiDevice.getInstance(inst)
    private fun launch(){context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK));assertNotNull(device.wait(Until.findObject(By.res("searchField")),15000));assertNotNull(device.wait(Until.findObject(By.res("createPlaylist")),5000));assertFalse(device.hasObject(By.res("tab-search")));assertFalse(device.hasObject(By.res("tab-library")));assertFalse(device.hasObject(By.text("새로 발견하기")))}
    private fun click(selector:BySelector) {
        val end=System.currentTimeMillis()+8000
        while(System.currentTimeMillis()<end) {
            try {
                val node=device.wait(Until.findObject(selector),1000) ?: continue
                val first=node.visibleBounds
                Thread.sleep(180)
                val second=device.findObject(selector)?.visibleBounds ?: continue
                if(first!=second || second.isEmpty)continue
                device.click(second.centerX(),second.centerY());Thread.sleep(350);device.waitForIdle();return
            } catch (_:StaleObjectException) { Thread.sleep(150) }
        }
        fail("안정된 화면 요소를 찾지 못함: $selector")
    }

    private fun shot(name:String){val folder=File(context.cacheDir,"streaming-ui").apply{mkdirs()};assertTrue(device.takeScreenshot(File(folder,"$name.png")))}
    @Test fun searchPlaylistAndSettingsWithoutThemeChoices() {
        require(android.os.Build.MODEL.contains("sdk",ignoreCase=true) || android.os.Build.FINGERPRINT.contains("generic"))
        // 격리 기기에서 이 테스트가 만든 재생목록만 정리해 재실행에도 동일한 시작 상태를 만든다.
        val graph=(context.applicationContext as SwayApp).graph
        inst.runOnMainSync { graph.edit { graph.library.update { l -> l.copy(playlists=l.playlists.filterNot { it.name in listOf("Night Walk","Evening") }) } } }
        launch();click(By.res("searchField"));device.findObject(By.clazz("android.widget.EditText")).text="Big Buck Bunny Blender";device.pressEnter()
        assertTrue(device.wait(Until.hasObject(By.descContains(" 메뉴")),60000));shot("search-results")
        click(By.res("searchScope"));click(By.text("음악"));assertTrue(device.wait(Until.hasObject(By.res("searchField")),5000));assertEquals("Big Buck Bunny Blender",device.findObject(By.clazz("android.widget.EditText")).text)
        click(By.res("cancelSearch"));assertTrue(device.wait(Until.hasObject(By.res("createPlaylist")),5000));assertFalse(device.hasObject(By.res("cancelSearch")))
        click(By.res("createPlaylist"));device.wait(Until.findObject(By.clazz("android.widget.EditText")),5000).text="Night Walk";click(By.text("저장"));click(By.text("Night Walk"));click(By.text("이름 변경"));device.wait(Until.findObject(By.clazz("android.widget.EditText")),5000).text="Evening";click(By.text("저장"));assertTrue(device.wait(Until.hasObject(By.text("Evening")),5000))
        // 화면은 블랙 하나라 테마·색상·화면 모드 설정이 없다.
        click(By.desc("보관함으로"));click(By.res("openSettings"));assertTrue(device.wait(Until.hasObject(By.text("다시 듣기용 저장")),5000));assertFalse(device.hasObject(By.text("Wi-Fi에서만 다운로드")))
        for(gone in listOf("테마","색상","화면 모드"))assertFalse(gone,device.hasObject(By.text(gone)));shot("settings")
        click(By.desc("닫기"));assertTrue(device.wait(Until.hasObject(By.res("libraryHome")),5000))
    }
    @Test fun chooseSavedTracksAddToPlaylistAndPickFromSaved() {
        require(android.os.Build.MODEL.contains("sdk",ignoreCase=true) || android.os.Build.FINGERPRINT.contains("generic"))
        val graph=(context.applicationContext as SwayApp).graph;val name="고른 곡 시험"
        val a=Track("YE7VzlLtp-4","Big Buck Bunny","Blender",596);val b=Track("aqz-KE-bpKQ","Big Buck Bunny 4K","Blender",596);val c=Track("eRsGyueVLvQ","Sintel","Blender",888)
        fun ids()=graph.library.state.value.playlists.first{it.name==name}.ids
        inst.runOnMainSync { graph.edit { graph.library.update { l -> l.copy(playlists=l.playlists.filterNot{it.name==name}) } };listOf(a,b,c).forEach{graph.save(it)};graph.edit{graph.library.playlist(name)} }
        try {
            launch();click(By.text("저장한 곡"));click(By.res("chooseTracks"));assertTrue(device.wait(Until.hasObject(By.text("곡 선택")),5000))
            click(By.res("choice-${c.id}"));click(By.res("choice-${a.id}"));assertTrue(device.wait(Until.hasObject(By.text("2곡 선택")),3000));shot("choose-saved")
            click(By.res("addChosenToPlaylist"));assertTrue(device.wait(Until.hasObject(By.text("2곡을 재생목록에")),5000));shot("choose-add-sheet")
            click(By.text(name));assertEquals(listOf(c.id,a.id),ids())
            assertTrue("담은 뒤 선택 모드가 끝나야 함",device.wait(Until.hasObject(By.res("chooseTracks")),5000))
            click(By.desc("보관함으로"));click(By.text(name));click(By.res("pickSaved"));assertTrue(device.wait(Until.hasObject(By.res("confirmPickedTracks")),5000))
            assertTrue(device.wait(Until.hasObject(By.text("이미 있음")),3000));shot("pick-saved")
            device.findObject(By.res("pickerSearch")).text="4K";assertTrue(device.wait(Until.gone(By.res("choice-${c.id}")),3000))
            click(By.res("choice-${b.id}"));assertTrue(device.wait(Until.hasObject(By.text("1곡 추가")),3000));click(By.res("confirmPickedTracks"))
            assertEquals(listOf(c.id,a.id,b.id),ids())
        } finally {
            inst.runOnMainSync { graph.edit { graph.library.update { l -> l.copy(playlists=l.playlists.filterNot{it.name==name}) } } }
        }
    }
    @Test fun storageSettingsSelectsLimitAndClears() {
        require(android.os.Build.MODEL.contains("sdk",ignoreCase=true) || android.os.Build.FINGERPRINT.contains("generic"))
        val graph=(context.applicationContext as SwayApp).graph;val before=graph.audioCache.limitMb
        fun until(condition:()->Boolean){val end=System.currentTimeMillis()+5000;while(System.currentTimeMillis()<end&&!condition())Thread.sleep(100);assertTrue(condition())}
        try {
            launch();click(By.res("openSettings"));assertTrue(device.wait(Until.hasObject(By.text("재생")),5000));click(By.text("다시 듣기용 저장"))
            assertTrue(device.wait(Until.hasObject(By.text("사용 중")),5000));shot("storage-settings")
            click(By.res("audioCache-500"));until{graph.audioCache.limitMb==500}
            click(By.res("audioCache-0"));until{graph.audioCache.limitMb==0};assertFalse(graph.audioCache.enabled)
            click(By.res("clearAudioCache"));until{graph.audioCache.cache.keys.all{it==graph.audioCache.protectedId||graph.audioCache.cache.getCachedSpans(it).isEmpty()}}
            click(By.res("audioCache-1024"));until{graph.audioCache.limitMb==1024};shot("storage-settings-1gb")
        } finally { graph.audioCache.limitMb=before }
    }
    @Test fun offlineToggleConfirmsOffAndMeteredNoticeSetting() {
        require(android.os.Build.MODEL.contains("sdk",ignoreCase=true) || android.os.Build.FINGERPRINT.contains("generic"))
        // 빈 재생목록으로 화면만 본다(곡을 받지 않는다). 실제 받기는 LiveAudioTest가 본다.
        val graph=(context.applicationContext as SwayApp).graph;val name="받아 두기 화면";val before=graph.meteredNotice
        fun list()=graph.library.state.value.playlists.first{it.name==name}
        fun until(condition:()->Boolean){val end=System.currentTimeMillis()+5000;while(System.currentTimeMillis()<end&&!condition())Thread.sleep(100);assertTrue(condition())}
        inst.runOnMainSync { graph.edit { graph.library.update { l -> l.copy(playlists=l.playlists.filterNot{it.name==name}) } };graph.edit{graph.library.playlist(name)} }
        try {
            launch();click(By.text(name));assertTrue(device.wait(Until.hasObject(By.res("offlineToggle")),5000))
            assertTrue(device.findObject(By.res("offlineStatus")).text.contains("Wi-Fi에서 받아 두면"))
            click(By.res("offlineToggle"));until{list().offline};assertTrue(device.wait(Until.hasObject(By.text("곡을 추가하면 Wi-Fi에서 받아요")),5000));shot("offline-on")
            click(By.res("offlineToggle"));assertTrue(device.wait(Until.hasObject(By.text("받아 둔 곡을 지울까요?")),5000));assertTrue(list().offline);shot("offline-off-confirm")
            click(By.text("취소"));assertTrue(list().offline)
            click(By.res("offlineToggle"));click(By.text("지우기"));until{!list().offline}
            click(By.desc("보관함으로"));click(By.res("openSettings"));assertTrue(device.wait(Until.hasObject(By.text("받아 둔 곡")),5000));assertTrue(device.hasObject(By.text("모바일 데이터 사용 알림")))
            graph.meteredNotice=true;click(By.res("meteredNotice"));until{!graph.meteredNotice};shot("settings-offline");click(By.res("meteredNotice"));until{graph.meteredNotice}
            click(By.desc("닫기"))
        } finally {
            graph.meteredNotice=before
            inst.runOnMainSync { graph.edit { graph.library.update { l -> l.copy(playlists=l.playlists.filterNot{it.name==name}) } } }
        }
    }
    @Test fun unifiedHomePlayerAndLastPlaylistReachable() {
        launch();val graph=(context.applicationContext as SwayApp).graph
        val names=(1..8).map{"확인 목록 $it"}
        try {
            val ready=System.currentTimeMillis()+15000
            while(System.currentTimeMillis()<ready){var ok=false;inst.runOnMainSync{ok=graph.player!=null};if(ok)break;Thread.sleep(200)}
            inst.runOnMainSync {
                check(graph.player!=null)
                val existing=graph.library.state.value.playlists.map{it.name}.toSet()
                names.filter{it !in existing}.forEach{graph.library.playlist(it)}
                graph.player!!.setMediaItem(graph.mediaItem(Track("aqz-KE-bpKQ","offline probe","Blender",596)))
            }
            assertNotNull(device.wait(Until.findObject(By.res("miniPlayer")),8000))
            assertTrue(device.wait(Until.hasObject(By.res("libraryHome")),5000));assertFalse(device.hasObject(By.res("tab-search")));assertTrue(device.hasObject(By.text("저장한 곡")));shot("home")
            click(By.res("searchField"));assertTrue(device.wait(Until.hasObject(By.res("cancelSearch")),3000));assertFalse(device.hasObject(By.res("createPlaylist")));assertFalse(device.hasObject(By.res("miniPlayer")));shot("search")
            click(By.res("cancelSearch"));assertTrue(device.wait(Until.hasObject(By.res("createPlaylist")),3000))
            repeat(6) { if(!device.hasObject(By.text("확인 목록 8"))) { device.findObject(By.scrollable(true))?.scroll(Direction.DOWN,0.8f); device.waitForIdle() } }
            val last=device.wait(Until.findObject(By.text("확인 목록 8")),5000);assertNotNull(last)
            val dock=device.findObject(By.res("miniPlayer")).visibleBounds
            assertTrue("마지막 재생목록이 미니플레이어에 가림",last.visibleBounds.bottom<=dock.top)
            shot("home-last-row")
            device.executeShellCommand("settings put system font_scale 1.5");Thread.sleep(1800);shot("large-font-home")
            device.executeShellCommand("settings put system font_scale 1.0")
            Thread.sleep(1200);click(By.res("miniPlayer"));assertTrue(device.wait(Until.hasObject(By.res("playerTitle")),5000));assertFalse(device.hasObject(By.text("지금 재생 중")))
            for(id in listOf("playerPlayPause","playerNext","playerShuffle","playerRepeat","mixToggle"))assertTrue(id,device.hasObject(By.res(id)))
            // 알고리즘 버튼은 셔플·반복 아래 줄에 따로 있다.
            assertTrue(device.findObject(By.res("mixToggle")).visibleBounds.top>=device.findObject(By.res("playerRepeat")).visibleBounds.bottom)
            shot("player");click(By.desc("대기열"));assertTrue(device.wait(Until.hasObject(By.text("재생 대기열")),5000));shot("queue");click(By.desc("닫기"));click(By.desc("닫기"));click(By.res("openSettings"));assertTrue(device.wait(Until.hasObject(By.text("다시 듣기용 저장")),5000));shot("settings-home")
        } finally {
            device.executeShellCommand("settings put system font_scale 1.0")
            inst.runOnMainSync { graph.edit { graph.library.update { l -> l.copy(playlists=l.playlists.filterNot { it.name in names }) } } }
        }
    }
}
