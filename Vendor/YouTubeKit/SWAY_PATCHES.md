# Sway 로컬 패치

원본: https://github.com/alexeichhorn/YouTubeKit

기준 revision: `e5b7d0396ce12bf3444f0d209e8436c83373b7af`. `Package.swift`, `LICENSE`, `Sources`, `Tests`를 원본에서 복사했다. 원본 MIT 라이선스를 보존한다.

변경 파일은 `Sources/YouTubeKit/SignatureSolver.swift`, `YouTube.swift`, `Extensions/Concurrency.swift`다. 서명 해석기의 기존 `preprocessed_player` 입력·출력 기능을 사용해 공통 플레이어 JavaScript의 전처리를 메모리에서 재사용한다. 기존 추출은 한 곡에서도 두 클라이언트의 응답을 처리하며 같은 프로그램을 반복 전처리했다.

- 캐시 키는 원본 JavaScript 문자열 전체다. 프로그램이 바뀌면 이전 결과를 사용하지 않는다.
- `NSCache`에 최대 2개 / 비용 한도 16 MiB를 지정했다. 이는 OS가 회수할 수 있는 메모리 캐시이며 디스크 저장이 아니다.
- 캐시에 음원·곡별 서명·재생 URL·로그인 정보를 저장하지 않는다.
- 각 해석은 별도 VM/context에서 현재 요청의 입력으로 실행한다.
- 캐시 사용 중 오류가 나면 해당 항목을 버리고 원본 전처리 경로를 한 번 실행한다.
- 클라이언트 선택·포맷·최고 AAC 선택·원본 언어 필터는 유지한다.

2026-10-15 추가: `YouTube.swift`의 공유 원본 JS를 서로 독립적인 static URL/String 쌍에서 URL-keyed `NSCache`로 바꿨다. 다른 player 버전의 URL과 소스가 동시 요청에서 잘못 짝지어지는 것을 막는다. 최대 2개 / 비용 한도 16 MiB이며 서명 실패 시 해당 URL 항목만 제거한다. 앱의 곡별 URL 캐시는 별도 `App/AudioResolutionCache.swift`에 있고 이 공통 JS 캐시에는 포함되지 않는다.

`concurrentMap`은 구조화된 task group을 사용한다. 부모 취소가 자식 네트워크 요청에도 전달되며 결과는 원래 입력 순서로 복원한다. 추출 시작·서명 처리·재시도 경계에 취소 확인을 추가했다. 이미 실행 중인 동기 JavaScript 계산을 강제로 중단하는 기능은 아니다.

패키지를 업데이트할 때 원본과의 차이를 이 파일로 확인하고, 실제 다곡 연속 추출·재생 및 캐시 유무 성능을 다시 검증한다. 패치만 임시 package checkout에 적용하면 재설치 시 사라지므로 앱과 진단 도구가 이 로컬 패키지를 함께 참조한다.

2026-10-20 추가(데이터 사용량): `YouTube.swift`에서 watch 페이지로 얻는 player JS 주소와 `ytcfg`를 곡 사이에 최대 60분 공유한다. 공유 문맥이 있으면 곡마다 watch HTML(압축 약 150 KB)을 받지 않고 InnerTube player 응답만 받는다. 웹 플레이어가 다음 영상으로 넘어갈 때 페이지를 다시 받지 않는 방식과 같다.

- 공유 경로는 InnerTube 응답 중 `playabilityStatus.status == "OK"`이고 `streamingData`가 있는 것이 하나 이상일 때만 쓴다. 그 밖의 응답이나 어떤 오류든 나면 인스턴스 상태를 비우고 원래 watch 페이지 경로(`checkAvailability` 포함)로 처음부터 판정한다. 불가·비공개·회원 전용 영상의 오류 종류는 원래 경로가 정한다.
- 문맥은 원래 경로가 watch 페이지로 성공했을 때만 저장한다. 연령 제한 영상(embed player)은 저장하지 않는다. 공유 경로 성공은 만료 시각을 늘리지 않는다.
- `YouTube.invalidateSharedPageContext()`로 버린다. 앱은 재생 실패 후 주소 갱신과 망 변경 때 호출한다.
- 저장하는 것은 player JS 주소와 `ytcfg`(visitor data·user agent)뿐이며 메모리에만 있다. 곡별 응답·재생 URL·로그인 정보는 저장하지 않는다.
- 클라이언트 2개(visionOS·web)·포맷·최고 AAC 선택·원본 언어 필터는 그대로다.

2026-10-26 추가(곡을 누르고 바로 화면을 잠글 때): `SignatureSolver.swift`가 전처리 결과를 메모리와 함께 `Library/Caches/YouTubeKit/preprocessed-players/<원본 JS의 SHA-256>.js`에도 저장한다. 앱을 다시 켠 뒤 첫 곡도 player JS 전체를 다시 분석하지 않는다.

- 실기기(iPhone 13 mini) 로그로 잰 값: 앱을 켠 뒤 첫 곡의 전체 분석이 화면이 켜져 있으면 약 2.5초, 곡을 누르고 바로 잠그면 약 21초 걸렸다. 그래서 탭부터 재생까지 6초가 25초로 늘어, iOS가 화면이 꺼진 앱에 주는 실행 시간(약 30초)에 가까웠다. 화면이 꺼진 앱은 낮은 우선순위로 돌아서 같은 계산이 느려진다.
- 파일 이름이 원본 JS 내용의 해시라 player가 바뀌면 이전 결과를 쓰지 않는다. 최근에 쓴 두 개만 남긴다(2026-10-27 네 개로 늘림). 저장하는 것은 player 프로그램의 전처리본뿐이고 곡·서명·재생 URL·로그인 정보는 없다.
- 저장본으로 해석하다 오류가 나면 메모리·디스크 항목을 모두 지우고 원래 전처리를 한 번 실행한다.
- 해석마다 `Sway solve source=full|memory|disk setup=…ms solve=…ms`를 기본 수준 로그로 남긴다. 기기 로그에서 이 단계 시간을 재는 용도다.
- YouTube가 player를 바꾼 뒤 첫 곡은 여전히 전체 분석을 한다.

2026-10-27 추가(다시 켠 앱이 다른 player를 받는 문제): `YouTube.swift`가 서명 해석에 성공한 player JS 주소를 `Library/Caches/YouTubeKit/player-pin.json`에 고정하고, 다음 실행부터 watch 페이지가 준 주소 대신 쓴다.

- 쿠키 없는 watch 페이지는 요청마다 여러 player 버전 중 하나를 준다. 아이폰은 하루에 4개를 받았다. 위 디스크 저장만으로는 다시 켠 앱이 다른 버전을 받으면 전체 분석을 다시 했다. 실기기에서 잠긴 상태로 19.8초, 탭부터 재생까지 27초였다.
- 고정은 만든 시각부터 48시간 동안만 쓰고, 성공해도 늘리지 않는다. 연령 제한 영상(embed player)에는 쓰지 않는다. `https://(www.)youtube.com/s/player/…` 주소만 받는다.
- 고정을 버리는 경우는 셋이다. 고정 player를 HTTP 200으로 받지 못하거나 서명 시각을 찾지 못할 때, 서명 해석이 실패할 때, `invalidateSharedPageContext()`가 불릴 때(앱의 재생 실패 후 주소 갱신·망 변경)다. 그 뒤에는 원래처럼 페이지의 player를 쓰고, 성공하면 그것을 새로 고정한다.
- 저장하는 것은 player 주소와 만든 시각뿐이다.
- 전처리본은 최근 네 개를 남긴다.
- 시험: `PlayerPinStoreTests`(만료·덮어쓰기·거부)와 `SolverDiskCacheTests`의 실제 조회 2개. 다시 켠 것처럼 만들면 전체 분석 횟수(`SignatureSolver.fullSolves`)가 늘지 않고 재생 주소가 받아지는지, 받을 수 없는 player를 고정하면 페이지 player로 돌아가는지를 본다.
