@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class, androidx.compose.ui.ExperimentalComposeUiApi::class)
package com.tinkerer0.sway

import android.Manifest
import android.content.ComponentName
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.BackHandler
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.*
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.*
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.scheduler.Requirements
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import coil.compose.AsyncImage
import kotlinx.coroutines.*
import org.schabi.newpipe.extractor.Page

class MainActivity : ComponentActivity() {
    private var controller by mutableStateOf<MediaController?>(null)
    private var future: com.google.common.util.concurrent.ListenableFuture<MediaController>? = null
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        val graph=(application as SwayApp).graph
        val f=MediaController.Builder(this,SessionToken(this,ComponentName(this,PlaybackService::class.java))).buildAsync(); future=f
        f.addListener({ runCatching { controller=f.get() }.onFailure { graph.messages.value="플레이어를 시작하지 못했어요." } },ContextCompat.getMainExecutor(this))
        setContent {
            SwayDesign {
                // 항상 어두운 화면이라 상태 표시줄·내비게이션 바 글자는 밝게 둔다.
                SideEffect { androidx.core.view.WindowCompat.getInsetsController(window, window.decorView).apply { isAppearanceLightStatusBars = false; isAppearanceLightNavigationBars = false } }
                SwayScreen(graph,controller) { if(android.os.Build.VERSION.SDK_INT>=33) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) } }
        }
    }
    // 화면으로 돌아올 때도 받을 곡을 맞춘다. Android 15 이상 시간 제한으로 멈춘 받기를 화면이 살아 있는 채로 돌아와도 다시 켠다.
    override fun onStart() { super.onStart(); val graph=(application as SwayApp).graph; graph.visible=true; window.decorView.post { graph.syncOffline() } }
    override fun onStop() { (application as SwayApp).graph.visible=false; super.onStop() }
    override fun onDestroy() { future?.let(MediaController::releaseFuture); controller=null; super.onDestroy() }
}
private data class PlayerState(val track: MediaItem?=null,val playing:Boolean=false,val loading:Boolean=false,val position:Long=0,val duration:Long=0,val repeat:Int=0,val shuffle:Boolean=false,val queue:List<MediaItem> = emptyList(),val index:Int=0)
@Composable private fun playerState(player: Player?): PlayerState {
    var state by remember { mutableStateOf(PlayerState()) }
    LaunchedEffect(player) { while(isActive) {
        state=PlayerState(player?.currentMediaItem,player?.playWhenReady==true,player?.playbackState==Player.STATE_BUFFERING,
            player?.currentPosition?:0,(player?.duration?:0).coerceAtLeast(0),player?.repeatMode?:0,player?.shuffleModeEnabled==true,
            (0 until (player?.mediaItemCount?:0)).map { player!!.getMediaItemAt(it) },player?.currentMediaItemIndex?:0)
        delay(350)
    } }
    return state
}
@Composable private fun SwayScreen(graph:AudioGraph,player:MediaController?,requestNotification:()->Unit) {
    val library by graph.library.state.collectAsStateWithLifecycle()
    val message by graph.messages.collectAsStateWithLifecycle()
    val mix by graph.mixSeed.collectAsStateWithLifecycle()
    val mixing by graph.mixing.collectAsStateWithLifecycle()
    val downloads by graph.offline.downloads.collectAsStateWithLifecycle(); val notMet by graph.offline.notMet.collectAsStateWithLifecycle()
    val downloaded=remember(downloads) { downloads.filterValues { it.state==Download.STATE_COMPLETED }.keys }
    // 받아 두기를 켠 재생목록의 곡이 바뀌면(켜기·끄기·곡 추가·빼기·삭제) 받을 곡을 맞춘다. 앱을 열 때도 한 번 맞춰 남은 곡을 이어 받는다.
    val offlineIds=remember(library.playlists) { library.playlists.filter { it.offline }.flatMap { it.ids }.toSet() }
    LaunchedEffect(offlineIds) { graph.syncOffline() }
    val playback=playerState(player); val scope=rememberCoroutineScope(); val focus=LocalFocusManager.current
    // 재생 중인 곡의 표지에서 뽑은 색: 미니플레이어 면, 재생 화면 배경, 목록의 재생 중 표시에 쓴다.
    val tint=artworkTint(playback.track?.mediaMetadata?.artworkUri?.toString()); val now=NowPlaying(playback.track?.mediaId,tint.highlight)
    val fieldFocus=remember { FocusRequester() }
    val snackbar=remember { SnackbarHostState() }
    var collection by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }; var submitted by rememberSaveable { mutableStateOf("") }; var music by rememberSaveable { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }; var scopeMenu by remember { mutableStateOf(false) }
    var results by remember { mutableStateOf<SearchPage?>(null) }; var searching by remember { mutableStateOf(false) }
    var searchError by remember { mutableStateOf<String?>(null) }; var searchJob by remember { mutableStateOf<Job?>(null) }; var generation by remember { mutableIntStateOf(0) }
    var settings by remember { mutableStateOf(false) }; var fullPlayer by remember { mutableStateOf(false) }; var queue by remember { mutableStateOf(false) }
    var selectedTrack by remember { mutableStateOf<Track?>(null) }; var adding by remember { mutableStateOf<List<Track>?>(null) }; var removeTrack by remember { mutableStateOf<Track?>(null) }
    var playlistEditor by remember { mutableStateOf(false) }; var renameId by remember { mutableStateOf<String?>(null) }; var playlistName by remember { mutableStateOf("") }; var deletePlaylist by remember { mutableStateOf<Playlist?>(null) }
    var offlineOff by remember { mutableStateOf<Playlist?>(null) }
    val playlist=library.playlists.find { it.id==collection }
    val tracks=when(collection){null->emptyList();"saved"->library.saved;"recent"->library.recent;else->playlist?.ids?.mapNotNull { id->library.saved.find { it.id==id } }?:emptyList()}
    // 저장한 곡·최근 들은 곡에서 고른 순서대로 재생하거나 담는다.
    var choosing by remember { mutableStateOf(false) }; var chosen by remember { mutableStateOf(listOf<String>()) }; var picking by remember { mutableStateOf(false) }
    val chosenTracks=chosen.mapNotNull { id->tracks.find { it.id==id } }
    fun finishChoosing() { choosing=false; chosen=emptyList() }
    LaunchedEffect(collection) { finishChoosing(); picking=false }
    val showingLibrary=collection==null && query.isEmpty() && submitted.isEmpty() && !editing
    val compact=LocalDensity.current.fontScale>1.4f
    LaunchedEffect(message) { message?.let { snackbar.showSnackbar(it); graph.messages.value=null } }
    fun search(more:Boolean=false, dismissKeyboard:Boolean=true) {
        val prior=results
        if(more && prior==null) return
        searchJob?.cancel(); val token=++generation
        val term=query.trim(); val mode=music
        if(dismissKeyboard) { focus.clearFocus(); editing=false }
        searchError=null
        if(!more) {
            submitted=term
            if(term.isBlank()) { results=null; searching=false; return }
            results=null
        }
        searching=true
        searchJob=scope.launch {
            try {
                val page=withContext(Dispatchers.IO) { graph.catalog.search(if(more)prior!!.query else term,if(more)prior!!.music else mode,if(more)prior?.next else null) }
                if(token==generation) results=if(more)page.copy(tracks=(prior!!.tracks+page.tracks).distinctBy { it.id }) else page
            } catch(e:Exception) { if(e is CancellationException)throw e; if(token==generation)searchError="검색을 불러오지 못했어요. 연결을 확인해 주세요." }
            finally { if(token==generation)searching=false }
        }
    }
    fun cancelSearch() {
        generation++; searchJob?.cancel(); searchJob=null
        query=""; submitted=""; results=null; searchError=null; searching=false
        focus.clearFocus(); editing=false
    }
    BackHandler(collection!=null || !showingLibrary) { if(choosing) finishChoosing() else if(collection!=null) collection=null else cancelSearch() }
    fun play(track:Track,tracks:List<Track> = listOf(track)) { requestNotification(); graph.play(track,tracks) }
    fun newPlaylist() { playlistName=""; renameId=null; playlistEditor=true }
    fun openSearch() { collection=null; fieldFocus.requestFocus() }
    Backdrop(Modifier.fillMaxSize().semantics { testTagsAsResourceId=true }) {
        Scaffold(containerColor=Color.Transparent,snackbarHost={SnackbarHost(snackbar)},contentWindowInsets=WindowInsets.safeDrawing,bottomBar={
            if(choosing || (!editing && playback.track!=null)) Column(Modifier.navigationBarsPadding()) {
            if(choosing) FlowRow(Modifier.padding(horizontal=12.dp).padding(top=4.dp,bottom=6.dp).fillMaxWidth().swaySurface().padding(8.dp).testTag("choiceBar"),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(8.dp),maxItemsInEachRow=if(compact)1 else 3) {
                ActionButton("재생",Icons.Rounded.PlayArrow,{play(chosenTracks.first(),chosenTracks);finishChoosing()},Modifier.weight(1f).testTag("playChosen"),enabled=chosen.isNotEmpty())
                ActionButton("셔플",Icons.Rounded.Shuffle,{val shuffled=chosenTracks.shuffled();play(shuffled.first(),shuffled);finishChoosing()},Modifier.weight(1f),enabled=chosen.isNotEmpty())
                ActionButton("담기",Icons.AutoMirrored.Rounded.PlaylistAdd,{adding=chosenTracks},Modifier.weight(1f).testTag("addChosenToPlaylist").semantics{contentDescription="재생목록에 담기"},enabled=chosen.isNotEmpty())
            }
            if(!editing) playback.track?.let { item ->
                Column(Modifier.padding(horizontal=12.dp).padding(top=4.dp,bottom=6.dp).fillMaxWidth().clip(RoundedCornerShape(CARD_RADIUS.dp)).background(tint.backdrop).testTag("miniPlayer")) {
                    Row(Modifier.padding(start=12.dp,end=4.dp,top=10.dp,bottom=6.dp),verticalAlignment=Alignment.CenterVertically) {
                        Row(Modifier.weight(1f).clickable { fullPlayer=true },verticalAlignment=Alignment.CenterVertically) {
                            Artwork(item.mediaMetadata.artworkUri?.toString(),44)
                            Column(Modifier.padding(horizontal=12.dp)) {
                                Text(item.mediaMetadata.title?.toString().orEmpty(),maxLines=1,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.bodyMedium,fontWeight=FontWeight.SemiBold)
                                Text(item.mediaMetadata.artist?.toString().orEmpty(),maxLines=1,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.bodySmall,color=Color.White.copy(alpha=.7f))
                            }
                        }
                        IconButton(onClick={ graph.toggle() }) { if(playback.loading)CircularProgressIndicator(Modifier.size(22.dp),strokeWidth=2.dp) else Icon(if(playback.playing)Icons.Rounded.Pause else Icons.Rounded.PlayArrow,if(playback.playing)"일시정지" else "재생") }
                        IconButton(onClick={ player?.seekToNextMediaItem() },enabled=player?.hasNextMediaItem()==true) { Icon(Icons.Rounded.SkipNext,"다음 곡") }
                    }
                    LinearProgressIndicator(progress={if(playback.duration>0)(playback.position.toFloat()/playback.duration).coerceIn(0f,1f) else 0f},modifier=Modifier.fillMaxWidth().padding(horizontal=16.dp).padding(bottom=8.dp).height(2.dp),color=Color.White,trackColor=Color.White.copy(alpha=.16f),drawStopIndicator={})
                }
            }
            }
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
                if(collection!=null) {
                    Row(Modifier.fillMaxWidth().padding(horizontal=12.dp,vertical=8.dp),verticalAlignment=Alignment.CenterVertically) {
                        IconButton(onClick={collection=null}) { Icon(Icons.AutoMirrored.Rounded.ArrowBack,"보관함으로") }
                        Text(if(choosing)(if(chosen.isEmpty())"곡 선택" else "${chosen.size}곡 선택") else when(collection){"saved"->"저장한 곡";"recent"->"최근 들은 곡";else->playlist?.name?:"재생목록"},Modifier.weight(1f),style=MaterialTheme.typography.headlineSmall,maxLines=1,overflow=TextOverflow.Ellipsis)
                        if(playlist==null && tracks.isNotEmpty()) TextButton(onClick={if(choosing)finishChoosing() else choosing=true},modifier=Modifier.testTag(if(choosing)"cancelChoosing" else "chooseTracks").defaultMinSize(minWidth=44.dp,minHeight=44.dp)) { Text(if(choosing)"취소" else "선택") }
                    }
                } else {
                    Row(Modifier.padding(horizontal=20.dp,vertical=12.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)) {
                        Row(Modifier.weight(1f).swaySurface(control=true).heightIn(min=52.dp).padding(horizontal=8.dp),verticalAlignment=Alignment.CenterVertically) {
                            Box { TextButton(onClick={scopeMenu=true},contentPadding=PaddingValues(horizontal=5.dp),modifier=Modifier.testTag("searchScope").defaultMinSize(minWidth=44.dp,minHeight=44.dp)) { Text(if(music)"음악" else "전체",style=MaterialTheme.typography.bodySmall,fontWeight=FontWeight.SemiBold); Icon(Icons.Rounded.ExpandMore,null,Modifier.size(15.dp)) }
                                DropdownMenu(expanded=scopeMenu,onDismissRequest={scopeMenu=false}) { listOf(false to "전체", true to "음악").forEach { (mode,label) -> DropdownMenuItem(text={Text(label)},onClick={music=mode;scopeMenu=false;search()},modifier=Modifier.testTag(if(mode)"searchMode-music" else "searchMode-all")) } }
                            }
                            VerticalDivider(Modifier.height(22.dp).padding(end=8.dp))
                            BasicTextField(value=query,onValueChange={query=it},singleLine=true,textStyle=MaterialTheme.typography.bodyLarge.copy(color=MaterialTheme.colorScheme.onSurface),cursorBrush=SolidColor(LocalPalette.current.accent),
                                modifier=Modifier.weight(1f).padding(vertical=12.dp).testTag("searchField").focusRequester(fieldFocus).onFocusChanged { editing=it.isFocused },keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={search()}),
                                decorationBox={ inner -> Box { if(query.isEmpty())Text(if(compact)"검색" else "노래, 가수 검색",style=MaterialTheme.typography.bodyLarge,color=MaterialTheme.colorScheme.onSurfaceVariant); inner() } })
                            if(query.isNotEmpty())IconButton(onClick={query="";search(dismissKeyboard=false);editing=true;fieldFocus.requestFocus()},modifier=Modifier.testTag("clearSearch")) { Icon(Icons.Rounded.Cancel,"검색어 지우기",Modifier.size(18.dp)) }
                        }
                        if(!showingLibrary) TextButton(onClick={cancelSearch()},modifier=Modifier.testTag("cancelSearch").defaultMinSize(minWidth=44.dp,minHeight=44.dp)) { Text("취소") }
                        else IconButton(onClick={settings=true},modifier=Modifier.swaySurface(control=true).testTag("openSettings")) { Icon(Icons.Rounded.Settings,"설정") }
                    }
                }
                if(searching && collection==null && !showingLibrary) LinearProgressIndicator(Modifier.fillMaxWidth())
                if(collection!=null || showingLibrary) {
                    LazyColumn(Modifier.weight(1f).testTag(if(collection==null)"libraryHome" else "libraryList"),contentPadding=PaddingValues(start=20.dp,end=20.dp,bottom=24.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                        if(collection==null) {
                            // 블랙 홈: 카드 없이 큰 제목과 표지로 구성한다. 구역 제목을 누르면 전체 목록으로 간다.
                            if(library.recent.isNotEmpty()) item { Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                SectionHeading("최근 들은 곡"){collection="recent"}
                                val recent=library.recent.take(12)
                                // 가로 목록만 화면 양끝까지 닿게 한다(바깥 목록의 좌우 여백 20dp를 넘긴다).
                                LazyRow(Modifier.layout { measurable,constraints -> val extra=40.dp.roundToPx(); val placeable=measurable.measure(constraints.copy(minWidth=constraints.maxWidth+extra,maxWidth=constraints.maxWidth+extra)); layout(constraints.maxWidth,placeable.height) { placeable.place(-extra/2,0) } }.testTag("recentRow"),
                                    contentPadding=PaddingValues(horizontal=20.dp),horizontalArrangement=Arrangement.spacedBy(14.dp)) {
                                    items(recent,key={it.id}) { track -> Column(Modifier.width(136.dp).clickable { play(track,recent) }.semantics(mergeDescendants=true){contentDescription="${track.title}, ${track.artist}, 재생"},verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                        Artwork(track.artwork,136)
                                        Column { Text(track.title,style=MaterialTheme.typography.bodyMedium,fontWeight=FontWeight.Medium,maxLines=1,overflow=TextOverflow.Ellipsis,color=if(now.id==track.id)now.highlight else Color.Unspecified);Text(track.artist,style=MaterialTheme.typography.bodySmall,maxLines=1,overflow=TextOverflow.Ellipsis,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                                    } }
                                }
                            } }
                            item { Column(Modifier.padding(top=if(library.recent.isNotEmpty())18.dp else 0.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                SectionHeading("저장한 곡"){collection="saved"}
                                if(library.saved.isEmpty()) Text("곡 옆의 메뉴에서 보관함에 추가할 수 있어요.",style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
                                else library.saved.take(4).forEach { track -> TrackRow(track,{play(track,library.saved)},{selectedTrack=track},now,downloaded=track.id in downloaded) }
                            } }
                            item { FlowRow(Modifier.fillMaxWidth().padding(top=18.dp),verticalArrangement=Arrangement.spacedBy(8.dp),itemVerticalAlignment=Alignment.CenterVertically) { Text("재생목록",Modifier.weight(1f),style=MaterialTheme.typography.headlineSmall); ActionButton("만들기",Icons.Rounded.Add,::newPlaylist,Modifier.testTag("createPlaylist")) } }
                            if(library.playlists.isEmpty())item { Text("좋아하는 곡끼리 모아보세요. 곡 옆의 메뉴에서 재생목록에 추가할 수 있어요.",style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                            items(library.playlists,key={it.id}) { list -> Row(Modifier.fillMaxWidth().clickable { collection=list.id },verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(14.dp)) {
                                val first=library.saved.find { it.id==list.ids.firstOrNull() }?.artwork
                                if(!first.isNullOrBlank()) Artwork(first,56) else Box(Modifier.size(56.dp).clip(RoundedCornerShape(ARTWORK_RADIUS.dp)).background(LocalPalette.current.surface),contentAlignment=Alignment.Center) { Icon(Icons.AutoMirrored.Rounded.QueueMusic,null,tint=MaterialTheme.colorScheme.onSurfaceVariant) }
                                Column(Modifier.weight(1f)) { Text(list.name,style=MaterialTheme.typography.bodyLarge,maxLines=1,overflow=TextOverflow.Ellipsis); Text("${list.ids.size}곡"+if(list.offline)" · 받아 두기" else "",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                            } }
                        } else {
                            if(playlist!=null)item { FlowRow(horizontalArrangement=Arrangement.spacedBy(10.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) { ActionButton("저장한 곡에서 추가",Icons.Rounded.Add,{picking=true},Modifier.testTag("pickSaved")); ActionButton("이름 변경",Icons.Rounded.Edit,{renameId=playlist.id;playlistName=playlist.name;playlistEditor=true}); ActionButton("삭제",Icons.Rounded.DeleteOutline,{deletePlaylist=playlist}) } }
                            if(playlist!=null)item { OfflineRow(playlist,downloads,notMet,{ on -> if(on){requestNotification();graph.setOffline(playlist.id,true)} else offlineOff=playlist },{graph.syncOffline()}) }
                            if(tracks.isEmpty())item { Column(horizontalAlignment=Alignment.CenterHorizontally) { EmptyState(if(collection=="saved")"아직 저장한 곡이 없어요" else if(collection=="recent")"들은 곡이 여기에 남아요" else "아직 곡이 없어요", if(playlist!=null)"저장한 곡에서 고르거나 곡 옆의 메뉴에서 추가하세요." else "곡 옆의 메뉴에서 보관함에 추가하세요."); if(playlist!=null)ActionButton("저장한 곡에서 고르기",Icons.Rounded.Add,{picking=true}) } }
                            else if(choosing) items(tracks,key={it.id}) { track -> TrackChoiceRow(track,chosen.indexOf(track.id).takeIf { it>=0 }?.plus(1)) { chosen=if(track.id in chosen) chosen-track.id else chosen+track.id } }
                            else item { FlowRow(horizontalArrangement=Arrangement.spacedBy(10.dp)) { ActionButton("전체 재생",Icons.Rounded.PlayArrow,{play(tracks.first(),tracks)}); if(playlist!=null)ActionButton("셔플",Icons.Rounded.Shuffle,{val shuffled=tracks.shuffled();play(shuffled.first(),shuffled)}) } }
                            if(!choosing) items(tracks,key={it.id}) { track -> Column { TrackRow(track,{play(track,tracks)},{selectedTrack=track},now,downloaded=track.id in downloaded)
                                if(playlist!=null)Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.End) { IconButton(onClick={graph.edit{graph.library.move(playlist.id,track.id,-1)}},enabled=tracks.first()!=track) {Icon(Icons.Rounded.KeyboardArrowUp,"곡 위로 이동")};IconButton(onClick={graph.edit{graph.library.move(playlist.id,track.id,1)}},enabled=tracks.last()!=track) {Icon(Icons.Rounded.KeyboardArrowDown,"곡 아래로 이동")};TextButton(onClick={graph.edit{graph.library.removeFromPlaylist(playlist.id,track.id)}}){Text("목록에서 빼기")} }
                            } }
                        }
                    }
                } else {
                    LazyColumn(Modifier.weight(1f).testTag("searchResults"),contentPadding=PaddingValues(start=20.dp,end=20.dp,bottom=24.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                        if(searchError!=null && results?.tracks.isNullOrEmpty()) { item { EmptyState("검색을 불러오지 못했어요",searchError!!); ActionButton("다시 시도",Icons.Rounded.Refresh,{search()}) } }
                        else if(!searching && submitted.isNotEmpty() && results?.tracks.isNullOrEmpty()) {
                            item { EmptyState("검색 결과가 없어요", if(music)"찾는 음원이 없다면 전체 검색도 확인해 보세요." else "다른 검색어로 찾아보세요.") }
                            if(music) item { ActionButton("전체에서 검색",Icons.Rounded.Search,{music=false;search()}) }
                        }
                        items(results?.tracks?:emptyList(),key={it.id}) { track -> TrackRow(track,{play(track)},{selectedTrack=track},now,downloaded=track.id in downloaded) }
                        if(Page.isValid(results?.next)) item { ActionButton("더 보기",Icons.Rounded.ExpandMore,{search(true)},enabled=!searching) }
                        if(!results?.tracks.isNullOrEmpty() && searchError!=null) item { Text(searchError!!,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        }
    }
    if(settings)SettingsScreen(graph){settings=false}
    if(fullPlayer)FullScreen("",{fullPlayer=false},background=Brush.verticalGradient(0f to tint.backdrop,.94f to LocalPalette.current.backdrop),closeIcon=Icons.Rounded.KeyboardArrowDown) {
        playback.track?.let { item -> Player(item,playback,player,graph,mix!=null,mixing,tint,{selectedTrack=graph.track(item)},{queue=true}) }
    }
    if(queue)FullScreen("재생 대기열",{queue=false}) { LazyColumn(contentPadding=PaddingValues(20.dp)) { items(playback.queue.withIndex().toList(),key={it.index}) { row -> graph.track(row.value)?.let { track -> TrackRow(track,{player?.seekToDefaultPosition(row.index);player?.prepare();player?.play()},{selectedTrack=track},if(row.index==playback.index)now else NowPlaying(),downloaded=track.id in downloaded) } } } }
    selectedTrack?.let { track -> ModalBottomSheet(onDismissRequest={selectedTrack=null},containerColor=LocalPalette.current.surface) { Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp).padding(bottom=24.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        Text(track.title,style=MaterialTheme.typography.titleLarge)
        if(library.saved.none { it.id==track.id })ActionButton("보관함에 추가",Icons.Rounded.Add,{graph.save(track);selectedTrack=null}) else Text("보관함에 있음",color=MaterialTheme.colorScheme.onSurfaceVariant)
        ActionButton("재생목록에 추가",Icons.AutoMirrored.Rounded.QueueMusic,{adding=listOf(track);selectedTrack=null})
        ActionButton("알고리즘 시작",Icons.Rounded.AutoAwesome,{requestNotification();graph.startMix(track);selectedTrack=null})
        if(library.saved.any { it.id==track.id })TextButton(onClick={removeTrack=track;selectedTrack=null}){Text("보관함에서 제거",color=MaterialTheme.colorScheme.error)}
    } } }
    adding?.let { picked -> ModalBottomSheet(onDismissRequest={adding=null},containerColor=LocalPalette.current.surface) { Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp).padding(bottom=24.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        Text(if(picked.size>1)"${picked.size}곡을 재생목록에" else "재생목록에 추가",style=MaterialTheme.typography.titleLarge); ActionButton("새 재생목록",Icons.Rounded.Add,::newPlaylist)
        library.playlists.forEach { list -> val missing=picked.filter { it.id !in list.ids }
            ActionButton(list.name+when { missing.isEmpty()->" · 이미 있음"; missing.size<picked.size->" · ${missing.size}곡 추가"; else->"" },Icons.AutoMirrored.Rounded.QueueMusic,{ if(graph.edit { graph.library.addToPlaylist(list.id,missing) }) { adding=null; finishChoosing() } },enabled=missing.isNotEmpty()) }
    } } }
    if(picking) playlist?.let { list -> SavedTrackPicker(library.saved,list.ids.toSet(),{picking=false}) { picked -> if(graph.edit { graph.library.addToPlaylist(list.id,picked) }) picking=false } }
    if(playlistEditor)AlertDialog(onDismissRequest={playlistEditor=false},title={Text(if(renameId==null)"새 재생목록" else "이름 변경")},text={OutlinedTextField(playlistName,{playlistName=it},singleLine=true,label={Text("이름")},modifier=Modifier.testTag("playlistName"))},confirmButton={TextButton(enabled=playlistName.isNotBlank(),onClick={
        val before=library.playlists.map{it.id}.toSet(); if(graph.edit{graph.library.playlist(playlistName,renameId)}) { if(renameId==null && adding!=null)graph.library.state.value.playlists.find{it.id !in before}?.let{val picked=adding!!;if(graph.edit{graph.library.addToPlaylist(it.id,picked)}){adding=null;finishChoosing()}};playlistEditor=false }
    }){Text("저장")}},dismissButton={TextButton(onClick={playlistEditor=false}){Text("취소")}})
    removeTrack?.let { track -> AlertDialog(onDismissRequest={removeTrack=null},title={Text("보관함에서 제거할까요?")},text={Text("재생목록에서도 이 곡이 빠져요.")},confirmButton={TextButton(onClick={graph.edit{graph.library.remove(track.id)};removeTrack=null}){Text("제거")}},dismissButton={TextButton(onClick={removeTrack=null}){Text("취소")}}) }
    deletePlaylist?.let { list -> AlertDialog(onDismissRequest={deletePlaylist=null},title={Text("재생목록을 삭제할까요?")},text={Text("저장한 곡은 보관함에 그대로 남아요."+if(list.offline)" 받아 둔 곡은 기기에서 지워요." else "")},confirmButton={TextButton(onClick={graph.edit{graph.library.update{it.copy(playlists=it.playlists.filterNot{p->p.id==list.id})}};deletePlaylist=null;collection=null}){Text("삭제")}},dismissButton={TextButton(onClick={deletePlaylist=null}){Text("취소")}}) }
    offlineOff?.let { list -> AlertDialog(onDismissRequest={offlineOff=null},title={Text("받아 둔 곡을 지울까요?")},text={Text("이 재생목록의 곡을 기기에서 지워요. 받아 두기를 켠 다른 재생목록에도 있는 곡은 남아요. 다시 받으려면 Wi-Fi가 필요해요.")},
        confirmButton={TextButton(onClick={graph.setOffline(list.id,false);offlineOff=null},modifier=Modifier.testTag("confirmOfflineOff")){Text("지우기")}},dismissButton={TextButton(onClick={offlineOff=null}){Text("취소")}}) }
}
/** 재생목록 받아 두기 스위치와 받은 정도. 받는 일은 데이터 요금이 없는 연결에서만 한다. */
@Composable private fun OfflineRow(list:Playlist,downloads:Map<String,Download>,notMet:Int,onToggle:(Boolean)->Unit,onRetry:()->Unit) {
    val context=LocalContext.current
    val rows=list.ids.map { downloads[it] }
    val done=rows.count { it?.state==Download.STATE_COMPLETED }; val failed=rows.count { it?.state==Download.STATE_FAILED }; val waiting=list.ids.size-done-failed
    val bytes=rows.sumOf { if(it?.state==Download.STATE_COMPLETED) it.bytesDownloaded else 0L }
    val status=when {
        !list.offline -> "Wi-Fi에서 받아 두면 데이터 없이 들을 수 있어요"
        list.ids.isEmpty() -> "곡을 추가하면 Wi-Fi에서 받아요"
        done==list.ids.size -> "${done}곡 모두 받음 · ${android.text.format.Formatter.formatShortFileSize(context,bytes)}"
        else -> "${list.ids.size}곡 중 ${done}곡 받음"+when {
            waiting==0 -> ""
            notMet and (Requirements.NETWORK or Requirements.NETWORK_UNMETERED)!=0 -> " · Wi-Fi를 기다리는 중"
            notMet!=0 -> " · 저장 공간이 부족해요"
            else -> " · 받는 중"
        }+(if(failed>0)" · ${failed}곡 받지 못함" else "")
    }
    Column(Modifier.fillMaxWidth().swaySurface()) {
        Row(Modifier.fillMaxWidth().toggleable(value=list.offline,role=Role.Switch,onValueChange=onToggle).padding(horizontal=16.dp,vertical=12.dp).testTag("offlineToggle"),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
            Icon(if(list.offline && list.ids.isNotEmpty() && done==list.ids.size)Icons.Rounded.DownloadDone else Icons.Rounded.Download,null,tint=LocalPalette.current.accent)
            Column(Modifier.weight(1f)) { Text("받아 두기",style=MaterialTheme.typography.bodyLarge,fontWeight=FontWeight.Medium);Text(status,Modifier.testTag("offlineStatus"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
            Switch(checked=list.offline,onCheckedChange=null)
        }
        if(list.offline && failed>0) TextButton(onClick=onRetry,modifier=Modifier.padding(start=8.dp,bottom=4.dp).testTag("retryOffline")) { Text("다시 시도") }
    }
}
@Composable internal fun FullScreen(title:String,onClose:()->Unit,action:(@Composable RowScope.()->Unit)?=null,background:Brush?=null,closeIcon:ImageVector=Icons.AutoMirrored.Rounded.ArrowBack,content:@Composable ColumnScope.()->Unit) {
    Dialog(onDismissRequest=onClose,properties=DialogProperties(usePlatformDefaultWidth=false,decorFitsSystemWindows=false)) {
        val dialogView = androidx.compose.ui.platform.LocalView.current
        // 창을 상태 표시줄·내비게이션 바 아래까지 펴서 배경(재생 화면의 표지 색)이 화면 끝까지 이어지게 한다.
        SideEffect { (dialogView.parent as? androidx.compose.ui.window.DialogWindowProvider)?.window?.let { w ->
            w.setLayout(android.view.ViewGroup.LayoutParams.MATCH_PARENT,android.view.ViewGroup.LayoutParams.MATCH_PARENT)
            androidx.core.view.WindowCompat.setDecorFitsSystemWindows(w,false)
            @Suppress("DEPRECATION") run { w.statusBarColor=android.graphics.Color.TRANSPARENT; w.navigationBarColor=android.graphics.Color.TRANSPARENT }
            if(android.os.Build.VERSION.SDK_INT>=29) w.isNavigationBarContrastEnforced=false
            androidx.core.view.WindowCompat.getInsetsController(w, dialogView).apply { isAppearanceLightStatusBars = false; isAppearanceLightNavigationBars = false } } }
        Backdrop(Modifier.fillMaxSize().semantics{testTagsAsResourceId=true}) { Column(Modifier.fillMaxSize().then(if(background!=null)Modifier.background(background) else Modifier).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal=12.dp,vertical=6.dp),verticalAlignment=Alignment.CenterVertically) { IconButton(onClick=onClose){Icon(closeIcon,"닫기")};Text(title,Modifier.weight(1f),style=MaterialTheme.typography.titleMedium);action?.invoke(this) }
            content()
        } }
    }
}
/** 홈의 구역 제목. 누르면 전체 목록으로 간다. */
@Composable private fun SectionHeading(title:String,onClick:()->Unit) { Row(Modifier.fillMaxWidth().clickable(onClickLabel="전체 목록 보기",onClick=onClick).padding(vertical=4.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(4.dp)) { Text(title,style=MaterialTheme.typography.headlineSmall);Icon(Icons.Rounded.ChevronRight,null,tint=MaterialTheme.colorScheme.onSurfaceVariant) } }
/** 재생 화면: 표지와 제목이 주인공이고, 조작부는 상자·글자 없이 기호만 둔다(iOS `noirPlayer`). */
@Composable private fun Player(item:MediaItem,playback:PlayerState,player:MediaController?,graph:AudioGraph,mixOn:Boolean,mixing:Boolean,tint:ArtworkTint,onMenu:()->Unit,onQueue:()->Unit) {
    val muted=MaterialTheme.colorScheme.onSurfaceVariant; val ink=Color(0xFF0A0A0A)
    // 일시정지하면 표지가 줄고 재생하면 돌아온다. 시스템에서 애니메이션을 끄면 Compose가 바로 바꾼다.
    val scale by animateFloatAsState(if(playback.playing)1f else .86f,spring(dampingRatio=.72f,stiffness=Spring.StiffnessMediumLow),label="artwork")
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=26.dp).padding(bottom=20.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        Box(Modifier.padding(top=6.dp).widthIn(max=420.dp).fillMaxWidth().aspectRatio(1f).graphicsLayer{scaleX=scale;scaleY=scale}.shadow(22.dp,RoundedCornerShape(ARTWORK_RADIUS.dp)).clip(RoundedCornerShape(ARTWORK_RADIUS.dp)).background(LocalPalette.current.surface),contentAlignment=Alignment.Center) {
            Illustration(160);item.mediaMetadata.artworkUri?.let { AsyncImage(it.toString(),null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop) } }
        Row(Modifier.fillMaxWidth().padding(top=28.dp),verticalAlignment=Alignment.Top) {
            Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(6.dp)) { Text(item.mediaMetadata.title?.toString().orEmpty(),Modifier.testTag("playerTitle"),style=MaterialTheme.typography.headlineSmall,maxLines=if(LocalDensity.current.fontScale>1.4f)4 else 2,overflow=TextOverflow.Ellipsis);Text(item.mediaMetadata.artist?.toString().orEmpty(),style=MaterialTheme.typography.bodyLarge,color=muted,maxLines=1,overflow=TextOverflow.Ellipsis) }
            IconButton(onClick=onMenu){Icon(Icons.Rounded.MoreHoriz,"곡 메뉴")}
        }
        var dragging by remember { mutableStateOf(false) }; var position by remember { mutableFloatStateOf(0f) }
        LaunchedEffect(playback.position) { if(!dragging)position=playback.position.toFloat() }
        Column(Modifier.fillMaxWidth().padding(top=10.dp)) {
            // 기본 Material 슬라이더는 막대와 손잡이가 두꺼워, 얇은 막대와 작은 원 손잡이로 그린다.
            val sliderColors=SliderDefaults.colors(thumbColor=Color.White,activeTrackColor=Color.White,inactiveTrackColor=Color.White.copy(alpha=.2f),disabledActiveTrackColor=Color.White.copy(alpha=.3f),disabledInactiveTrackColor=Color.White.copy(alpha=.12f))
            Slider(value=position.coerceIn(0f,playback.duration.toFloat().coerceAtLeast(1f)),onValueChange={dragging=true;position=it},onValueChangeFinished={player?.seekTo(position.toLong());dragging=false},valueRange=0f..playback.duration.toFloat().coerceAtLeast(1f),enabled=playback.duration>0,
                colors=sliderColors,modifier=Modifier.semantics{contentDescription="재생 위치"},
                thumb={ Box(Modifier.size(14.dp).background(Color.White.copy(alpha=if(playback.duration>0)1f else .4f),CircleShape)) },
                track={ state -> SliderDefaults.Track(sliderState=state,modifier=Modifier.height(4.dp),colors=sliderColors,enabled=playback.duration>0,drawStopIndicator=null,thumbTrackGapSize=0.dp) })
            Row { Text(time(position.toLong()),Modifier.testTag("elapsed"),style=MaterialTheme.typography.bodySmall,color=muted);Spacer(Modifier.weight(1f));Text(time(playback.duration),Modifier.testTag("duration"),style=MaterialTheme.typography.bodySmall,color=muted) }
        }
        Row(Modifier.fillMaxWidth().padding(top=14.dp),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically) {
            IconButton(onClick={player?.shuffleModeEnabled=!playback.shuffle},modifier=Modifier.testTag("playerShuffle").semantics{stateDescription=if(playback.shuffle)"켜짐" else "꺼짐"}) {Icon(Icons.Rounded.Shuffle,"셔플",Modifier.size(22.dp),tint=if(playback.shuffle)tint.highlight else muted)}
            IconButton(onClick={player?.seekToPreviousMediaItem()},enabled=player?.hasPreviousMediaItem()==true,modifier=Modifier.size(52.dp)) {Icon(Icons.Rounded.SkipPrevious,"이전 곡",Modifier.size(38.dp))}
            Box(Modifier.size(72.dp).clip(CircleShape).background(Color.White).clickable(role=Role.Button){graph.toggle()}.testTag("playerPlayPause"),contentAlignment=Alignment.Center) {
                if(playback.loading)CircularProgressIndicator(Modifier.size(28.dp),color=ink,strokeWidth=3.dp) else Icon(if(playback.playing)Icons.Rounded.Pause else Icons.Rounded.PlayArrow,if(playback.playing)"일시정지" else "재생",Modifier.size(36.dp),tint=ink) }
            IconButton(onClick={player?.seekToNextMediaItem()},enabled=player?.hasNextMediaItem()==true,modifier=Modifier.size(52.dp).testTag("playerNext")) {Icon(Icons.Rounded.SkipNext,"다음 곡",Modifier.size(38.dp))}
            IconButton(onClick={player?.repeatMode=(playback.repeat+1)%3},enabled=!mixOn,modifier=Modifier.testTag("playerRepeat")) {Icon(if(playback.repeat==1)Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,if(playback.repeat==0)"반복 끔" else if(playback.repeat==1)"한 곡 반복" else "전체 반복",Modifier.size(22.dp),tint=if(playback.repeat==0||mixOn)muted else tint.highlight)}
        }
        Row(Modifier.fillMaxWidth().padding(top=22.dp),horizontalArrangement=Arrangement.End,verticalAlignment=Alignment.CenterVertically) {
            IconButton(onClick={if(mixOn)graph.stopMix() else graph.track(item)?.let(graph::startMix)},enabled=!mixing,modifier=Modifier.testTag("mixToggle").semantics{stateDescription=if(mixing)"곡을 불러오는 중" else if(mixOn)"켜짐" else "꺼짐"}) {
                if(mixing)CircularProgressIndicator(Modifier.size(20.dp),color=tint.highlight,strokeWidth=2.dp) else Icon(Icons.Rounded.AutoAwesome,if(mixOn)"알고리즘 끄기" else "알고리즘 켜기",Modifier.size(22.dp),tint=if(mixOn)tint.highlight else muted) }
            IconButton(onClick=onQueue) {Icon(Icons.AutoMirrored.Rounded.QueueMusic,"대기열",Modifier.size(22.dp),tint=muted)}
        }
    }
}
@Composable internal fun ActionButton(label:String,icon:ImageVector,onClick:()->Unit,modifier:Modifier=Modifier,enabled:Boolean=true) { TextButton(onClick=onClick,enabled=enabled,modifier=modifier.swaySurface(control=true),contentPadding=PaddingValues(horizontal=14.dp,vertical=8.dp)) { Icon(icon,null,Modifier.size(18.dp));Spacer(Modifier.width(6.dp));Text(label) } }
/** 곡 행: 카드 없이 여백으로만 나눈다. 재생 중인 곡은 제목을 표지 색으로 쓰고 가수 앞에 표시를 둔다. */
@Composable private fun TrackRow(track:Track,onPlay:()->Unit,onMenu:()->Unit,now:NowPlaying=NowPlaying(),downloaded:Boolean=false) { val playing=now.id==track.id
    Row(Modifier.fillMaxWidth().padding(vertical=2.dp),verticalAlignment=Alignment.CenterVertically) {
    Row(Modifier.weight(1f).clickable(onClick=onPlay),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) { Artwork(track.artwork,48);Column { Text(track.title,style=MaterialTheme.typography.bodyLarge,fontWeight=FontWeight.Medium,maxLines=2,overflow=TextOverflow.Ellipsis,color=if(playing)now.highlight else Color.Unspecified)
        Row(verticalAlignment=Alignment.CenterVertically) { if(playing)Icon(Icons.Rounded.GraphicEq,"재생 중",Modifier.padding(end=4.dp).size(14.dp),tint=now.highlight);if(downloaded)Icon(Icons.Rounded.DownloadDone,"받아 둠",Modifier.padding(end=4.dp).size(14.dp).testTag("downloaded-${track.id}"),tint=MaterialTheme.colorScheme.onSurfaceVariant);Text(track.artist+(if(track.duration>0)" · ${time(track.duration*1000)}" else ""),style=MaterialTheme.typography.bodySmall,maxLines=1,overflow=TextOverflow.Ellipsis,color=MaterialTheme.colorScheme.onSurfaceVariant) } } };IconButton(onClick=onMenu){Icon(Icons.Rounded.MoreHoriz,"${track.title} 메뉴")}
} }
/** 곡을 골라 담는 행. 고른 순서를 번호로 보여 준다. */
@Composable private fun TrackChoiceRow(track:Track,order:Int?,note:String?=null,enabled:Boolean=true,onToggle:()->Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(CONTROL_RADIUS.dp)).then(if(order!=null)Modifier.background(Color.White.copy(alpha=.10f)) else Modifier).alpha(if(enabled)1f else .55f).clickable(enabled=enabled,onClick=onToggle).padding(horizontal=12.dp,vertical=10.dp).testTag("choice-${track.id}")
        .semantics(mergeDescendants=true){selected=order!=null;stateDescription=order?.let{"${it}번째로 선택됨"}?:note?:"선택 안 됨"},verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(28.dp).clip(CircleShape).then(if(order!=null)Modifier.background(LocalPalette.current.accent) else Modifier.border(2.dp,MaterialTheme.colorScheme.onSurfaceVariant,CircleShape)),contentAlignment=Alignment.Center) { order?.let { Text(if(it<=99)"$it" else "✓",color=MaterialTheme.colorScheme.onPrimary,style=MaterialTheme.typography.labelMedium,fontWeight=FontWeight.Bold) } }
        Artwork(track.artwork,48)
        Column(Modifier.weight(1f)) { Text(track.title,style=MaterialTheme.typography.bodyLarge,fontWeight=FontWeight.Medium,maxLines=2,overflow=TextOverflow.Ellipsis);Text(note?:(track.artist+(if(track.duration>0)" · ${time(track.duration*1000)}" else "")),style=MaterialTheme.typography.bodySmall,maxLines=1,overflow=TextOverflow.Ellipsis,color=MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}
/** 재생목록에 넣을 곡을 저장한 곡에서 고른다. 이미 있는 곡은 고를 수 없다. */
@Composable private fun SavedTrackPicker(saved:List<Track>,existing:Set<String>,onClose:()->Unit,onAdd:(List<Track>)->Unit) {
    var chosen by remember { mutableStateOf(listOf<String>()) }; var query by remember { mutableStateOf("") }
    val term=query.trim(); val shown=if(term.isEmpty())saved else saved.filter { it.title.contains(term,true) || it.artist.contains(term,true) }
    FullScreen("저장한 곡에서 추가",onClose,action={ TextButton(onClick={onAdd(chosen.mapNotNull { id->saved.find { it.id==id } })},enabled=chosen.isNotEmpty(),modifier=Modifier.testTag("confirmPickedTracks").defaultMinSize(minWidth=44.dp,minHeight=44.dp)) { Text(if(chosen.isEmpty())"추가" else "${chosen.size}곡 추가") } }) {
        if(saved.isEmpty()) EmptyState("아직 저장한 곡이 없어요","곡 옆의 메뉴에서 보관함에 추가할 수 있어요.")
        else {
            Row(Modifier.padding(horizontal=20.dp,vertical=8.dp).fillMaxWidth().swaySurface(control=true).heightIn(min=48.dp).padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Rounded.Search,null,Modifier.size(20.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
                BasicTextField(value=query,onValueChange={query=it},singleLine=true,textStyle=MaterialTheme.typography.bodyLarge.copy(color=MaterialTheme.colorScheme.onSurface),cursorBrush=SolidColor(LocalPalette.current.accent),modifier=Modifier.weight(1f).padding(vertical=12.dp).testTag("pickerSearch"),
                    decorationBox={ inner -> Box { if(query.isEmpty())Text("제목이나 가수",style=MaterialTheme.typography.bodyLarge,color=MaterialTheme.colorScheme.onSurfaceVariant); inner() } })
                if(query.isNotEmpty())IconButton(onClick={query=""}) { Icon(Icons.Rounded.Cancel,"검색어 지우기",Modifier.size(18.dp)) }
            }
            LazyColumn(Modifier.weight(1f),contentPadding=PaddingValues(start=20.dp,end=20.dp,top=4.dp,bottom=24.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                items(shown,key={it.id}) { track -> val added=track.id in existing
                    TrackChoiceRow(track,chosen.indexOf(track.id).takeIf { it>=0 }?.plus(1),if(added)"이미 있음" else null,!added) { chosen=if(track.id in chosen) chosen-track.id else chosen+track.id } }
            }
        }
    }
}
@Composable private fun Artwork(url:String?,size:Int) {
    Box(Modifier.size(size.dp).clip(RoundedCornerShape(ARTWORK_RADIUS.dp)).background(LocalPalette.current.surface),contentAlignment=Alignment.Center) { Illustration((size*.85f).toInt());if(!url.isNullOrBlank())AsyncImage(url,null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop) }
}
@Composable private fun EmptyState(title:String,detail:String) { Column(Modifier.fillMaxWidth().padding(vertical=36.dp,horizontal=12.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(12.dp)) { Icon(Icons.Rounded.MusicNote,null,Modifier.size(36.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant);Text(title,style=MaterialTheme.typography.titleMedium);Text(detail,style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant) } }
private fun time(ms:Long)="%d:%02d".format(ms.coerceAtLeast(0)/60000,ms.coerceAtLeast(0)/1000%60)
