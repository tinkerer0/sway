package com.tinkerer0.sway

import android.graphics.Bitmap
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.core.graphics.drawable.toBitmap
import coil.imageLoader
import coil.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** 표지에서 뽑은 두 색(iOS `ArtworkTint.swift`와 같은 계산). 재생 화면 배경·미니플레이어·재생 중 표시에 쓴다. */
data class ArtworkTint(val backdrop: Color, val highlight: Color) {
    companion object {
        /** 표지가 없거나 무채색에 가까워 뽑을 색이 없을 때. */
        val Neutral = ArtworkTint(Color(0xFF3D3D45), Color.White)
        private const val SIDE = 40
        /**
         * 표지를 화면과 같은 방식(가운데 정사각형)으로 잘라 40×40으로 줄인 뒤,
         * 색상을 18구간으로 나눠 채도가 높은 화소가 가장 많이 몰린 구간의 색을 고른다.
         */
        fun extract(source: Bitmap): ArtworkTint {
            val edge = min(source.width, source.height); if (edge <= 0) return Neutral
            val square = Bitmap.createBitmap(source, (source.width - edge) / 2, (source.height - edge) / 2, edge, edge)
            val small = Bitmap.createScaledBitmap(square, SIDE, SIDE, true)
            val pixels = IntArray(SIDE * SIDE); small.getPixels(pixels, 0, SIDE, 0, 0, SIDE, SIDE)
            val weight = DoubleArray(18); val reds = DoubleArray(18); val greens = DoubleArray(18); val blues = DoubleArray(18)
            for (pixel in pixels) {
                val r = (pixel shr 16 and 255).toDouble(); val g = (pixel shr 8 and 255).toDouble(); val b = (pixel and 255).toDouble()
                val high = max(r, max(g, b)); val chroma = high - min(r, min(g, b))
                if (high < 45 || chroma < 30) continue
                val saturation = chroma / high; val w = saturation * saturation * high / 255
                val bin = (hue(r, g, b, high, chroma) / 20).toInt() % 18
                weight[bin] += w; reds[bin] += r * w; greens[bin] += g * w; blues[bin] += b * w
            }
            val best = weight.indices.maxByOrNull { weight[it] } ?: return Neutral
            if (weight[best] < 3) return Neutral
            val r = reds[best] / weight[best]; val g = greens[best] / weight[best]; val b = blues[best] / weight[best]
            val high = max(r, max(g, b)); val chroma = high - min(r, min(g, b)); if (chroma <= 0) return Neutral
            val angle = hue(r, g, b, high, chroma)
            return ArtworkTint(hsl(angle, min(.62, max(.3, chroma / high * .8)), .3), hsl(angle, .88, .64))
        }
        /** 0 이상 360 미만. */
        private fun hue(r: Double, g: Double, b: Double, high: Double, chroma: Double): Double {
            val sector = if (high == r) ((g - b) / chroma + 6) % 6 else if (high == g) (b - r) / chroma + 2 else (r - g) / chroma + 4
            return sector * 60
        }
        private fun hsl(hue: Double, saturation: Double, lightness: Double): Color {
            val chroma = (1 - abs(2 * lightness - 1)) * saturation; val second = chroma * (1 - abs((hue / 60) % 2 - 1)); val base = lightness - chroma / 2
            val (r, g, b) = when { hue < 60 -> Triple(chroma, second, 0.0); hue < 120 -> Triple(second, chroma, 0.0); hue < 180 -> Triple(0.0, chroma, second)
                hue < 240 -> Triple(0.0, second, chroma); hue < 300 -> Triple(second, 0.0, chroma); else -> Triple(chroma, 0.0, second) }
            return Color((r + base).toFloat(), (g + base).toFloat(), (b + base).toFloat())
        }
    }
}
/** 표지 주소별로 뽑은 색을 기억한다. 표지는 Coil이 이미 받아 둔 것을 다시 읽으므로 데이터를 더 쓰지 않는다. */
private val tints: SnapshotStateMap<String, ArtworkTint> = mutableStateMapOf()
@Composable fun artworkTint(url: String?): ArtworkTint {
    val context = LocalContext.current.applicationContext
    LaunchedEffect(url) {
        if (url.isNullOrBlank() || tints.containsKey(url)) return@LaunchedEffect
        val tint = withContext(Dispatchers.IO) { runCatching {
            val drawable = context.imageLoader.execute(ImageRequest.Builder(context).data(url).size(160).allowHardware(false).build()).drawable ?: return@runCatching null
            ArtworkTint.extract(drawable.toBitmap().let { if (it.config == Bitmap.Config.ARGB_8888) it else it.copy(Bitmap.Config.ARGB_8888, false) })
        }.getOrNull() }
        if (tints.size > 300) tints.clear()
        if (tint != null) tints[url] = tint
    }
    val tint = url?.let { tints[it] } ?: ArtworkTint.Neutral
    // 곡이 바뀌면 색이 천천히 넘어간다.
    val backdrop by animateColorAsState(tint.backdrop, tween(1000), label = "backdrop"); val highlight by animateColorAsState(tint.highlight, tween(1000), label = "highlight")
    return ArtworkTint(backdrop, highlight)
}
