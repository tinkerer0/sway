import XCTest

final class SwayUITests: XCTestCase {
    @MainActor func testBackgroundDuringInitialLookupStillStartsPlayback() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture", "--slow-audio-start"]; app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "저장한 곡")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Big Buck Bunny,")).firstMatch.tap()
        app.buttons["miniPlayer"].tap()
        let elapsed = app.staticTexts["elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["playerPlayPause"].value as? String, "로딩 중")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(16))
        app.activate()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let parts = elapsed.label.split(separator: ":").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2)
        if parts.count == 2 { XCTAssertGreaterThanOrEqual(parts[0] * 60 + parts[1], 5) }
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "일시정지")
        app.buttons["playerPlayPause"].tap()
    }
    @MainActor func testLiveMixAddsAlbumTracksAndKeepsSeed() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        selectScope(app, "music")
        let field = app.textFields["searchField"]; field.tap(); field.typeText("아이유 밤편지\n")
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Through the Night (밤편지),", "재생")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 30)); album.tap()
        app.buttons["miniPlayer"].tap()
        let mix = app.buttons["mixToggle"]
        XCTAssertTrue(mix.isHittable)
        XCTAssertEqual(mix.value as? String, "꺼짐")
        XCTAssertEqual(app.buttons["playerRepeat"].frame.midY, app.buttons["playerShuffle"].frame.midY, accuracy: 2)
        XCTAssertGreaterThan(mix.frame.minY, app.buttons["playerRepeat"].frame.maxY)
        mix.tap()
        XCTAssertTrue(app.buttons["알고리즘 끄기"].waitForExistence(timeout: 40))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["알고리즘 끄기"])
        waitForExpectations(timeout: 40)
        XCTAssertEqual(mix.value as? String, "켜짐")
        let controls = XCTAttachment(screenshot: app.screenshot()); controls.name = "Mix controls active"; controls.lifetime = .keepAlways; add(controls)
        XCTAssertTrue(app.staticTexts["Through the Night (밤편지)"].exists)
        app.buttons["대기열"].tap()
        let tracks = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "재생"))
        XCTAssertGreaterThan(tracks.count, 1)
        XCTAssertTrue(tracks.element(boundBy: 0).label.hasPrefix("Through the Night (밤편지),"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Clean mix queue"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["완료"].tap()
        if app.buttons["playerPlayPause"].label == "일시정지" { app.buttons["playerPlayPause"].tap() }
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["알고리즘 끄기"].exists)
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "재생")
        app.buttons["대기열"].tap()
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "재생")).count, 1)
        app.buttons["완료"].tap(); app.buttons["알고리즘 끄기"].tap()
        XCTAssertTrue(app.buttons["알고리즘 켜기"].exists)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["알고리즘 켜기"].exists)
    }
    @MainActor func testLargeTextLibraryAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["searchScope"].frame.height, 44)
        selectScope(app, "music")
        XCTAssertLessThanOrEqual(app.buttons["searchScope"].frame.maxX, app.textFields["searchField"].frame.minX)
        XCTAssertGreaterThan(app.textFields["searchField"].frame.width, 50)
        capture(app, "Large text search")
        selectScope(app, "all")
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.buttons["storageSettings"].isHittable)
        XCTAssertFalse(app.buttons["themeSettings"].exists)
        capture(app, "Large text settings")
        app.buttons["완료"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "저장한 곡")).firstMatch
        capture(app, "Large text library")
        for _ in 0..<6 { if saved.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(saved.isHittable)
        saved.tap()
        let track = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Big Buck Bunny,")).firstMatch
        XCTAssertTrue(track.isHittable)
        track.tap()
        app.buttons["miniPlayer"].tap()
        if app.buttons["playerPlayPause"].label == "일시정지" { app.buttons["playerPlayPause"].tap() }
        let mix = app.buttons["mixToggle"]
        for _ in 0..<6 { if mix.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(mix.isHittable)
        XCTAssertGreaterThanOrEqual(mix.frame.height, 44)
        XCTAssertGreaterThanOrEqual(mix.frame.width, 44)
        capture(app, "Large text player controls")
    }
    @MainActor func testSettingsLicenses() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        app.buttons["openSettings"].tap()
        app.buttons["Sway 정보"].tap()
        XCTAssertTrue(app.staticTexts["좋아하는 음악을, 가볍게."].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["오픈소스 라이선스"].tap()
        app.buttons["YouTubeKit"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "MIT License")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Galmuri11"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SIL Open Font License")).firstMatch.exists)
    }
    @MainActor func testStorageSettingsSelectsLimitAndClears() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        app.buttons["openSettings"].tap()
        let row = app.buttons["storageSettings"]
        XCTAssertTrue(row.waitForExistence(timeout: 3)); row.tap()
        app.buttons["audioCache-500"].tap()
        XCTAssertTrue(app.buttons["audioCache-500"].isSelected)
        XCTAssertTrue(app.buttons["clearAudioCache"].exists); app.buttons["clearAudioCache"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Storage settings"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.buttons["storageSettings"].value as? String, "500 MB")
        // 다른 시험이 기본값을 쓰도록 되돌린다.
        app.buttons["storageSettings"].tap(); app.buttons["audioCache-1024"].tap()
        XCTAssertTrue(app.buttons["audioCache-1024"].isSelected)
    }
    @MainActor func testSearchEditingClearAndCancel() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.isHittable)
        XCTAssertFalse(app.navigationBars["검색"].exists)
        field.tap(); field.typeText("아이유")
        XCTAssertTrue(app.buttons["cancelSearch"].isHittable)
        app.buttons["clearSearch"].tap()
        XCTAssertFalse(app.buttons["clearSearch"].exists)
        field.typeText("밤편지")
        app.buttons["cancelSearch"].tap()
        XCTAssertTrue(app.buttons["createPlaylist"].isHittable)
        XCTAssertFalse(app.buttons["cancelSearch"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["openSettings"].isHittable)
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.buttons["storageSettings"].isHittable)
        app.buttons["완료"].tap()
        XCTAssertTrue(app.buttons["createPlaylist"].isHittable)
        XCTAssertFalse(app.buttons["cancelSearch"].exists)
    }
    @MainActor func testUnifiedHome() {
        do {
            let app = XCUIApplication()
            app.launchArguments = ["--uitesting", "--reset-fixture", "--home-layout-fixture"]
            app.launch()
            let field = app.textFields["searchField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["createPlaylist"].isHittable)
            let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "저장한 곡")).firstMatch
            let recent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "최근 들은 곡")).firstMatch
            XCTAssertTrue(saved.isHittable); XCTAssertTrue(recent.isHittable)
            XCTAssertGreaterThan(saved.frame.minY, field.frame.maxY)
            XCTAssertFalse(app.buttons["tab-search"].exists)
            XCTAssertFalse(app.buttons["tab-library"].exists)
            XCTAssertFalse(app.tabBars.firstMatch.exists)
            XCTAssertFalse(app.buttons["refreshDiscovery"].exists)
            XCTAssertFalse(app.staticTexts["추천"].exists)
            XCTAssertTrue(app.buttons["miniPlayer"].isHittable)
            let playlist = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "테스트 목록")).firstMatch
            XCTAssertLessThan(playlist.frame.maxY, app.buttons["miniPlayer"].frame.minY)
            capture(app, "Unified home")
            field.tap(); field.typeText("IU")
            XCTAssertTrue(app.buttons["cancelSearch"].isHittable)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            XCTAssertFalse(app.buttons["createPlaylist"].exists)
            XCTAssertFalse(app.buttons["miniPlayer"].exists)
            capture(app, "Unified home search keyboard")
            app.buttons["cancelSearch"].tap()
            XCTAssertTrue(app.buttons["createPlaylist"].isHittable)
            XCTAssertTrue(app.buttons["miniPlayer"].isHittable)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            playlist.tap()
            XCTAssertTrue(app.navigationBars["테스트 목록"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.textFields["searchField"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(field.isHittable)
            saved.tap()
            XCTAssertTrue(app.navigationBars["저장한 곡"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Big Buck Bunny,")).firstMatch.exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["openSettings"].isHittable)
            app.terminate()
        }
    }
    @MainActor func testCancelInFlightSearchReturnsToLibrary() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        let field = app.textFields["searchField"]
        field.tap(); field.typeText("아이유 밤편지\n")
        XCTAssertTrue(app.buttons["cancelSearch"].waitForExistence(timeout: 3))
        app.buttons["cancelSearch"].tap()
        XCTAssertTrue(app.buttons["createPlaylist"].waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(app.buttons["createPlaylist"].isHittable)
        XCTAssertFalse(app.buttons["cancelSearch"].exists)
        // 홈에는 저장한 곡 행이 있으므로 검색 결과(밤편지)만 없는지 본다.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH %@", "밤편지", ", 재생")).firstMatch.exists)
    }
    @MainActor private func selectScope(_ app: XCUIApplication, _ value: String) {
        let scope = app.buttons["searchScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 3))
        scope.tap()
        let option = app.buttons["searchMode-\(value)"]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        XCTAssertEqual(scope.value as? String, value == "music" ? "음악" : "전체")
    }
    @MainActor func testUnifiedHomePreservesLibraryOnRelaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture", "--home-layout-fixture"]; app.launch()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "저장한 곡")).firstMatch
        saved.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Big Buck Bunny,")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "최근 들은 곡")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Through the Night")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["miniPlayer"].tap()
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "재생")
        app.buttons["닫기"].tap()
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["createPlaylist"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["miniPlayer"].isHittable)
        XCTAssertFalse(app.buttons["refreshDiscovery"].exists)
    }
    /// 예전에 저장된 테마·화면 모드 값이 있어도 블랙 화면이고, 홈·재생 화면의 조작 요소가 그대로 있다.
    @MainActor func testNoirThemeHomeAndPlayer() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-fixture", "--home-layout-fixture", "-sway.theme", "glass", "-sway.appearance", "light"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["createPlaylist"].isHittable)
        let saved = app.buttons["저장한 곡"], recent = app.buttons["최근 들은 곡"]
        XCTAssertTrue(saved.isHittable); XCTAssertTrue(recent.isHittable)
        XCTAssertTrue(app.buttons["miniPlayer"].isHittable)
        let playlist = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "테스트 목록")).firstMatch
        XCTAssertTrue(playlist.isHittable)
        // 홈의 저장한 곡에서 바로 재생한다. 표지가 있는 곡이어야 표지 색이 화면에 반영된다.
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Big Buck Bunny,")).firstMatch.tap()
        sleep(3)
        capture(app, "Noir home")
        saved.tap()
        XCTAssertTrue(app.navigationBars["저장한 곡"].waitForExistence(timeout: 3))
        capture(app, "Noir saved list")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["playerTitle"].waitForExistence(timeout: 3))
        for id in ["playerPlayPause", "playerNext", "playerShuffle", "playerRepeat", "mixToggle"] { XCTAssertTrue(app.buttons[id].exists, id) }
        XCTAssertFalse(app.staticTexts["지금 재생 중"].exists)
        sleep(1)
        capture(app, "Noir player playing")
        if app.buttons["playerPlayPause"].label == "일시정지" { app.buttons["playerPlayPause"].tap() }
        sleep(1)
        capture(app, "Noir player paused")
        app.buttons["닫기"].tap()
        app.buttons["openSettings"].tap()
        for id in ["themeSettings", "colorSettings", "appearanceSettings"] { XCTAssertFalse(app.buttons[id].exists, id) }
        XCTAssertTrue(app.buttons["storageSettings"].isHittable)
        capture(app, "Noir settings")
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testMusicSearchFindsAlbumAndKeepsGeneralMode() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        selectScope(app, "music")
        let field = app.textFields["searchField"]
        field.tap(); field.typeText("아이유 밤편지\n")
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Through the Night (밤편지),", "재생")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 30))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Music search"; shot.lifetime = .keepAlways; add(shot)
        selectScope(app, "all")
        let video = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH %@", "[MV]", "재생")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        XCTAssertEqual(field.value as? String, "아이유 밤편지")
    }
    @MainActor func testPlaylistRenameSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-fixture"]
        app.launch()
        app.buttons["createPlaylist"].tap()
        app.alerts.textFields.firstMatch.typeText("Walking")
        app.alerts.buttons["만들기"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Walking")).firstMatch.tap()
        app.buttons["재생목록 메뉴"].tap()
        app.buttons["이름 변경"].tap()
        let field = app.alerts.textFields.firstMatch
        field.tap(); field.press(forDuration: 1)
        // 기존 이름을 문자 수만큼 지워 새 이름으로 바꾼다.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Walking".count) + "Evening")
        app.alerts.buttons["저장"].tap()
        XCTAssertTrue(app.navigationBars["Evening"].waitForExistence(timeout: 3))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Evening"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Walking"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Sway library"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testLiveAudioAdvancesAndPauses() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "저장한 곡")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Big Buck Bunny,")).firstMatch.tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5)); app.buttons["miniPlayer"].tap()
        let elapsed = app.staticTexts["elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let advances = NSPredicate { _, _ in
            let text = elapsed.label
            let parts = text.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 && parts[0] * 60 + parts[1] >= 3
        }
        expectation(for: advances, evaluatedWith: nil)
        waitForExpectations(timeout: 60)
        app.buttons["playerPlayPause"].tap()
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "재생")
        let pausedAt = elapsed.label
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(elapsed.label, pausedAt)
        XCTAssertEqual(app.staticTexts["duration"].label, "9:56")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Live audio player"; shot.lifetime = .keepAlways; add(shot)
        // adjust를 끝 가까이(0.99·0.996)로 주면 몇 초씩 어긋나다가 가끔 맨 끝(596.52초)에 붙는다. 끝 0.5초 안에서
        // 재생을 누르면 처음부터 다시 트는 것이 앱 동작이라 곡이 끝나지 않았다(2026-10-21 반복 시험에서 놓인 위치를 찍어 확인).
        // 끝에서 30초쯤 앞에 놓고 끝날 때까지 기다린다.
        let slider = app.sliders["재생 위치"]
        slider.adjust(toNormalizedSliderPosition: 0.95)
        XCTAssertLessThan((slider.value as? String).flatMap(Double.init) ?? .infinity, 595)
        app.buttons["playerPlayPause"].tap()
        expectation(for: NSPredicate(format: "label == %@", "재생"), evaluatedWith: app.buttons["playerPlayPause"])
        waitForExpectations(timeout: 45)
    }

    @MainActor func testPickSavedTracksForPlaylistAndChosenPlayback() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        // 빈 재생목록에서 저장한 곡을 골라 담는다.
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "테스트 목록")).firstMatch.tap()
        app.buttons["저장한 곡에서 고르기"].tap()
        // 재생목록의 곡 행("…, 재생")과 구분되게 고르는 행의 이름 전체로 찾는다.
        let choice = app.buttons.matching(NSPredicate(format: "label == %@", "Big Buck Bunny, Blender · 재생 확인용")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["confirmPickedTracks"].isEnabled)
        choice.tap()
        XCTAssertEqual(choice.value as? String, "1번째로 선택됨")
        app.buttons["confirmPickedTracks"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Big Buck Bunny,", "재생")).firstMatch.waitForExistence(timeout: 3))
        // 다시 열면 이미 담긴 곡은 고를 수 없다.
        app.buttons["재생목록 메뉴"].tap(); app.buttons["저장한 곡에서 추가"].tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        XCTAssertEqual(choice.value as? String, "이미 있음")
        XCTAssertFalse(choice.isEnabled)
        app.buttons["닫기"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        // 저장한 곡에서 골라 그 곡들만 재생한다.
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "저장한 곡")).firstMatch.tap()
        app.buttons["chooseTracks"].tap()
        XCTAssertFalse(app.buttons["playChosen"].isEnabled)
        choice.tap()
        XCTAssertTrue(app.navigationBars["1곡 선택"].waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Choose saved tracks"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["playChosen"].tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chooseTracks"].exists)
        app.buttons["miniPlayer"].tap()
        XCTAssertEqual(app.staticTexts["playerTitle"].label, "Big Buck Bunny")
        app.buttons["playerPlayPause"].tap()
    }
    @MainActor func testChooseSavedTracksAtLargestText() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "저장한 곡")).firstMatch.tap()
        app.buttons["chooseTracks"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Big Buck Bunny, Blender · 재생 확인용")).firstMatch.tap()
        for id in ["playChosen", "addChosenToPlaylist"] { XCTAssertTrue(app.buttons[id].isHittable, id) }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Choose saved tracks XXXL"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["addChosenToPlaylist"].tap()
        XCTAssertTrue(app.buttons["테스트 목록"].waitForExistence(timeout: 3))
        app.buttons["테스트 목록"].tap()
        XCTAssertTrue(app.buttons["chooseTracks"].waitForExistence(timeout: 3))
    }
    @MainActor func testLiveSearchAndSaveToPlaylist() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"]; app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText("아이유 밤편지\n")
        let menus = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH %@", "밤편지", "메뉴"))
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 30))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Korean search"; shot.lifetime = .keepAlways; add(shot)
        menus.firstMatch.tap(); app.buttons["재생목록에 추가"].tap()
        app.buttons["테스트 목록"].tap()
        app.buttons["cancelSearch"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "테스트 목록")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH %@", "밤편지", "재생")).firstMatch.waitForExistence(timeout: 3))
    }
}
