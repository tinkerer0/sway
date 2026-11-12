package com.tinkerer0.sway

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 화면은 블랙 하나다(iOS 판과 같다). 검정 바탕에 카드·테두리·그림자 없이 여백과 글자 굵기로 나누고,
 * 색은 재생 중인 곡의 표지에서만 가져온다([ArtworkTint]). 예전 테마·색상·화면 모드 설정값은 읽지 않는다.
 */
data class SwayPalette(val accent: Color = Color.White, val backdrop: Color = Color(0xFF0A0A0A), val surface: Color = Color(0xFF18181B))
val LocalPalette = staticCompositionLocalOf { SwayPalette() }
/** 재생 중인 곡과 그 표지에서 뽑은 선명한 색. 목록에서 재생 중인 곡을 표시하는 데 쓴다. */
data class NowPlaying(val id: String? = null, val highlight: Color = Color.White)
val LocalNowPlaying = compositionLocalOf { NowPlaying() }
const val CARD_RADIUS = 12
const val CONTROL_RADIUS = 10
const val ARTWORK_RADIUS = 8

@Composable fun SwayDesign(content: @Composable () -> Unit) {
    val p = SwayPalette()
    val colors = darkColorScheme(primary = p.accent, onPrimary = Color(0xFF0A0A0A), background = p.backdrop, surface = p.surface, surfaceContainerHigh = p.surface,
        secondaryContainer = Color.White.copy(alpha = .12f), onSurface = Color.White, onSurfaceVariant = Color(0xFF9B9BA1), outlineVariant = Color.White.copy(alpha = .12f))
    val base = Typography(); val typography = Typography(
        headlineLarge = base.headlineLarge.copy(fontWeight = FontWeight.ExtraBold, fontSize = 30.sp),
        headlineSmall = base.headlineSmall.copy(fontWeight = FontWeight.ExtraBold, fontSize = 22.sp, letterSpacing = (-0.4).sp),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.4).sp), titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold))
    CompositionLocalProvider(LocalPalette provides p, LocalContentColor provides colors.onSurface) { MaterialTheme(colorScheme = colors, typography = typography, content = content) }
}
@Composable fun Backdrop(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) { Box(modifier.background(LocalPalette.current.backdrop), content = content) }
/** 떠 있는 조작부(검색창·버튼)는 흰색 10% 면, 묶음(설정 목록 등)은 어두운 면을 쓴다. */
@Composable fun Modifier.swaySurface(control: Boolean = false, selected: Boolean = false): Modifier {
    val shape = RoundedCornerShape((if (control) CONTROL_RADIUS else CARD_RADIUS).dp)
    return clip(shape).background(if (selected) Color.White.copy(alpha = .18f) else if (control) Color.White.copy(alpha = .10f) else LocalPalette.current.surface)
}
@Composable fun Illustration(size: Int = 90) { Icon(Icons.Rounded.MusicNote, null, Modifier.size((size * .5f).dp), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
