import AppKit

/// AX API の抽象化。テスト時に MockAXProvider を注入する。
protocol AXProvider {
    /// AXIsProcessTrusted() の抽象化
    func isProcessTrusted() -> Bool

    /// AXIsProcessTrustedWithOptions() の抽象化
    @discardableResult
    func requestTrust(prompt: Bool) -> Bool

    /// ターミナルウィンドウの中心座標を取得する。
    /// 成功: (CGPoint, nil)  失敗: (nil, FixedGazeReason)
    func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?)
}

/// NSWorkspace の抽象化。テスト時に MockWorkspaceProvider を注入する。
protocol WorkspaceProvider {
    /// フロントアプリの bundleIdentifier を返す。nil ならアプリ未検出。
    func frontmostBundleIdentifier() -> String?

    /// フロントアプリの PID を返す。nil ならアプリ未検出。
    func frontmostPID() -> pid_t?
}

// MARK: - 本番実装

struct RealAXProvider: AXProvider {
    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func findTerminalCenter(pid: pid_t) -> (CGPoint?, FixedGazeReason?) {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
            let windows = ref as? [AXUIElement], !windows.isEmpty
        else { return (nil, .terminalMinimized) }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return (nil, .terminalInOtherSpace) }

        // AXValue 型を検証してから取り出す（force cast は不正な AX 応答でクラッシュする）
        guard
            let pos = Self.axValue(posRef, as: .cgPoint, into: CGPoint.zero),
            let size = Self.axValue(sizeRef, as: .cgSize, into: CGSize.zero)
        else { return (nil, .terminalInOtherSpace) }

        // AX 座標系（Y=0 が画面上端、下向き正）→ Cocoa 座標系（Y=0 が画面下端、上向き正）に変換
        // マルチモニタ: primary screen (screens[0]) の高さが座標変換の基準
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1440
        let centerX = pos.x + size.width / 2
        let centerY = screenHeight - (pos.y + size.height / 2)
        return (CGPoint(x: centerX, y: centerY), nil)
    }

    /// CFTypeRef が期待する型の AXValue であることを検証して値を取り出す。
    private static func axValue<T>(_ ref: CFTypeRef?, as type: AXValueType, into initial: T) -> T? {
        guard
            let ref,
            CFGetTypeID(ref) == AXValueGetTypeID(),
            AXValueGetType(ref as! AXValue) == type
        else { return nil }
        var value = initial
        guard AXValueGetValue(ref as! AXValue, type, &value) else { return nil }
        return value
    }
}

struct RealWorkspaceProvider: WorkspaceProvider {
    func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// NSEvent.addGlobalMonitorForEvents を使った本番実装。
final class RealGlobalEventMonitor: GlobalEventMonitorProviding {
    private var monitor: Any?

    func startMonitoring(handler: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            handler()
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        stopMonitoring()
    }
}
