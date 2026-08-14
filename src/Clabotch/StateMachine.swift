import Foundation
import os.log

/// ClabotchEvent を受けて MascotPhase を遷移させるステートマシン。
/// main thread 専用。AppDelegate が所有するグローバル 1 インスタンス。
/// v0.3: 複数セッションを並列追跡し、displayPriority で表示フェーズを決定する。
final class StateMachine {

    // MARK: - 公開状態

    /// 全セッションの状態。セッション ID でキー。
    private(set) var sessions: [String: SessionState] = [:]

    /// 表示フェーズ。全セッションの中で最も優先度が高いフェーズ。
    /// セッションが空なら .idle。
    private(set) var displayPhase: MascotPhase = .idle

    /// 後方互換: 最も優先度が高いアクティブセッション（.done を除く）を返す。
    var session: SessionState? {
        sessions.values
            .filter { !$0.phase.isDone }
            .min { $0.phase.displayPriority < $1.phase.displayPriority
                   || ($0.phase.displayPriority == $1.phase.displayPriority
                       && $0.startedAt < $1.startedAt) }
    }

    /// 表示上のプライマリセッション。displayPriority 最小 → startedAt が早い方 →
    /// sessionID 昇順、の順で完全に決定的に選ぶ（Dictionary の列挙順に依存しない）。
    /// displayPhase はこのセッションの phase になる。
    private var primarySession: SessionState? {
        sessions.values.min { a, b in
            if a.phase.displayPriority != b.phase.displayPriority {
                return a.phase.displayPriority < b.phase.displayPriority
            }
            if a.startedAt != b.startedAt {
                return a.startedAt < b.startedAt
            }
            return a.sessionID < b.sessionID
        }
    }

    // MARK: - コールバック

    var onPhaseChanged: ((MascotPhase) -> Void)?
    var onEphemeralDone: ((Int) -> Void)?
    /// セッション数が変化したときに発火する。バブルテキストの [+N] サフィックス更新に使用。
    var onSessionCountChanged: ((Int) -> Void)?

    // MARK: - セッション数追跡

    private var lastNotifiedSessionCount: Int = 0

    // MARK: - レース対策（セッション単位）

    private var sessionEpochs: [String: UInt] = [:]
    private var pendingTransitions: [String: DispatchWorkItem] = [:]

    // MARK: - Sleep タイマー

    private var sleepTimer: Timer?
    private(set) var sleepThreshold: TimeInterval

    // MARK: - セッションタイムアウト

    private var sessionTimeoutTimer: Timer?
    private(set) var sessionTimeout: TimeInterval
    /// テスト用: タイムアウトチェック間隔。本番では 60秒。
    private let sessionTimeoutCheckInterval: TimeInterval

    // MARK: - Auto-transition delay

    private let errorAutoTransitionDelay: TimeInterval
    private let doneAutoTransitionDelay: TimeInterval
    private let respondingTransitionDelay: TimeInterval

    // MARK: - DI seams

    private let now: () -> Date

    init(
        sleepThreshold: TimeInterval = 300,
        sessionTimeout: TimeInterval = 300,
        sessionTimeoutCheckInterval: TimeInterval = 60,
        errorAutoTransitionDelay: TimeInterval = 2.5,
        doneAutoTransitionDelay: TimeInterval = 4.0,
        respondingTransitionDelay: TimeInterval = 0.8,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sleepThreshold = sleepThreshold
        self.sessionTimeout = sessionTimeout
        self.sessionTimeoutCheckInterval = sessionTimeoutCheckInterval
        self.errorAutoTransitionDelay = errorAutoTransitionDelay
        self.doneAutoTransitionDelay = doneAutoTransitionDelay
        self.respondingTransitionDelay = respondingTransitionDelay
        self.now = now
    }

    // MARK: - ライフサイクル

    /// 初期フェーズ同期 + sleep タイマー始動。
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        onPhaseChanged?(displayPhase)
        startSleepTimerIfNeeded()
    }

    // MARK: - イベント処理

    /// ClabotchEvent を受けて phase 遷移を行う。main thread 限定。
    /// 全セッションのイベントを受理する（ownership guard 廃止）。
    func handle(event: ClabotchEvent) {
        dispatchPrecondition(condition: .onQueue(.main))

        let currentDate = now()

        os_log(.default, "🧠 StateMachine.handle: %{public}@ (sessions=%d, displayPhase=%{public}@)",
               event.debugSummary, sessions.count, displayPhase.debugName)

        switch event {
        case .sessionStart(let sessionID):
            // 重複 session_start は no-op（§14.3 不変条件 4）
            guard sessions[sessionID] == nil else {
                os_log(.debug, "🧠 StateMachine: session_start 重複 → no-op (sid=%{public}@)", String(sessionID.prefix(8)))
                return
            }
            cancelSleepTimer()
            sessions[sessionID] = SessionState(
                sessionID: sessionID,
                phase: .thinking,
                startedAt: currentDate,
                lastEventAt: currentDate
            )
            sessionEpochs[sessionID] = 0
            recalculateDisplayPhase()
            startSessionTimeoutTimerIfNeeded()

        case .toolStart(let sessionID, let toolName):
            guard let s = sessions[sessionID], !s.phase.isDone else { return }
            bumpEpoch(for: sessionID)
            sessions[sessionID]?.lastEventAt = currentDate
            sessions[sessionID]?.phase = .working(toolName: toolName)
            recalculateDisplayPhase()

        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
            guard let s = sessions[sessionID], !s.phase.isDone else { return }
            bumpEpoch(for: sessionID)
            sessions[sessionID]?.lastEventAt = currentDate
            if isError {
                let p = MascotPhase.error(toolName: toolName, message: errorMessage)
                sessions[sessionID]?.phase = p
                recalculateDisplayPhase()
                scheduleAutoTransition(
                    for: sessionID, toPhase: .thinking,
                    after: errorAutoTransitionDelay
                )
            } else {
                sessions[sessionID]?.phase = .thinking
                recalculateDisplayPhase()
                scheduleAutoTransition(
                    for: sessionID, toPhase: .responding,
                    after: respondingTransitionDelay
                )
            }

        case .sessionDone(let sessionID, let hookElapsedMs):
            // 未追跡セッション: ephemeral 通知のみ
            guard let session = sessions[sessionID] else {
                if hookElapsedMs > 0 {
                    onEphemeralDone?(hookElapsedMs)
                }
                return
            }

            // Hook が elapsed_ms を提供しなかった場合（ツール未使用セッション等）、
            // app が記録した startedAt からフォールバック計算する。
            let elapsedMs: Int
            if hookElapsedMs > 0 {
                elapsedMs = hookElapsedMs
            } else {
                let computedMs = Int(currentDate.timeIntervalSince(session.startedAt) * 1000)
                elapsedMs = max(0, computedMs)
            }

            bumpEpoch(for: sessionID)
            sessions[sessionID]?.lastEventAt = currentDate
            sessions[sessionID]?.phase = .done(elapsedMs: elapsedMs)
            recalculateDisplayPhase()
            scheduleSessionRemoval(for: sessionID, after: doneAutoTransitionDelay)

            // 非プライマリセッションの完了: ephemeral 通知
            // 完了したセッション自身がプライマリとして表示されない場合
            // （より高優先のセッション表示中、または先行した別の done が表示中）、
            // ephemeral bubble でユーザーに通知する
            if primarySession?.sessionID != sessionID, elapsedMs > 0 {
                onEphemeralDone?(elapsedMs)
            }

        case .unknown:
            break
        }
    }

    // MARK: - セッション epoch 管理

    private func bumpEpoch(for sessionID: String) {
        cancelPendingTransition(for: sessionID)
        sessionEpochs[sessionID, default: 0] &+= 1
    }

    private func cancelPendingTransition(for sessionID: String) {
        pendingTransitions[sessionID]?.cancel()
        pendingTransitions.removeValue(forKey: sessionID)
    }

    // MARK: - Auto-transition（遅延遷移、セッション単位）

    private func scheduleAutoTransition(
        for sessionID: String,
        toPhase phase: MascotPhase,
        after delay: TimeInterval
    ) {
        let epoch = sessionEpochs[sessionID] ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sessionEpochs[sessionID] == epoch else { return }
            self.sessions[sessionID]?.phase = phase
            self.pendingTransitions.removeValue(forKey: sessionID)
            self.recalculateDisplayPhase()
        }
        pendingTransitions[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// session_done 後の遅延セッション削除。
    private func scheduleSessionRemoval(for sessionID: String, after delay: TimeInterval) {
        let epoch = sessionEpochs[sessionID] ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sessionEpochs[sessionID] == epoch else { return }
            guard self.sessions[sessionID] != nil else { return }
            self.sessions.removeValue(forKey: sessionID)
            self.sessionEpochs.removeValue(forKey: sessionID)
            self.pendingTransitions.removeValue(forKey: sessionID)
            self.recalculateDisplayPhase()
        }
        pendingTransitions[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - displayPhase 再計算

    /// sessions から displayPhase を再計算し、変化があれば onPhaseChanged を発火する。
    /// プライマリ選択は primarySession（priority → startedAt → sessionID）で決定的。
    /// セッション数が変化した場合は onSessionCountChanged を発火する。
    private func recalculateDisplayPhase() {
        updateDisplayPhase(to: primarySession?.phase ?? .idle)
        notifySessionCountIfNeeded()
    }

    /// セッション数が前回通知時と異なる場合に onSessionCountChanged を発火する。
    private func notifySessionCountIfNeeded() {
        let count = sessions.count
        guard count != lastNotifiedSessionCount else { return }
        lastNotifiedSessionCount = count
        onSessionCountChanged?(count)
    }

    /// displayPhase を直接更新する。sleep タイマー管理 + コールバック発火。
    private func updateDisplayPhase(to newPhase: MascotPhase) {
        guard displayPhase != newPhase else { return }
        os_log(.default, "🧠 StateMachine: フェーズ遷移 %{public}@ → %{public}@",
               displayPhase.debugName, newPhase.debugName)
        displayPhase = newPhase

        if case .idle = newPhase, sessions.isEmpty {
            startSleepTimerIfNeeded()
        }

        onPhaseChanged?(newPhase)
    }

    // MARK: - セッションタイムアウトタイマー

    /// セッションが存在する間、定期的に stale セッションをチェックするタイマーを開始する。
    private func startSessionTimeoutTimerIfNeeded() {
        guard !sessions.isEmpty else { return }
        guard sessionTimeoutTimer == nil else { return }
        guard sessionTimeout.isFinite else { return }
        sessionTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: sessionTimeoutCheckInterval, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.reapStaleSessions()
        }
    }

    private func cancelSessionTimeoutTimer() {
        sessionTimeoutTimer?.invalidate()
        sessionTimeoutTimer = nil
    }

    /// lastEventAt が sessionTimeout を超えたセッションを削除する。
    private func reapStaleSessions() {
        dispatchPrecondition(condition: .onQueue(.main))
        let currentDate = now()
        var reaped = false
        for (sessionID, session) in sessions {
            let elapsed = currentDate.timeIntervalSince(session.lastEventAt)
            guard elapsed > sessionTimeout else { continue }
            os_log(.default, "🧠 StateMachine: セッションタイムアウト sid=%{public}@ (%.0f秒超過)",
                   String(sessionID.prefix(8)), elapsed)
            sessions.removeValue(forKey: sessionID)
            sessionEpochs.removeValue(forKey: sessionID)
            cancelPendingTransition(for: sessionID)
            reaped = true
        }
        if reaped {
            recalculateDisplayPhase()
        }
        if sessions.isEmpty {
            cancelSessionTimeoutTimer()
        }
    }

    // MARK: - Sleep タイマー

    private func startSleepTimerIfNeeded() {
        guard sessions.isEmpty else { return }
        guard case .idle = displayPhase else { return }
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: sleepThreshold, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            guard self.sessions.isEmpty else { return }
            self.updateDisplayPhase(to: .sleeping)
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    // MARK: - スリープ復帰

    /// ターミナルクリック等の外部トリガーで sleeping → idle に復帰する。
    /// セッションが残っていない場合のみ有効。スリープタイマーを再スケジュールする。
    func wakeFromSleep() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .sleeping = displayPhase else { return }
        updateDisplayPhase(to: .idle)
        startSleepTimerIfNeeded()
    }

    // MARK: - 設定変更

    /// スリープタイムアウトを動的に変更する。
    /// .infinity を指定するとスリープ無効。変更後、必要なら sleep タイマーを再スケジュールする。
    func updateSleepThreshold(_ newThreshold: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        sleepThreshold = newThreshold
        cancelSleepTimer()

        // スリープ中に閾値が変更された場合、idle に戻してからタイマーを再スケジュール
        if case .sleeping = displayPhase {
            updateDisplayPhase(to: .idle)
        }

        if newThreshold.isFinite {
            startSleepTimerIfNeeded()
        }
    }

    /// セッションタイムアウトを動的に変更する。
    /// .infinity を指定するとタイムアウト無効。
    func updateSessionTimeout(_ newTimeout: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        sessionTimeout = newTimeout
        cancelSessionTimeoutTimer()

        if newTimeout.isFinite {
            startSessionTimeoutTimerIfNeeded()
        }
    }

}

// MARK: - MascotPhase ヘルパー

extension MascotPhase {
    /// .done かどうかを判定する。
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    /// デバッグログ用の詳細フェーズ名（associated value 含む）
    var debugName: String {
        switch self {
        case .idle:                return "idle"
        case .thinking:            return "thinking"
        case .responding:          return "responding"
        case .working(let tool):   return "working(\(tool))"
        case .done(let ms):        return "done(\(ms)ms)"
        case .error(let tool, _):  return "error(\(tool))"
        case .sleeping:            return "sleeping"
        }
    }
}

// MARK: - ClabotchEvent デバッグヘルパー

extension ClabotchEvent {
    /// デバッグログ用のイベント概要
    var debugSummary: String {
        switch self {
        case .sessionStart(let sid):
            return "session_start(sid=\(sid.prefix(8))…)"
        case .toolStart(let sid, let tool):
            return "tool_start(sid=\(sid.prefix(8))…, tool=\(tool))"
        case .toolEnd(let sid, let tool, let ms, let isErr, _):
            return "tool_end(sid=\(sid.prefix(8))…, tool=\(tool), \(ms)ms, err=\(isErr))"
        case .sessionDone(let sid, let ms):
            return "session_done(sid=\(sid.prefix(8))…, \(ms)ms)"
        case .unknown:
            return "unknown"
        }
    }
}
