@testable import Clabotch
import XCTest

/// CoordinatorBinder の変換メソッドのテスト。
/// Phase → GazeOverride / BlinkEnabled / BubbleText の対応表を検証する。
@MainActor
final class AppDelegateCoordinatorTests: XCTestCase {

    /// bubbleText テスト用: セッション 0 件の binder インスタンス
    private func makeBinderWithNoSessions() -> CoordinatorBinder {
        let sm = StateMachine()
        let gc = GazeController(axProvider: MockAXProvider(), workspaceProvider: MockWorkspaceProvider(), pollInterval: 1)
        let bc = BlinkController()
        return CoordinatorBinder(
            stateMachine: sm,
            gazeController: gc,
            blinkController: bc,
            eyeView: nil,
            activeBubble: BubbleSpy(),
            ephemeralBubble: BubbleSpy(),
            anchorProvider: { nil }
        )
    }

    // MARK: - gazeOverride(for:)

    func testGazeOverrideForIdleSoftFixed() {
        // patch_017: idle は softFixed（allowsAttentionOverride=true）
        let override = CoordinatorBinder.gazeOverride(for: .idle)
        XCTAssertEqual(override, .fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true))
    }

    func testGazeOverrideForThinkingNone() {
        let override = CoordinatorBinder.gazeOverride(for: .thinking)
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForWorkingNone() {
        let override = CoordinatorBinder.gazeOverride(for: .working(toolName: "Bash"))
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForDoneSoftFixed() {
        // patch_017: done は softFixed（allowsAttentionOverride=true）
        let override = CoordinatorBinder.gazeOverride(for: .done(elapsedMs: 1000))
        XCTAssertEqual(override, .fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true))
    }

    func testGazeOverrideForErrorHardFixed() {
        // patch_017: error は hardFixed（allowsAttentionOverride=false）
        let override = CoordinatorBinder.gazeOverride(for: .error(toolName: "test", message: "err"))
        XCTAssertEqual(override, .fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false))
    }

    func testGazeOverrideForRespondingNone() {
        let override = CoordinatorBinder.gazeOverride(for: .responding)
        XCTAssertEqual(override, .none)
    }

    func testGazeOverrideForSleepingHardFixed() {
        // patch_017: sleeping は hardFixed（allowsAttentionOverride=false）
        let override = CoordinatorBinder.gazeOverride(for: .sleeping)
        XCTAssertEqual(override, .fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false))
    }

    // MARK: - isBlinkEnabled(for:)

    func testIsBlinkEnabledMapping() {
        // 通常 phase → true
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .idle))
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .thinking))
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .responding))
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .working(toolName: "bash")))
        XCTAssertTrue(CoordinatorBinder.isBlinkEnabled(for: .done(elapsedMs: 1000)))

        // 停止 phase → false
        XCTAssertFalse(CoordinatorBinder.isBlinkEnabled(for: .error(toolName: "test", message: nil)))
        XCTAssertFalse(CoordinatorBinder.isBlinkEnabled(for: .sleeping))
    }

    // MARK: - bubbleText(for:) — セッション 0 件（サフィックスなし）

    func testBubbleTextThinking() {
        let binder = makeBinderWithNoSessions()
        XCTAssertNil(binder.bubbleText(for: .thinking))
    }

    func testBubbleTextDoneWithTime() {
        let binder = makeBinderWithNoSessions()
        XCTAssertEqual(
            binder.bubbleText(for: .done(elapsedMs: 222000)),
            L10n.bubbleDone(elapsedText: L10n.elapsedTime(minutes: 3, seconds: 42))
        )
    }

    func testBubbleTextDoneNoTime() {
        let binder = makeBinderWithNoSessions()
        XCTAssertEqual(binder.bubbleText(for: .done(elapsedMs: 0)), L10n.bubbleDone)
    }

    func testBubbleTextErrorFixedMessage() {
        let binder = makeBinderWithNoSessions()
        // v11 §6: error は固定文言。error_message は表示しない (§13.6)
        XCTAssertEqual(binder.bubbleText(for: .error(toolName: "Bash", message: "some detail")), L10n.bubbleError)
        XCTAssertEqual(binder.bubbleText(for: .error(toolName: "Bash", message: nil)), L10n.bubbleError)
    }

    func testBubbleTextResponding() {
        let binder = makeBinderWithNoSessions()
        XCTAssertEqual(binder.bubbleText(for: .responding), L10n.bubbleResponding)
    }

    func testBubbleTextWorking() {
        let binder = makeBinderWithNoSessions()
        // ツール別吹き出し文言（CoordinatorBinder.workingText が source of truth）
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Bash")), L10n.workingText(for: "Bash"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Read")), L10n.workingText(for: "Read"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Write")), L10n.workingText(for: "Write"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Edit")), L10n.workingText(for: "Edit"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Grep")), L10n.workingText(for: "Grep"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Glob")), L10n.workingText(for: "Glob"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "Agent")), L10n.workingText(for: "Agent"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "WebSearch")), L10n.workingText(for: "WebSearch"))
        XCTAssertEqual(binder.bubbleText(for: .working(toolName: "UnknownTool")), L10n.workingText(for: "UnknownTool"))
    }

    func testBubbleTextIdleNil() {
        let binder = makeBinderWithNoSessions()
        XCTAssertNil(binder.bubbleText(for: .idle))
        XCTAssertNil(binder.bubbleText(for: .sleeping))
    }

    // MARK: - debugName（MascotPhase extension）

    func testDebugNameIncludesAssociatedValues() {
        XCTAssertEqual(MascotPhase.idle.debugName, "idle")
        XCTAssertEqual(MascotPhase.thinking.debugName, "thinking")
        XCTAssertEqual(MascotPhase.responding.debugName, "responding")
        XCTAssertEqual(MascotPhase.working(toolName: "Bash").debugName, "working(Bash)")
        XCTAssertEqual(MascotPhase.done(elapsedMs: 99999).debugName, "done(99999ms)")
        XCTAssertEqual(MascotPhase.error(toolName: "Read", message: "err").debugName, "error(Read)")
        XCTAssertEqual(MascotPhase.sleeping.debugName, "sleeping")
    }

    func testDebugNameDoesNotLeakErrorMessage() {
        // error の debugName には toolName を含むが、error message は含まない
        let name = MascotPhase.error(toolName: "Bash", message: "token=abc123").debugName
        XCTAssertFalse(name.contains("token"))
        XCTAssertFalse(name.contains("abc123"))
        XCTAssertEqual(name, "error(Bash)")
    }

    // MARK: - formatElapsedTime

    func testFormatElapsedTime() {
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(222000), L10n.elapsedTime(minutes: 3, seconds: 42))
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(5000), L10n.elapsedTime(minutes: 0, seconds: 5))
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(60000), L10n.elapsedTime(minutes: 1, seconds: 0))
        XCTAssertEqual(CoordinatorBinder.formatElapsedTime(0), L10n.elapsedTime(minutes: 0, seconds: 0))
    }

    // MARK: - 完了通知音（patch_021）

    func testCompletionSoundPlayedOnDoneWhenEnabled() {
        let binder = makeBinderWithNoSessions()
        var playCount = 0
        binder.isCompletionSoundEnabled = { true }
        binder.playCompletionSound = { _ in playCount += 1 }
        binder.bind()

        binder.stateMachine.onPhaseChanged?(.done(elapsedMs: 1000))

        XCTAssertEqual(playCount, 1)
    }

    func testCompletionSoundUsesSelectedSoundName() {
        let binder = makeBinderWithNoSessions()
        var playedNames: [String] = []
        binder.isCompletionSoundEnabled = { true }
        binder.completionSoundName = { "Hero" }
        binder.playCompletionSound = { playedNames.append($0) }
        binder.bind()

        binder.stateMachine.onPhaseChanged?(.done(elapsedMs: 1000))

        XCTAssertEqual(playedNames, ["Hero"])
    }

    func testCompletionSoundDefaultNameIsGlass() {
        let binder = makeBinderWithNoSessions()
        // AppDelegate が結線しない場合のデフォルトは SettingsStore のデフォルトと一致
        XCTAssertEqual(binder.completionSoundName(), SettingsStore.defaultCompletionSoundName)
        XCTAssertEqual(SettingsStore.defaultCompletionSoundName, "Glass")
    }

    func testCompletionSoundNotPlayedWhenDisabled() {
        let binder = makeBinderWithNoSessions()
        var playCount = 0
        binder.isCompletionSoundEnabled = { false }
        binder.playCompletionSound = { _ in playCount += 1 }
        binder.bind()

        binder.stateMachine.onPhaseChanged?(.done(elapsedMs: 1000))

        XCTAssertEqual(playCount, 0)
    }

    func testCompletionSoundNotPlayedOnNonDonePhases() {
        let binder = makeBinderWithNoSessions()
        var playCount = 0
        binder.isCompletionSoundEnabled = { true }
        binder.playCompletionSound = { _ in playCount += 1 }
        binder.bind()

        binder.stateMachine.onPhaseChanged?(.idle)
        binder.stateMachine.onPhaseChanged?(.thinking)
        binder.stateMachine.onPhaseChanged?(.responding)
        binder.stateMachine.onPhaseChanged?(.working(toolName: "Bash"))
        binder.stateMachine.onPhaseChanged?(.error(toolName: "Bash", message: "err"))
        binder.stateMachine.onPhaseChanged?(.sleeping)

        XCTAssertEqual(playCount, 0)
    }

    // patch_022: 非プライマリセッションの完了（ephemeral done）でも通知音を鳴らす

    func testCompletionSoundPlayedOnEphemeralDoneWhenEnabled() {
        let binder = makeBinderWithNoSessions()
        var playCount = 0
        binder.isCompletionSoundEnabled = { true }
        binder.playCompletionSound = { _ in playCount += 1 }
        binder.bind()

        binder.stateMachine.onEphemeralDone?(3000)

        XCTAssertEqual(playCount, 1)
    }

    func testCompletionSoundNotPlayedOnEphemeralDoneWhenDisabled() {
        let binder = makeBinderWithNoSessions()
        var playCount = 0
        binder.isCompletionSoundEnabled = { false }
        binder.playCompletionSound = { _ in playCount += 1 }
        binder.bind()

        binder.stateMachine.onEphemeralDone?(3000)

        XCTAssertEqual(playCount, 0)
    }
}
