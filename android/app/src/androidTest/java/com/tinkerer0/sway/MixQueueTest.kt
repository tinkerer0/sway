@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway
import android.app.Application
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class MixQueueTest {
    private val inst=InstrumentationRegistry.getInstrumentation()
    private fun main(action:()->Unit)=inst.runOnMainSync(action)
    private fun await(condition:()->Boolean){repeat(100){if(condition())return;Thread.sleep(50)};assertTrue(condition())}
    @Test fun refillKeepsCurrentItemAndAppendsOnlyNewTracks() {
        var calls=0;val a=Track("abcdefghijk","seed","artist",200)
        val graph=AudioGraph(inst.targetContext.applicationContext as Application){calls++;(1..5).map{Track("queue%06d".format((calls-1)*5+it),"candidate $calls/$it","artist",200)}}
        main{graph.player=ExoPlayer.Builder(graph.app).build();graph.player!!.setMediaItem(graph.mediaItem(a));graph.startMix(a)}
        try{
            await{!graph.mixing.value};main{assertEquals(6,graph.player!!.mediaItemCount);assertEquals(a.id,graph.player!!.currentMediaItem!!.mediaId);graph.player!!.seekToDefaultPosition(3);graph.replenishMix()}
            await{!graph.mixing.value};main{assertEquals(11,graph.player!!.mediaItemCount);assertEquals(3,graph.player!!.currentMediaItemIndex);assertEquals(2,calls);assertEquals(a,graph.mixSeed.value);assertEquals(11,(0 until 11).map{graph.player!!.getMediaItemAt(it).mediaId}.distinct().size)}
        }finally{main{graph.stopMix();graph.player!!.release();graph.player=null};graph.scope.cancel()}
    }
    @Test fun stoppedMixDiscardsLateResult() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val a=Track("abcdefghijk","seed","artist",200)
        val graph=AudioGraph(inst.targetContext.applicationContext as Application){entered.countDown();release.await(5,TimeUnit.SECONDS);listOf(Track("abcdefghijl","late","artist",200))}
        main{graph.player=ExoPlayer.Builder(graph.app).build();graph.player!!.setMediaItem(graph.mediaItem(a));graph.startMix(a)}
        try{assertTrue(entered.await(5,TimeUnit.SECONDS));main{graph.stopMix()};release.countDown();Thread.sleep(300);main{assertEquals(1,graph.player!!.mediaItemCount);assertNull(graph.mixSeed.value);assertFalse(graph.mixing.value)}}
        finally{release.countDown();main{graph.player!!.release();graph.player=null};graph.scope.cancel()}
    }
}
