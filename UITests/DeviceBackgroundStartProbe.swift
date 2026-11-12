import XCTest

/// 실기기 전용 확인: 곡을 누르고 바로 앱을 뒤로 보냈을 때 화면 밖에서 재생이 시작되는지 본다.
/// 실제 보관함과 받아 둔 곡을 그대로 쓴다. --reset-fixture는 받아 둔 음원을 지우므로 넘기지 않고, Release로 빌드해
/// 시험용 인자를 모두 끈다. 판정의 정본은 아이폰 로그(audiomxd "can't stop others", AVPlayer timeControlStatus)다.
/// 아이폰은 UI 자동화를 켤 때마다 Face ID·암호를 요구하므로(2026-10-28 testmanagerd "requires authentication"),
/// 여러 경우를 한 번의 xcodebuild로 이름 순서대로 돌린다. 검색어는 TEST_RUNNER_SWAY_PROBE_<키>로 넘긴다
/// ("검색어|결과 제목에 든 말"). 값이 없는 경우는 건너뛴다. 마지막 경우는 잠금 버튼을 누르고 앱을 더 건드리지 않는다.
final class DeviceBackgroundStartProbe: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("실기기 전용")
        #endif
    }
    /// S1: 재생 → 일시정지 → 앱 종료 → 다시 열기 → 처음 듣는 곡 탭 → 바로 홈.
    @MainActor func test1PauseRelaunchThenHome() throws {
        try pauseRelaunchThenLeave(first: query("SWAY_PROBE_S1_FIRST"), second: query("SWAY_PROBE_S1_SECOND"), lock: false, tag: "S1")
    }
    /// S2: YouTube가 NowPlaying인 상태에서 처음 듣는 곡 탭 → 바로 홈.
    @MainActor func test2OtherAppNowPlayingThenHome() throws {
        let track = try query("SWAY_PROBE_S2")
        mark("S2 begin")
        let youtube = XCUIApplication(bundleIdentifier: "com.google.ios.youtube")
        youtube.open(URL(string: "https://www.youtube.com/watch?v=YE7VzlLtp-4")!); mark("youtube opened")
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        // 재생 중인 채로 나가면 화면 속 화면으로 계속 재생돼 Sway 검색창을 가린다(2026-10-28 1회차). 멈춘 뒤 나간다.
        guard pauseYouTube(youtube) else { XCTFail("YouTube 영상을 멈추지 못했다"); youtube.terminate(); return }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let app = XCUIApplication(); app.launch(); mark("launched")
        tapResult(app, track)
        leave(app, lock: false)
    }
    /// S3: S1과 같은 순서를 홈 대신 잠금 버튼으로. 잠긴 뒤에는 앱을 건드리지 않는다.
    @MainActor func test3PauseRelaunchThenLock() throws {
        // 앞 경우가 실패해 YouTube가 화면 속 화면으로 남아 있으면 검색창을 가린다.
        XCUIApplication(bundleIdentifier: "com.google.ios.youtube").terminate()
        try pauseRelaunchThenLeave(first: query("SWAY_PROBE_S3_FIRST"), second: query("SWAY_PROBE_S3_SECOND"), lock: true, tag: "S3")
    }
    /// S2′(2026-10-30): 멜론에서 곡을 틀었다가 앱 안에서 멈추고 홈으로 나간 뒤(멈춰도 NowPlaying을 유지하는 앱),
    /// 처음 듣는 곡 탭 → 바로 홈. S2의 YouTube는 뒤로 가며 스스로 NowPlaying을 내놓아 조건이 재현되지 않았고,
    /// 결제하지 않은 Spotify는 재생목록 화면에서 재생 버튼을 찾지 못했다(같은 날 1회차).
    @MainActor func test4OtherAppPausedThenHome() throws {
        let track = try query("SWAY_PROBE_S2P")
        mark("S2P begin")
        // 모바일 에이전트 앱이 떠 있으면 자동화 연결을 잡을 수 있다(2026-10-30 build 146부터 열 때 연결).
        XCUIApplication(bundleIdentifier: "com.tinkerer0.iphoneprobe").terminate()
        guard playThenPauseMelon() else { XCTFail("멜론을 틀고 멈추지 못했다"); return }
        let app = XCUIApplication(); app.launch(); mark("launched")
        tapResult(app, track)
        leave(app, lock: false)
    }
    /// 미니 플레이어의 '재생'을 눌러 '일시정지'로 바뀌면 재생된 것으로 보고, 6초 뒤 멈춘다.
    @MainActor private func playThenPauseMelon() -> Bool {
        let melon = XCUIApplication(bundleIdentifier: "com.iloen.iphonemelon")
        melon.activate(); mark("melon activated")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        // 실행 때 안내 창('Melon' 아이콘을 변경했습니다)이나 광고 창('오늘 하루 보지 않기'·'닫기')이 미니 플레이어를 가린다.
        // 광고 창을 닫지 않고 누른 2회차에는 재생되지 않았다(2026-10-30 로그에 멜론 재생 줄 없음).
        for label in ["확인", "닫기"] where melon.alerts.buttons[label].exists { melon.alerts.buttons[label].tap(); mark("melon dismissed alert \(label)") }
        if melon.buttons["닫기"].exists { melon.buttons["닫기"].tap(); mark("melon dismissed popup") }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let pause = melon.buttons.matching(NSPredicate(format: "label IN %@", ["일시정지", "일시 정지", "Pause"])).firstMatch
        let play = melon.buttons.matching(NSPredicate(format: "label IN %@", ["재생", "Play"])).firstMatch
        if !pause.exists {
            guard play.exists else { mark("melon buttons \(melon.buttons.allElementsBoundByIndex.prefix(60).map(\.label))"); return false }
            play.tap(); mark("melon play")
        }
        guard pause.waitForExistence(timeout: 10) else { mark("melon buttons \(melon.buttons.allElementsBoundByIndex.prefix(60).map(\.label))"); return false }
        mark("melon playing")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        pause.tap(); mark("melon paused")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        goHome(melon, "home after melon")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        return true
    }
    /// S4: 재생 → 일시정지 → 홈(일시정지한 채 뒤로 가면 refreshIdleSession이 세션을 끈다) → 돌아와 처음 듣는 곡 탭 → 바로 홈.
    @MainActor func test5PauseHomeReturnThenHome() throws {
        let first = try query("SWAY_PROBE_S4_FIRST"), second = try query("SWAY_PROBE_S4_SECOND")
        mark("S4 begin")
        let app = XCUIApplication(); app.launch(); mark("launched")
        playThenPause(app, first)
        goHome(app, "home after pause")
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        app.activate(); mark("returned")
        app.buttons["닫기"].tap()
        tapResult(app, second)
        leave(app, lock: false)
    }
    @MainActor private func pauseRelaunchThenLeave(first: (text: String, match: String), second: (text: String, match: String), lock: Bool, tag: String) {
        mark("\(tag) begin")
        let app = XCUIApplication(); app.launch(); mark("launched")
        playThenPause(app, first)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate(); mark("terminated")
        app.launch(); mark("relaunched")
        tapResult(app, second)
        leave(app, lock: lock)
    }
    /// 곡을 눌러 3초 이상 들린 뒤 재생 화면에서 멈춘다. 재생 화면은 열어 둔 채로 끝난다.
    @MainActor private func playThenPause(_ app: XCUIApplication, _ track: (text: String, match: String)) {
        tapResult(app, track)
        openPlayer(app)
        let audible = NSPredicate { _, _ in (self.seconds(app) ?? 0) >= 3 }
        expectation(for: audible, evaluatedWith: nil); waitForExpectations(timeout: 60)
        app.buttons["playerPlayPause"].tap(); mark("paused")
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "재생")
    }
    @MainActor private func pauseYouTube(_ youtube: XCUIApplication) -> Bool {
        let pause = youtube.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS[c] %@", "일시중지", "일시정지", "pause")).firstMatch
        // 조작 버튼은 몇 초 뒤 저절로 숨어서 요소를 다시 찾는 tap()은 실패한다(2026-10-28 2회차). 찾은 순간의 위치를 좌표로
        // 누르고, 잠시 뒤 일시중지 버튼이 사라졌으면 멈춘 것으로 본다. 숨은 사이에 눌렀다면 버튼이 다시 보여 한 번 더 누른다.
        for _ in 0..<5 {
            // 가운데는 재생 버튼 자리라 비켜서 눌러 조작 버튼만 띄운다.
            if !pause.exists { youtube.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.17)).tap() }
            guard pause.waitForExistence(timeout: 1.5), let frame = try? pause.snapshot().frame else { continue }
            youtube.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            mark("youtube tapped pause at \(frame)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if !pause.exists { mark("youtube paused"); return true }
        }
        mark("youtube buttons \(youtube.buttons.allElementsBoundByIndex.prefix(40).map(\.label))")
        return false
    }
    @MainActor private func query(_ key: String) throws -> (text: String, match: String) {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { throw XCTSkip("\(key) 없음") }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : parts[0])
    }
    private func mark(_ event: String) { NSLog("SwayProbe %@", event) }
    /// 홈 버튼 신호가 시간 초과로 버려져 앱이 화면 앞에 남는 일이 있었다(2026-10-30 backboardd "Home … downEvent:0 phase:0x4
    /// timeout", 시험 프레임워크는 오류 없음). 실제로 뒤로 갔는지 확인하고, 아니면 홈 화면을 앞으로 불러 내린다.
    @MainActor private func goHome(_ target: XCUIApplication, _ event: String) {
        // 멈춘 앱은 곧 runningBackgroundSuspended가 되므로 화면 앞이 아닌지만 본다.
        func leftForeground(within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while target.state == .runningForeground && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return target.state != .runningForeground
        }
        XCUIDevice.shared.press(.home)
        if !leftForeground(within: 1.5) {
            mark("\(event): still foreground after home press")
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
            _ = leftForeground(within: 3)
        }
        mark("\(event) state \(target.state.rawValue)")
    }
    @MainActor private func tapResult(_ app: XCUIApplication, _ query: (text: String, match: String)) {
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(query.text + "\n")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label ENDSWITH %@", query.match, ", 재생")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        mark("result \(result.label)")
        result.tap(); mark("tap")
    }
    @MainActor private func openPlayer(_ app: XCUIApplication) {
        let mini = app.buttons["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10)); mini.tap()
        XCTAssertTrue(app.staticTexts["elapsed"].waitForExistence(timeout: 5))
    }
    @MainActor private func seconds(_ app: XCUIApplication) -> Int? {
        let parts = app.staticTexts["elapsed"].label.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }
    /// 탭 직후 앱을 뒤로 보내고 40초 기다린다. 홈으로 보냈으면 돌아와 재생 상태를 읽고 멈춘다.
    @MainActor private func leave(_ app: XCUIApplication, lock: Bool) {
        if lock { _ = XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton")); mark("locked") }
        else { goHome(app, "home") }
        RunLoop.current.run(until: Date().addingTimeInterval(40))
        guard !lock else { mark("end while locked"); return }
        app.activate(); mark("activated")
        openPlayer(app)
        let state = app.buttons["playerPlayPause"].label, elapsed = seconds(app) ?? -1
        mark("state \(state) elapsed \(elapsed)")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "After background"; shot.lifetime = .keepAlways; add(shot)
        if state == "일시정지" { app.buttons["playerPlayPause"].tap(); mark("paused at end") }
        // 탭 뒤 10초 안에 소리가 났다면 40초 뒤 위치는 30초 근처다. 돌아온 뒤 새로 시작했다면 몇 초에 머문다.
        XCTAssertEqual(state, "일시정지")
        XCTAssertGreaterThanOrEqual(elapsed, 20)
    }
}
