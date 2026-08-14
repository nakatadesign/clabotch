import Foundation

/// テスト用の短い一時ディレクトリを作成（sun_path 104 byte 制限対策）
func makeTestSocketDir(id: String = UUID().uuidString.prefix(8).description) -> String {
    let dir = "/tmp/cbt-\(id)"
    try? FileManager.default.removeItem(atPath: dir)
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    chmod(dir, 0o700)
    return dir
}

/// テスト用ディレクトリのクリーンアップ
func cleanupTestDir(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
}

/// Unix domain socket に接続してデータを送信するヘルパー
func sendToSocket(path: String, data: Data, timeout: TimeInterval = 2.0) throws {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: "test", code: Int(errno)) }
    defer { Darwin.close(fd) }

    // SO_NOSIGPIPE 設定
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        path.withCString { src in
            _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count))
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        throw NSError(domain: "test", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "connect failed: \(errno)"])
    }

    _ = data.withUnsafeBytes { buf in
        Darwin.write(fd, buf.baseAddress!, buf.count)
    }
}

/// テスト用の有効な NDJSON 行を生成（改行なし）
/// - Parameters:
///   - event: イベント種別（session_start, tool_start, tool_end, session_done）
///   - sessionID: セッション ID
///   - eventID: イベント ID（デフォルト自動生成）
///   - toolName: tool_start / tool_end 用のツール名
///   - durationMs: tool_end 用の実行時間（ms）
///   - isError: tool_end 用のエラーフラグ
///   - errorMessage: tool_end 用のエラーメッセージ（nil で省略）
///   - elapsedMs: session_done 用の経過時間（ms）
func makeTestNDJSON(
    event: String = "session_start",
    sessionID: String = "test-session",
    eventID: UUID = UUID(),
    timestamp: String = "2026-03-10T09:00:00Z",
    toolName: String? = nil,
    durationMs: Int? = nil,
    isError: Bool? = nil,
    errorMessage: String? = nil,
    elapsedMs: Int? = nil
) -> String {
    var json = "{\"schema_version\":\"1\",\"event_id\":\"\(eventID.uuidString)\",\"event\":\"\(event)\",\"session_id\":\"\(sessionID)\",\"timestamp\":\"\(timestamp)\""
    if let toolName { json += ",\"tool_name\":\"\(toolName)\"" }
    if let durationMs { json += ",\"duration_ms\":\(durationMs)" }
    if let isError { json += ",\"is_error\":\(isError)" }
    if let errorMessage { json += ",\"error_message\":\"\(errorMessage)\"" }
    if let elapsedMs { json += ",\"elapsed_ms\":\(elapsedMs)" }
    json += "}"
    return json
}

/// Unix domain socket に接続して live 判定
func isSocketLive(path: String) -> Bool {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        path.withCString { src in
            _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count))
        }
    }

    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}
