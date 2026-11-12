import XCTest

/// 오래 재생·연속 넘기기 안정성 시험. 실제 네트워크로 오래 돌아서 환경 변수가 없으면 건너뛴다.
/// 예: TEST_RUNNER_SWAY_SOAK_MINUTES=60 TEST_RUNNER_SWAY_CACHE_LIMIT_MB=20 xcodebuild test ...
///     -only-testing:SwayUITests/SwayStabilityTests/testLongAlgorithmPlayback
/// 표본 줄(SOAK/SKIP)은 xcodebuild 출력에 남아 밖에서 메모리·로그와 시각을 맞춰 본다.
final class SwayStabilityTests: XCTestCase {
    private struct Sample { let title: String; let seconds: Int; let state: String }

    private func setting(_ key: String) throws -> Double {
        guard let value = ProcessInfo.processInfo.environment[key].flatMap(Double.init) else { throw XCTSkip("\(key) 없음") }
        return value
    }

    /// 검색한 곡으로 알고리즘을 켜고 전체 플레이어를 연다.
    @MainActor private func startAlgorithm(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reset-fixture"] + extra; app.launch()
        let scope = app.buttons["searchScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5)); scope.tap(); app.buttons["searchMode-music"].tap()
        let field = app.textFields["searchField"]; field.tap(); field.typeText("아이유 밤편지\n")
        let song = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Through the Night (밤편지),", "재생")).firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 30)); song.tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5)); app.buttons["miniPlayer"].tap()
        app.buttons["mixToggle"].tap()
        let on = app.buttons["알고리즘 끄기"]
        XCTAssertTrue(on.waitForExistence(timeout: 40))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: on); waitForExpectations(timeout: 40)
        return app
    }

    @MainActor private func sample(_ app: XCUIApplication) -> Sample {
        let parts = app.staticTexts["elapsed"].label.split(separator: ":").compactMap { Int($0) }
        let button = app.buttons["playerPlayPause"]
        let state = button.label == "재생" ? "paused" : (button.value as? String) == "로딩 중" ? "loading" : "playing"
        return Sample(title: app.staticTexts["playerTitle"].label, seconds: parts.count == 2 ? parts[0] * 60 + parts[1] : -1, state: state)
    }

    /// 알고리즘으로 정해진 시간 동안 이어 듣는다. 10초마다 위치를 보고 20초 이상 멈춘 구간·예상 못 한 일시정지를 센다.
    @MainActor func testLongAlgorithmPlayback() throws {
        let minutes = try setting("SWAY_SOAK_MINUTES")
        let limit = ProcessInfo.processInfo.environment["SWAY_CACHE_LIMIT_MB"].map { ["--audio-cache-limit-mb", $0] } ?? []
        let app = startAlgorithm(limit)
        let started = Date(), end = started.addingTimeInterval(minutes * 60)
        var last = sample(app), frozen = 0, longestFrozen = 0, stalls = 0, pauses = 0, changes = 0
        print("SOAK start title=\(last.title) sec=\(last.seconds) state=\(last.state)")
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(10))
            guard app.state == .runningForeground else { XCTFail("앱이 실행 중이 아님: \(app.state.rawValue)"); break }
            let now = sample(app)
            if now.title != last.title { changes += 1 }
            if now.title == last.title && now.seconds == last.seconds && now.state != "paused" {
                frozen += 10; longestFrozen = max(longestFrozen, frozen); if frozen == 20 { stalls += 1 }
            } else { frozen = 0 }
            print("SOAK t=\(Int(Date().timeIntervalSince(started))) title=\(now.title) sec=\(now.seconds) state=\(now.state) frozen=\(frozen)")
            if now.state == "paused" {
                // 사용자가 누르지 않았는데 멈췄다. 기록하고 다시 재생해 남은 시간도 시험한다.
                pauses += 1; app.buttons["playerPlayPause"].tap()
            }
            last = now
        }
        print("SOAK summary minutes=\(minutes) changes=\(changes) stalls=\(stalls) longestFrozen=\(longestFrozen) pauses=\(pauses)")
        // 밖에서 메모리 누수 검사를 돌릴 수 있게 재생을 유지한 채 잠시 기다린다.
        print("SOAK HOLD"); RunLoop.current.run(until: Date().addingTimeInterval(90))
        XCTAssertEqual(stalls, 0, "20초 이상 멈춘 구간"); XCTAssertEqual(pauses, 0, "예상 못 한 일시정지")
        XCTAssertGreaterThanOrEqual(Double(changes), minutes / 8, "곡 전환 수")
    }

    /// 다음 곡을 빠르게(1.5초)와 천천히(6초) 번갈아 넘긴 뒤에도 재생이 이어지는지 본다.
    @MainActor func testRapidSkipsKeepPlaying() throws {
        let count = Int(try setting("SWAY_SKIP_COUNT"))
        let app = startAlgorithm()
        var pauses = 0
        for index in 0..<count {
            app.buttons["playerNext"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(index % 2 == 0 ? 1.5 : 6))
            guard app.state == .runningForeground else { XCTFail("앱이 실행 중이 아님: \(app.state.rawValue)"); return }
            let now = sample(app)
            print("SKIP i=\(index) title=\(now.title) sec=\(now.seconds) state=\(now.state)")
            if now.state == "paused" { pauses += 1; app.buttons["playerPlayPause"].tap() }
        }
        let before = sample(app)
        let advances = NSPredicate { _, _ in
            let now = self.sample(app); return now.state == "playing" && (now.title != before.title || now.seconds >= before.seconds + 5)
        }
        expectation(for: advances, evaluatedWith: nil); waitForExpectations(timeout: 30)
        print("SKIP summary count=\(count) pauses=\(pauses)")
        print("SKIP HOLD"); RunLoop.current.run(until: Date().addingTimeInterval(60))
        XCTAssertEqual(pauses, 0, "예상 못 한 일시정지")
    }
}
