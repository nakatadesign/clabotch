import AppKit
import Foundation
import os.log

/// StateMachine → 下流コンポーネントの結線を担当する Coordinator。
/// AppDelegate から抽出し、自動テストで結線パスを直接検証可能にする。
final class CoordinatorBinder {
    let stateMachine: StateMachine
    let gazeController: GazeController
    let blinkController: BlinkController
    weak var eyeView: ClabotchEyeView?
    let activeBubble: BubblePresenting
    let ephemeralBubble: BubblePresenting
    var anchorProvider: () -> CGPoint?
    /// AX 権限変化時の追加通知（設定画面のステータス更新など）。
    var onAccessibilityStatusChanged: ((GazePermissionStatus) -> Void)?
    /// 完了通知音の有効判定（patch_021）。AppDelegate が SettingsStore を結線する。
    var isCompletionSoundEnabled: () -> Bool = { false }
    /// 完了通知音のサウンド名（patch_021）。AppDelegate が SettingsStore を結線する。
    var completionSoundName: () -> String = { SettingsStore.defaultCompletionSoundName }
    /// 完了通知音の再生（patch_021）。テストでは spy に差し替える。
    var playCompletionSound: (String) -> Void = { name in
        NSSound(named: name)?.play()
    }

    init(
        stateMachine: StateMachine,
        gazeController: GazeController,
        blinkController: BlinkController,
        eyeView: ClabotchEyeView?,
        activeBubble: BubblePresenting,
        ephemeralBubble: BubblePresenting,
        anchorProvider: @escaping () -> CGPoint?
    ) {
        self.stateMachine = stateMachine
        self.gazeController = gazeController
        self.blinkController = blinkController
        self.eyeView = eyeView
        self.activeBubble = activeBubble
        self.ephemeralBubble = ephemeralBubble
        self.anchorProvider = anchorProvider
    }

    /// StateMachine の callback を設定する。AppDelegate.applicationDidFinishLaunching から呼ばれる。
    func bind() {
        // GazeController → ClabotchEyeView
        gazeController.onGazeFrameChanged = { [weak self] frame in
            self?.eyeView?.setGazeFrame(frame)
        }

        // BlinkController → ClabotchEyeView
        blinkController.onBlink = { [weak self] in
            self?.eyeView?.triggerBlink()
        }

        // StateMachine → Coordinator fan-out
        stateMachine.onPhaseChanged = { [weak self] phase in
            guard let self else { return }
            os_log(.default, "👀 CoordinatorBinder: フェーズ変更 → %{public}@", phase.debugName)

            let override = Self.gazeOverride(for: phase)
            self.gazeController.setOverride(override)

            // thinking/working/responding 遷移時にターミナル方向へ一時注視（patch_015）
            if case .thinking = phase { self.gazeController.lookAtTerminal() }
            if case .responding = phase { self.gazeController.lookAtTerminal() }
            if case .working = phase { self.gazeController.lookAtTerminal() }

            let blinkEnabled = Self.isBlinkEnabled(for: phase)
            self.blinkController.setBlinking(enabled: blinkEnabled)

            self.eyeView?.setPhaseAppearance(phase: phase)

            // §5: DONE 時にジャンプアニメーション（DONE スピンとは独立して動作）
            if case .done = phase {
                self.eyeView?.performJump()
                // patch_021: 設定で有効な場合のみ完了通知音を再生
                if self.isCompletionSoundEnabled() {
                    self.playCompletionSound(self.completionSoundName())
                }
            }

            if let text = self.bubbleText(for: phase) {
                if let anchor = self.anchorProvider() {
                    self.activeBubble.show(text: text, anchor: anchor)
                }
            } else {
                self.activeBubble.dismiss()
            }
        }

        // セッション数変化時にバブルテキストを再評価（displayPhase 不変でも [+N] が変わる）
        stateMachine.onSessionCountChanged = { [weak self] _ in
            guard let self else { return }
            let phase = self.stateMachine.displayPhase
            if let text = self.bubbleText(for: phase) {
                if let anchor = self.anchorProvider() {
                    self.activeBubble.show(text: text, anchor: anchor)
                }
            }
            // idle/sleeping → bubbleText==nil → 既に dismiss 済みなので何もしない
        }

        // AX 権限変化時のフィードバック
        gazeController.onPermissionChanged = { [weak self] status in
            guard let self else { return }
            self.onAccessibilityStatusChanged?(status)
            guard status == .granted else { return }
            if let anchor = self.anchorProvider() {
                self.ephemeralBubble.show(text: L10n.bubbleAccessibilityEnabled, anchor: anchor, duration: 3.0)
            }
        }

        // ターミナルクリックで sleeping から復帰
        gazeController.onTerminalClicked = { [weak self] in
            self?.stateMachine.wakeFromSleep()
        }

        stateMachine.onEphemeralDone = { [weak self] elapsedMs in
            guard let self else { return }
            // patch_022: 非プライマリセッションの完了にも設定有効時は通知音を鳴らす
            if self.isCompletionSoundEnabled() {
                self.playCompletionSound(self.completionSoundName())
            }
            let text = Self.formatElapsedTime(elapsedMs)
            let display = L10n.bubbleForeignSessionDone(elapsedText: text)
            if var anchor = self.anchorProvider() {
                // activeBubble 表示中なら下にずらして重なりを回避
                if self.activeBubble.isShowing {
                    anchor.y -= Self.bubbleStackOffset
                }
                self.ephemeralBubble.show(text: display, anchor: anchor, duration: 2.0)
            }
        }
    }

    // MARK: - Phase → Override 変換（patch_017 準拠）

    static func gazeOverride(for phase: MascotPhase) -> GazeOverride {
        switch phase {
        case .idle:       return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true)   // softFixed
        case .thinking:   return .none
        case .responding: return .none
        case .working:    return .none
        case .done:       return .fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true)   // softFixed
        case .error:      return .fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false)     // hardFixed
        case .sleeping:   return .fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false)     // hardFixed
        }
    }

    // MARK: - Phase → Blink 変換（v11 §6 準拠）

    static func isBlinkEnabled(for phase: MascotPhase) -> Bool {
        switch phase {
        case .idle, .thinking, .responding, .working, .done: return true
        case .error, .sleeping:                               return false
        }
    }

    // MARK: - Phase → 吹き出し文言（v11 §6 準拠）

    /// 現在の displayPhase に対応する吹き出し文言を返す。
    /// 複数セッションがアクティブな場合、`[+N]` サフィックスで他セッション数を表示する。
    func bubbleText(for phase: MascotPhase) -> String? {
        let base: String?
        switch phase {
        case .thinking:
            base = nil
        case .responding:
            base = L10n.bubbleResponding
        case .working(let toolName):
            base = Self.workingText(for: toolName)
        case .done(let elapsedMs):
            if elapsedMs > 0 {
                base = L10n.bubbleDone(elapsedText: Self.formatElapsedTime(elapsedMs))
            } else {
                base = L10n.bubbleDone
            }
        case .error:
            base = L10n.bubbleError  // v11 §6 固定文言。詳細 error_message は v1.0+ (§13.6)
        case .idle, .sleeping:
            return nil
        }

        guard let text = base else { return nil }
        let otherCount = stateMachine.sessions.count - 1
        if otherCount > 0 {
            return "\(text) [+\(otherCount)]"
        }
        return text
    }

    // MARK: - 定数

    /// activeBubble 表示中に ephemeralBubble を下にずらすオフセット（ポイント）
    static let bubbleStackOffset: CGFloat = 30

    // MARK: - ヘルパー

    static func workingText(for toolName: String) -> String {
        L10n.workingText(for: toolName)
    }

    static func formatElapsedTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return L10n.elapsedTime(minutes: minutes, seconds: seconds)
    }
}
