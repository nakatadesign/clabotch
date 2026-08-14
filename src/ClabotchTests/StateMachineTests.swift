import XCTest
@testable import Clabotch

// MARK: - MascotPhaseDisplayPriorityTests（§12.3 displayPriority）

@MainActor
final class MascotPhaseDisplayPriorityTests: XCTestCase {

    func testDisplayPriorityOrder() {
        // error(0) < working(1) < responding(2) < thinking(3) < done(4) < idle(5) < sleeping(6)
        XCTAssertEqual(MascotPhase.error(toolName: "Bash", message: nil).displayPriority, 0)
        XCTAssertEqual(MascotPhase.working(toolName: "Read").displayPriority, 1)
        XCTAssertEqual(MascotPhase.responding.displayPriority, 2)
        XCTAssertEqual(MascotPhase.thinking.displayPriority, 3)
        XCTAssertEqual(MascotPhase.done(elapsedMs: 100).displayPriority, 4)
        XCTAssertEqual(MascotPhase.idle.displayPriority, 5)
        XCTAssertEqual(MascotPhase.sleeping.displayPriority, 6)
    }

    func testErrorHasHighestPriority() {
        let phases: [MascotPhase] = [
            .idle, .thinking, .working(toolName: "Read"),
            .done(elapsedMs: 0), .error(toolName: "Bash", message: nil), .sleeping
        ]
        let min = phases.min { $0.displayPriority < $1.displayPriority }
        XCTAssertEqual(min, .error(toolName: "Bash", message: nil))
    }

    func testIsDoneHelper() {
        XCTAssertTrue(MascotPhase.done(elapsedMs: 100).isDone)
        XCTAssertFalse(MascotPhase.thinking.isDone)
        XCTAssertFalse(MascotPhase.responding.isDone)
        XCTAssertFalse(MascotPhase.idle.isDone)
    }
}

// MARK: - StateMachineOwnershipTests（Ownership Guard → Multi-session、required 6）

@MainActor
final class StateMachineOwnershipTests: XCTestCase {

    // 1. session == nil で session_start → thinking に遷移
    func testSessionStartAcceptedWhenNoSession() {
        let sm = StateMachine()
        XCTAssertNil(sm.session)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 2. active session 中に同一 ID の session_start → no-op
    func testDuplicateSessionStartIsNoOp() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)

        // 同一 ID で再度 session_start → phase 変化なし
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 3. multi-session: 別 ID の session_start は受理される
    func testSecondSessionStartAccepted() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionStart(sessionID: "s2"))
        // 両方追跡されている
        XCTAssertEqual(sm.sessions.count, 2)
        // displayPhase は thinking（両方 thinking で同一）
        XCTAssertEqual(sm.displayPhase, .thinking)
        // 後方互換: session は先着（s1）を返す
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 4. active session 中に別 session_id の tool_start → 未追跡なので無視
    func testToolStartForUnknownSessionIgnored() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))

        sm.handle(event: .toolStart(sessionID: "s2", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 5. active session 中に別 session_id の tool_end → 未追跡なので無視
    func testToolEndForUnknownSessionIgnored() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))

        sm.handle(event: .toolEnd(sessionID: "s2", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 6. 未追跡セッションの session_done(ms==0) → 無視、ephemeral なし
    func testUnknownSessionDoneIgnored() {
        let sm = StateMachine()
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s2", elapsedMs: 0))

        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertNotNil(sm.session)
        XCTAssertEqual(ephemeralCount, 0)
    }
}

// MARK: - StateMachinePhaseTests（Phase 遷移、required 8）

@MainActor
final class StateMachinePhaseTests: XCTestCase {

    // 7. session_start → thinking + session 設定
    func testSessionStartSetsThinking() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertNotNil(sm.sessions["s1"])
        XCTAssertEqual(sm.sessions["s1"]?.phase, .thinking)
    }

    // 8. thinking → tool_start → working
    func testToolStartSetsWorking() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
        XCTAssertEqual(sm.sessions["s1"]?.phase, .working(toolName: "Read"))
    }

    // 9. working → tool_end(success) → thinking
    func testToolEndSuccessSetsThinking() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Read",
                                   durationMs: 50, isError: false, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 10. working → tool_end(error) → error
    func testToolEndErrorSetsError() {
        let sm = StateMachine(errorAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 200, isError: true, errorMessage: "失敗"))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: "失敗"))
    }

    // 11. thinking → session_done → done + session == nil（後方互換）
    func testSessionDoneSetsDone() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 3000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 3000))
        // session computed property は .done を除外するので nil
        XCTAssertNil(sm.session)
        // sessions dict には .done として残っている（遅延削除）
        XCTAssertEqual(sm.sessions["s1"]?.phase, .done(elapsedMs: 3000))
    }

    // 12. error → errorAutoTransitionDelay 後 → thinking
    func testErrorAutoTransitionToThinking() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: nil))

        let exp = expectation(description: "auto-transition to thinking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .thinking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 13. done → doneAutoTransitionDelay 後 → idle（セッション削除）
    func testDoneAutoTransitionToIdle() {
        let sm = StateMachine(doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 1000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 1000))

        let exp = expectation(description: "auto-transition to idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .idle)
            // セッション削除済み
            XCTAssertTrue(sm.sessions.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 14. unknown イベント → phase 変化なし
    func testUnknownEventIsNoOp() {
        let sm = StateMachine()
        sm.handle(event: .unknown(rawJSON: "{}"))
        XCTAssertEqual(sm.displayPhase, .idle)
        XCTAssertNil(sm.session)
    }
}

// MARK: - StateMachineRaceTests（Delayed Transition レース対策、required 4）

@MainActor
final class StateMachineRaceTests: XCTestCase {

    // 15. error 中に新しい tool_start → pending auto-transition が発火しない
    func testNewEventCancelsPendingTransition() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: nil))

        // error auto-transition が発火する前に tool_start で working に遷移
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))

        // 0.1秒後: auto-transition は cancel されているので thinking にならない
        let exp = expectation(description: "auto-transition cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 16. done 中に新しい session_start → done auto-transition が発火しない
    func testNewSessionCancelsDoneTransition() {
        let sm = StateMachine(doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 500))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 500))

        // done auto-transition が発火する前に新 session_start
        sm.handle(event: .sessionStart(sessionID: "s2"))
        XCTAssertEqual(sm.displayPhase, .thinking)

        // 0.1秒後: s1 の removal は発火しても s2 は残る
        let exp = expectation(description: "new session persists")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .thinking)
            XCTAssertEqual(sm.session?.sessionID, "s2")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 17. error → session_done → error auto-transition 無効、done → idle のみ発火
    func testSessionDoneCancelsPendingErrorTransition() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.15, doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: nil))

        // session_done で error auto-transition をキャンセルし、done を設定
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 200))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 200))

        // done removal（0.1秒）のみ発火 → idle
        let exp = expectation(description: "done auto-transition only")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(sm.displayPhase, .idle)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 18. error auto-transition 発火前に session_done + 新セッション → 旧 transition 無効
    func testPendingTransitionInvalidatedByEpoch() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1, doneAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))

        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 0))
        sm.handle(event: .sessionStart(sessionID: "s2"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s2")

        let exp = expectation(description: "epoch mismatch invalidates stale transition")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .thinking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - StateMachineSleepTests（Sleeping、required 4）

@MainActor
final class StateMachineSleepTests: XCTestCase {

    // 19. idle + sessions 空 → sleepThreshold 後 → sleeping
    func testSleepingFiresAfterThreshold() {
        let sm = StateMachine(sleepThreshold: 0.15)
        sm.start()
        XCTAssertEqual(sm.displayPhase, .idle)

        let exp = expectation(description: "sleeping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(sm.displayPhase, .sleeping)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 20. session 存在時は sleep タイマーが始動しない
    func testSleepingNotFiresWithActiveSession() {
        // フォールバック計算で elapsedMs が一貫するよう固定時刻を使用
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let sm = StateMachine(sleepThreshold: 0.1, doneAutoTransitionDelay: 10, now: { fixedDate })
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 0))
        // startedAt == currentDate（同一固定時刻）→ フォールバック計算 = 0ms
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 0))

        let exp = expectation(description: "not sleeping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // done のまま（セッション残留中なので sleep タイマー未始動）
            XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 0))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 21. sleeping 中に session_start → thinking に遷移
    func testSleepingCancelledBySessionStart() {
        let sm = StateMachine(sleepThreshold: 0.1)
        sm.start()

        let sleepExp = expectation(description: "sleeping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .sleeping)
            sleepExp.fulfill()
        }
        wait(for: [sleepExp], timeout: 1)

        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 22. done → session 削除 → idle → sleep タイマー再始動
    func testSleepTimerRestartsOnReturnToIdle() {
        let sm = StateMachine(sleepThreshold: 0.15, doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 100))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 100))

        // done → session 削除(0.1秒) → idle → sleeping(0.15秒)
        let exp = expectation(description: "sleep after idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(sm.displayPhase, .sleeping)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - StateMachineEphemeralTests（Ephemeral 通知、required 3）

@MainActor
final class StateMachineEphemeralTests: XCTestCase {

    // 23. 未追跡セッション session_done(ms > 0) → onEphemeralDone コールバック
    func testUnknownSessionDoneEphemeral() {
        let sm = StateMachine()
        var receivedMs: Int?
        sm.onEphemeralDone = { ms in receivedMs = ms }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s2", elapsedMs: 5000))

        XCTAssertEqual(receivedMs, 5000)
        // active session は変化なし
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 24. 未追跡セッション session_done(ms == 0) → silent drop
    func testUnknownSessionDoneZeroMsSilentDrop() {
        let sm = StateMachine()
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s2", elapsedMs: 0))

        XCTAssertEqual(ephemeralCount, 0)
    }

    // 25. active session_done → onEphemeralDone 呼ばれない（displayPhase が .done）
    func testActiveSessionDoneNoEphemeral() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 3000))

        XCTAssertEqual(ephemeralCount, 0)
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 3000))
    }
}

// MARK: - StateMachineCallbackTests（onPhaseChanged コールバック、required 2）

@MainActor
final class StateMachineCallbackTests: XCTestCase {

    // 26. 遷移時に onPhaseChanged が正しい phase で呼ばれる
    func testOnPhaseChangedCalledOnTransition() {
        let sm = StateMachine()
        var phases: [MascotPhase] = []
        sm.onPhaseChanged = { phase in phases.append(phase) }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))

        XCTAssertEqual(phases, [.thinking, .working(toolName: "Read")])
    }

    // 27. start() で onPhaseChanged が .idle で呼ばれる
    func testStartEmitsInitialPhase() {
        let sm = StateMachine(sleepThreshold: 10)
        var phases: [MascotPhase] = []
        sm.onPhaseChanged = { phase in phases.append(phase) }
        sm.start()
        XCTAssertEqual(phases, [.idle])
    }

    // 28. 同一 phase への遷移 → onPhaseChanged 呼ばれない
    func testOnPhaseChangedNotCalledForSamePhase() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))

        var callCount = 0
        sm.onPhaseChanged = { _ in callCount += 1 }

        // thinking → tool_end(success) → thinking: 同じ phase なので呼ばれない
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Read",
                                   durationMs: 50, isError: false, errorMessage: nil))

        XCTAssertEqual(callCount, 0)
    }
}

// MARK: - StateMachineMultiSessionTests（複数セッション並列追跡、計画 014）

@MainActor
final class StateMachineMultiSessionTests: XCTestCase {

    // MS-1. 2 セッション: A=thinking, B=working → displayPhase = .working
    func testTwoSessionsDisplayPriorityWorking() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionStart(sessionID: "b"))
        sm.handle(event: .toolStart(sessionID: "b", toolName: "Bash"))

        XCTAssertEqual(sm.sessions["a"]?.phase, .thinking)
        XCTAssertEqual(sm.sessions["b"]?.phase, .working(toolName: "Bash"))
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Bash"))
    }

    // MS-2. 2 セッション: A=error, B=working → displayPhase = .error
    func testTwoSessionsDisplayPriorityError() {
        let sm = StateMachine(errorAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionStart(sessionID: "b"))
        sm.handle(event: .toolStart(sessionID: "b", toolName: "Read"))
        sm.handle(event: .toolEnd(sessionID: "a", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: "oops"))

        XCTAssertEqual(sm.sessions["a"]?.phase, .error(toolName: "Bash", message: "oops"))
        XCTAssertEqual(sm.sessions["b"]?.phase, .working(toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: "oops"))
    }

    // MS-3. セッション A done → B のフェーズが displayPhase に
    func testSessionDoneRevealsOtherSession() {
        let sm = StateMachine(doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionStart(sessionID: "b"))
        sm.handle(event: .toolStart(sessionID: "b", toolName: "Read"))
        // a=thinking(2), b=working(1) → displayPhase = working
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))

        sm.handle(event: .sessionDone(sessionID: "b", elapsedMs: 500))
        // b=done(3), a=thinking(2) → displayPhase = thinking
        XCTAssertEqual(sm.displayPhase, .thinking)
        // session（.done 除外）は a
        XCTAssertEqual(sm.session?.sessionID, "a")
    }

    // MS-4. 全セッション done → idle（遅延後）
    func testAllSessionsDoneThenIdle() {
        let sm = StateMachine(doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionStart(sessionID: "b"))
        sm.handle(event: .sessionDone(sessionID: "a", elapsedMs: 100))
        sm.handle(event: .sessionDone(sessionID: "b", elapsedMs: 200))
        // 両方 done → displayPhase = done（先に完了した a or b の done）
        XCTAssertTrue(sm.displayPhase.isDone)
        XCTAssertNil(sm.session)

        let exp = expectation(description: "all sessions removed → idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .idle)
            XCTAssertTrue(sm.sessions.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MS-5. 全セッション done → idle → sleep
    func testAllSessionsDoneThenSleep() {
        let sm = StateMachine(sleepThreshold: 0.15, doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionDone(sessionID: "a", elapsedMs: 100))

        let exp = expectation(description: "done → idle → sleep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(sm.displayPhase, .sleeping)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MS-6. 非プライマリセッション done → ephemeral 通知
    func testNonPrimarySessionDoneFiresEphemeral() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        var receivedMs: Int?
        sm.onEphemeralDone = { ms in receivedMs = ms }

        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionStart(sessionID: "b"))
        sm.handle(event: .toolStart(sessionID: "a", toolName: "Read"))
        // a=working(1), b=thinking(2) → displayPhase = working

        sm.handle(event: .sessionDone(sessionID: "b", elapsedMs: 3000))
        // b=done(3), a=working(1) → displayPhase = working（.done ではない）
        // → ephemeral 通知
        XCTAssertEqual(receivedMs, 3000)
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
    }

    // MS-7. プライマリセッション done → ephemeral 通知なし
    func testPrimarySessionDoneNoEphemeral() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "a"))
        // a=thinking → displayPhase = thinking

        sm.handle(event: .sessionDone(sessionID: "a", elapsedMs: 5000))
        // a=done → displayPhase = done → ephemeral なし
        XCTAssertEqual(ephemeralCount, 0)
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 5000))
    }

    // MS-7b. 先行セッションの done が表示中でも後発 done は ephemeral 通知される（patch_022）
    // 旧実装は displayPhase.isDone で判定していたため、別セッションの done 表示中に
    // 完了した後発セッションの通知が取りこぼされていた。
    func testLaterDoneBehindEarlierDoneFiresEphemeral() {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let sm = StateMachine(doneAutoTransitionDelay: 10, now: { currentTime })
        var ephemeralMs: [Int] = []
        sm.onEphemeralDone = { ephemeralMs.append($0) }

        sm.handle(event: .sessionStart(sessionID: "a"))
        currentTime = Date(timeIntervalSince1970: 1_001)
        sm.handle(event: .sessionStart(sessionID: "b"))

        // a done: b=thinking がプライマリ → a は非プライマリ → ephemeral
        sm.handle(event: .sessionDone(sessionID: "a", elapsedMs: 1000))
        XCTAssertEqual(ephemeralMs, [1000])

        // b done: 両方 done、startedAt が早い a がプライマリ表示（displayPhase.isDone）
        // → 後発の b は表示されないが ephemeral で通知される
        sm.handle(event: .sessionDone(sessionID: "b", elapsedMs: 2000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 1000))
        XCTAssertEqual(ephemeralMs, [1000, 2000])
    }

    // MS-7c. displayPriority と startedAt が完全同率のときは sessionID で決定的に選ぶ（patch_022）
    func testPrimaryTieBreaksBySessionID() {
        let fixed = Date(timeIntervalSince1970: 3_000)
        let sm = StateMachine(doneAutoTransitionDelay: 10, now: { fixed })
        var ephemeralMs: [Int] = []
        sm.onEphemeralDone = { ephemeralMs.append($0) }

        sm.handle(event: .sessionStart(sessionID: "b"))
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionDone(sessionID: "a", elapsedMs: 1000))
        sm.handle(event: .sessionDone(sessionID: "b", elapsedMs: 2000))

        // 両セッション同時刻 startedAt・両方 done → sessionID 昇順で "a" がプライマリ表示
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 1000))
        // a done 時: b=thinking がプライマリ → ephemeral(1000)
        // b done 時: a がプライマリ（タイブレーク）→ ephemeral(2000)
        XCTAssertEqual(ephemeralMs, [1000, 2000])
    }

    // MS-8. セッション A の error auto-transition は B のイベントに影響されない
    func testPerSessionEpochIsolation() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionStart(sessionID: "b"))
        sm.handle(event: .toolEnd(sessionID: "a", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        // a=error(0), b=thinking(2) → displayPhase = error
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: nil))

        // b に新しいイベント → a の pending transition に影響しない
        sm.handle(event: .toolStart(sessionID: "b", toolName: "Read"))
        XCTAssertEqual(sm.sessions["b"]?.phase, .working(toolName: "Read"))

        // 0.1秒後: a の error→thinking auto-transition が発火する
        let exp = expectation(description: "a の auto-transition は b に影響されない")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.sessions["a"]?.phase, .thinking)
            // a=thinking(2), b=working(1) → displayPhase = working
            XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MS-9. sessions.count と displayPhase の整合性
    func testSessionsCountConsistency() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        XCTAssertTrue(sm.sessions.isEmpty)
        XCTAssertEqual(sm.displayPhase, .idle)

        sm.handle(event: .sessionStart(sessionID: "a"))
        XCTAssertEqual(sm.sessions.count, 1)

        sm.handle(event: .sessionStart(sessionID: "b"))
        XCTAssertEqual(sm.sessions.count, 2)

        sm.handle(event: .sessionStart(sessionID: "c"))
        XCTAssertEqual(sm.sessions.count, 3)

        sm.handle(event: .sessionDone(sessionID: "b", elapsedMs: 0))
        XCTAssertEqual(sm.sessions.count, 3) // done セッションは遅延削除で残留
        XCTAssertEqual(sm.displayPhase, .thinking) // a,c が thinking
    }

    // MS-10. done セッションへの late tool イベントは無視される
    func testLateToolEventsIgnoredForDoneSession() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionDone(sessionID: "a", elapsedMs: 1000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 1000))

        // done 後に tool_start → 無視
        sm.handle(event: .toolStart(sessionID: "a", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 1000))
        XCTAssertEqual(sm.sessions["a"]?.phase, .done(elapsedMs: 1000))

        // done 後に tool_end → 無視
        sm.handle(event: .toolEnd(sessionID: "a", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: "err"))
        XCTAssertEqual(sm.sessions["a"]?.phase, .done(elapsedMs: 1000))
    }

    // MS-11. 同一 priority の 2 セッション → 先着のフェーズが displayPhase
    func testEqualPriorityDeterministicSelection() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        var tick = 0
        let sm = StateMachine(now: {
            tick += 1
            return fixedDate.addingTimeInterval(Double(tick))
        })
        sm.handle(event: .sessionStart(sessionID: "a"))  // startedAt = 1001
        sm.handle(event: .sessionStart(sessionID: "b"))  // startedAt = 1002
        sm.handle(event: .toolStart(sessionID: "a", toolName: "Read"))
        sm.handle(event: .toolStart(sessionID: "b", toolName: "Bash"))
        // 両方 working(1) → 先着(a) の "Read" が displayPhase
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
    }

    // MS-13. 新セッション開始で sleep タイマーキャンセル
    func testNewSessionCancelsSleepTimer() {
        let sm = StateMachine(sleepThreshold: 0.1)
        sm.start()
        XCTAssertEqual(sm.displayPhase, .idle)

        // sleep 発火前にセッション開始
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sm.handle(event: .sessionStart(sessionID: "a"))
        }

        let exp = expectation(description: "sleep タイマーがキャンセルされる")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .thinking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - StateMachineElapsedFallbackTests（経過時間フォールバック計算）

@MainActor
final class StateMachineElapsedFallbackTests: XCTestCase {

    // EF-1. Hook が elapsed_ms > 0 を提供 → そのまま使用
    func testHookElapsedMsUsedWhenPositive() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 5000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 5000))
    }

    // EF-2. Hook が elapsed_ms == 0、追跡済みセッション → startedAt からフォールバック計算
    func testFallbackElapsedFromStartedAt() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        var tick = 0
        let sm = StateMachine(doneAutoTransitionDelay: 10, now: {
            defer { tick += 1 }
            // tick 0: session_start → startedAt = 1000
            // tick 1: sessionDone  → currentDate = 1060（60秒後）
            return fixedDate.addingTimeInterval(Double(tick) * 60)
        })
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 0))

        // startedAt=1000, currentDate=1060 → 60秒 = 60000ms
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 60000))
    }

    // EF-3. フォールバック計算が ephemeral 通知にも反映される
    func testFallbackElapsedFiresEphemeral() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        var tick = 0
        let sm = StateMachine(doneAutoTransitionDelay: 10, now: {
            defer { tick += 1 }
            return fixedDate.addingTimeInterval(Double(tick) * 30)
        })
        var receivedMs: Int?
        sm.onEphemeralDone = { ms in receivedMs = ms }

        sm.handle(event: .sessionStart(sessionID: "a"))  // tick 0: t=1000
        sm.handle(event: .sessionStart(sessionID: "b"))  // tick 1: t=1030
        sm.handle(event: .toolStart(sessionID: "a", toolName: "Bash"))  // tick 2: t=1060

        // b は thinking(2), a は working(1) → displayPhase = .working
        // b を done(0) → 非プライマリ + フォールバック計算
        sm.handle(event: .sessionDone(sessionID: "b", elapsedMs: 0))  // tick 3: t=1090

        // b.startedAt = 1030, currentDate = 1090 → 60秒 = 60000ms
        XCTAssertEqual(receivedMs, 60000)
    }

    // EF-4. 未追跡セッションの elapsedMs==0 → フォールバックなし（silent drop）
    func testUntrackedSessionZeroMsNoFallback() {
        let sm = StateMachine()
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "unknown", elapsedMs: 0))

        XCTAssertEqual(ephemeralCount, 0)
    }

    // EF-5. Hook 値が優先される（Hook > 0 かつ startedAt からの計算値と異なる場合）
    func testHookValueTakesPrecedenceOverFallback() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        var tick = 0
        let sm = StateMachine(doneAutoTransitionDelay: 10, now: {
            defer { tick += 1 }
            return fixedDate.addingTimeInterval(Double(tick) * 120)
        })
        sm.handle(event: .sessionStart(sessionID: "s1"))
        // Hook が 5000ms（5秒）を報告。startedAt からは 120秒。Hook 値を優先。
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 5000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 5000))
    }
}

// MARK: - StateMachineRespondingTests（.responding 遷移）

@MainActor
final class StateMachineRespondingTests: XCTestCase {

    // R-1. tool_end(success) 直後は .thinking
    func testToolEndSuccessIsThinkingImmediately() {
        let sm = StateMachine(respondingTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.sessions["s1"]?.phase, .thinking)
    }

    // R-2. 遅延経過後に .responding に遷移
    func testRespondingTransitionAfterDelay() {
        let sm = StateMachine(respondingTransitionDelay: 0.05)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))

        let exp = expectation(description: "responding transition")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(sm.displayPhase, .responding)
            XCTAssertEqual(sm.sessions["s1"]?.phase, .responding)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // R-3. 遅延経過前に tool_start が来たら .working → .responding にならない
    func testToolStartCancelsRespondingTransition() {
        let sm = StateMachine(respondingTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))

        // 遅延前に tool_start
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))

        let exp = expectation(description: "responding not fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // R-4. 遅延経過前に session_done が来たら .done が優先
    func testSessionDoneCancelsRespondingTransition() {
        let sm = StateMachine(doneAutoTransitionDelay: 10, respondingTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))

        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 5000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 5000))

        let exp = expectation(description: "responding not fired after done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 5000))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // R-5. 複数セッションで displayPriority が正しく解決される
    func testRespondingDisplayPriorityWithMultipleSessions() {
        let sm = StateMachine(respondingTransitionDelay: 0.05)
        sm.handle(event: .sessionStart(sessionID: "a"))
        sm.handle(event: .sessionStart(sessionID: "b"))
        // a を responding にする
        sm.handle(event: .toolStart(sessionID: "a", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "a", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))

        let exp = expectation(description: "a becomes responding")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(sm.sessions["a"]?.phase, .responding)
            // a=responding(2), b=thinking(3) → displayPhase = responding
            XCTAssertEqual(sm.displayPhase, .responding)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // R-6. .responding のセッションに tool_start が来たら .working に戻る
    func testToolStartFromRespondingGoesToWorking() {
        let sm = StateMachine(respondingTransitionDelay: 0.05)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))

        let exp = expectation(description: "responding then working")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(sm.displayPhase, .responding)
            sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
            XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // R-7. session_start 後は .thinking のまま（.responding にはならない）
    func testSessionStartStaysThinking() {
        let sm = StateMachine(respondingTransitionDelay: 0.05)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)

        let exp = expectation(description: "stays thinking after session_start")
        exp.isInverted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if sm.displayPhase == .responding { exp.fulfill() }
        }
        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // R-8. tool_end(error) では .responding 遷移がスケジュールされない
    func testToolEndErrorDoesNotScheduleResponding() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1, respondingTransitionDelay: 0.05)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: "失敗"))

        // 即時は error
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: "失敗"))

        // 0.05秒後: responding にはならない（error auto-transition は 0.1秒後なのでまだ error）
        let exp = expectation(description: "no responding after error")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            // error のまま（responding にならない）
            XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: "失敗"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - セッションタイムアウトテスト

    // T-1. stale セッションがタイムアウト後に自動削除され idle に戻る
    func testStaleSessionAutoCleanup() {
        // タイムアウト 0.05秒、チェック間隔 0.03秒で高速テスト
        let sm = StateMachine(
            sessionTimeout: 0.05,
            sessionTimeoutCheckInterval: 0.03
        )
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.sessions.count, 1)

        let exp = expectation(description: "stale session cleaned up")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(sm.sessions.count, 0)
            XCTAssertEqual(sm.displayPhase, .idle)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // T-2. アクティブなセッション（lastEventAt が新しい）は削除されない
    func testActiveSessionNotCleaned() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let sm = StateMachine(
            sessionTimeout: 0.1,
            sessionTimeoutCheckInterval: 0.03,
            now: { currentTime }
        )
        sm.handle(event: .sessionStart(sessionID: "s1"))

        // タイムアウト前にイベントを送り続ける
        let exp = expectation(description: "active session survives")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            currentTime = Date()  // now() を現在時刻に更新
            sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // セッションはまだ生存（最後のイベントから 0.1秒経っていない）
            XCTAssertEqual(sm.sessions.count, 1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // T-3. 複数セッションで stale な方だけ削除される
    func testStaleSessionCleanupRevealsOtherSession() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let sm = StateMachine(
            sessionTimeout: 0.08,
            sessionTimeoutCheckInterval: 0.03,
            now: { currentTime }
        )

        // s1 を開始（古い lastEventAt）
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))

        // s2 を少し後に開始
        currentTime = currentTime.addingTimeInterval(0.05)
        sm.handle(event: .sessionStart(sessionID: "s2"))
        sm.handle(event: .toolStart(sessionID: "s2", toolName: "Read"))

        XCTAssertEqual(sm.sessions.count, 2)

        // now() を s1 がタイムアウトするが s2 はまだ生存する時刻に設定
        let exp = expectation(description: "only stale session removed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            currentTime = Date(timeIntervalSince1970: 1000.1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(sm.sessions.count, 1)
            XCTAssertNotNil(sm.sessions["s2"])
            XCTAssertNil(sm.sessions["s1"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // T-4. sessionTimeout が .infinity のときはタイマーが開始されない
    func testInfiniteSessionTimeoutDisablesTimer() {
        let sm = StateMachine(sessionTimeout: .infinity)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.sessions.count, 1)

        let exp = expectation(description: "session persists with infinite timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(sm.sessions.count, 1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // T-5. updateSessionTimeout で動的にタイムアウトを変更できる
    func testUpdateSessionTimeout() {
        let sm = StateMachine(
            sessionTimeout: .infinity,
            sessionTimeoutCheckInterval: 0.03
        )
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.sessions.count, 1)

        // タイムアウトを短く変更
        sm.updateSessionTimeout(0.05)

        let exp = expectation(description: "session cleaned up after timeout update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(sm.sessions.count, 0)
            XCTAssertEqual(sm.displayPhase, .idle)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
