@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package com.tinkerer0.sway

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.media3.exoplayer.offline.Download
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable fun SettingsScreen(graph:AudioGraph,onClose:()->Unit) {
    var page by remember { mutableStateOf("설정") }
    var legacy by remember { mutableLongStateOf(0) }; var confirm by remember { mutableStateOf(false) }
    var notices by remember { mutableStateOf("") }; val scope=rememberCoroutineScope()
    var limit by remember { mutableIntStateOf(graph.audioCache.limitMb) }; var used by remember { mutableStateOf<Long?>(null) }
    var meteredNotice by remember { mutableStateOf(graph.meteredNotice) }
    val downloads by graph.offline.downloads.collectAsStateWithLifecycle()
    val done=downloads.values.filter { it.state==Download.STATE_COMPLETED }
    fun measure() { scope.launch { used=withContext(Dispatchers.IO){graph.audioCache.bytes()} } }
    LaunchedEffect(page) { if(page=="다시 듣기용 저장")measure() }
    LaunchedEffect(Unit) { legacy=withContext(Dispatchers.IO){graph.legacyBytes()} }
    LaunchedEffect(page) { if(page=="오픈소스 라이선스")notices=withContext(Dispatchers.IO){ graph.app.assets.open("NOTICES.txt").bufferedReader().use{it.readText()} } }
    FullScreen(page,{if(page=="설정")onClose() else page="설정"}) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
            when(page) {
                "설정" -> {
                    SettingsGroup("재생") {
                        Box(Modifier.testTag("storageSettings")) { SettingsRow("다시 듣기용 저장",Icons.Rounded.Storage,AudioCache.label(limit)){page="다시 듣기용 저장"} }
                        SettingsRow("받아 둔 곡",Icons.Rounded.DownloadDone,if(done.isEmpty())"재생목록에서 받아 두기를 켜면 Wi-Fi에서 받아요" else "${done.size}곡 · ${android.text.format.Formatter.formatShortFileSize(graph.app,done.sumOf{it.bytesDownloaded})}",null)
                        Row(Modifier.fillMaxWidth().toggleable(value=meteredNotice,role=Role.Switch){meteredNotice=it;graph.meteredNotice=it}.padding(horizontal=18.dp,vertical=14.dp).testTag("meteredNotice"),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                            Icon(Icons.Rounded.SignalCellularAlt,null,Modifier.size(21.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
                            Column(Modifier.weight(1f)) { Text("모바일 데이터 사용 알림");Text("받아 두지 않은 곡을 모바일 데이터로 재생하면 알려 줘요",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                            Switch(checked=meteredNotice,onCheckedChange=null)
                        }
                    }
                    SettingsGroup("앱 정보") {
                        SettingsRow("Sway 정보",Icons.Rounded.Info){page="Sway 정보"}
                        SettingsRow("오픈소스 라이선스",Icons.Rounded.Description){page="오픈소스 라이선스"}
                        SettingsRow("버전",Icons.Rounded.MusicNote,"${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",null)
                    }
                    if(legacy>0)SettingsGroup("이전 버전의 파일") { Column(Modifier.padding(18.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
                        Text("이전 다운로드  ${legacy/1024/1024} MB",style=MaterialTheme.typography.titleMedium)
                        Text("현재 버전은 스트리밍해요. 이전 음원을 삭제해도 곡 목록과 재생목록은 남아요.",style=MaterialTheme.typography.bodyMedium)
                        TextButton(onClick={confirm=true}){Text("이전 다운로드 삭제")}
                    } }
                }
                "Sway 정보" -> {
                    Column(Modifier.fillMaxWidth().swaySurface().padding(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) { Text("좋아하는 음악을, 가볍게.",style=MaterialTheme.typography.titleMedium);Text("음원은 인터넷으로 스트리밍해요. 재생목록에서 받아 두기를 켜면 Wi-Fi에서 곡을 받아 두고 인터넷 없이 들을 수 있어요.");Text("영상 없이 오디오만 재생하며, 원본에서 제공하는 높은 품질을 사용해요.") }
                    SettingsGroup("보관함") { Text("앱을 삭제하면 저장한 곡 목록도 사라져요. 업데이트할 때는 기존 앱을 지우지 않고 설치하세요.",Modifier.padding(20.dp)) }
                }
                "다시 듣기용 저장" -> {
                    SettingsGroup(null) { AudioCache.OPTIONS.forEach { mb -> Row(Modifier.fillMaxWidth().clickable{limit=mb;scope.launch{withContext(Dispatchers.IO){graph.audioCache.limitMb=mb;graph.audioCache.trim()};measure()}}.padding(18.dp).testTag("audioCache-$mb").semantics{selected=limit==mb},verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                        Icon(if(mb==0)Icons.Rounded.Block else Icons.Rounded.Storage,null,Modifier.size(21.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant);Text(AudioCache.label(mb),Modifier.weight(1f));if(limit==mb)Icon(Icons.Rounded.Check,null)
                    } } }
                    SettingsGroup(null) {
                        SettingsRow("사용 중",Icons.Rounded.BarChart,used?.let{android.text.format.Formatter.formatShortFileSize(graph.app,it)}?:"계산 중",null)
                        Box(Modifier.testTag("clearAudioCache")) { SettingsRow("저장된 음원 지우기",Icons.Rounded.DeleteOutline,null,false){scope.launch{withContext(Dispatchers.IO){graph.audioCache.clear()};measure()}} }
                    }
                    Text("들은 곡을 이 휴대폰에 남겨 다시 들을 때 데이터를 쓰지 않아요. 한도를 넘으면 오래 안 들은 곡부터 지우고, 저장 공간이 부족하면 Android가 비울 수도 있어요. 지금 재생 중인 곡은 남겨 둬요.",Modifier.padding(horizontal=8.dp),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                }
                "오픈소스 라이선스" -> Text(notices,style=MaterialTheme.typography.bodySmall)
            }
        }
    }
    if(confirm)AlertDialog(onDismissRequest={confirm=false},title={Text("이전 음원 파일을 삭제할까요?")},text={Text("곡 정보와 재생목록은 유지돼요. 이후 음악을 들으려면 인터넷 연결이 필요해요.")},confirmButton={TextButton(onClick={confirm=false;scope.launch{withContext(Dispatchers.IO){graph.deleteLegacy()};legacy=withContext(Dispatchers.IO){graph.legacyBytes()}}}){Text("삭제")}},dismissButton={TextButton(onClick={confirm=false}){Text("취소")}})
}
@Composable private fun SettingsGroup(title:String?,content:@Composable ColumnScope.()->Unit) { Column(verticalArrangement=Arrangement.spacedBy(10.dp)) { title?.let{Text(it,Modifier.padding(horizontal=8.dp),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)};Column(Modifier.fillMaxWidth().swaySurface(),content=content) } }
@Composable private fun SettingsRow(title:String,icon:ImageVector,detail:String?=null,chevron:Boolean?=null,onClick:(()->Unit)?=null) { Row(Modifier.fillMaxWidth().then(if(onClick!=null)Modifier.clickable(onClick=onClick) else Modifier).padding(horizontal=18.dp,vertical=18.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) { Icon(icon,null,Modifier.size(21.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant);Column(Modifier.weight(1f)){Text(title);detail?.let{Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}};if(chevron?:(onClick!=null))Icon(Icons.Rounded.ChevronRight,null,Modifier.size(18.dp)) } }
