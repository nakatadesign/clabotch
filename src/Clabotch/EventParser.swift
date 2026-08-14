import Foundation

/// NDJSON 行データを ClabotchEnvelope に変換する pure function。
/// 任意スレッドで呼び出し可能。不正な入力に対しては nil を返す。
///
/// スキーマは v11 §10.2 準拠（patch_022 で厳格化）:
/// - 共通フィールド schema_version / event / session_id / event_id / timestamp はすべて必須
/// - session_done の elapsed_ms は必須（省略をデフォルト 0 に丸めない — producer の破損を隠さない）
/// - 負の duration_ms / elapsed_ms は不正として破棄
struct EventParser {

    /// producer（hook スクリプト）は制御下にあるため、上限は防御的な安全弁。
    static let maxSessionIDLength = 256
    static let maxToolNameLength = 128

    static func parse(_ data: Data) -> ClabotchEnvelope? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schemaVersion = json["schema_version"] as? String,
            schemaVersion == "1",
            let eventIDRaw = json["event_id"] as? String,
            let eventID = UUID(uuidString: eventIDRaw),
            let event = json["event"] as? String,
            let sessionID = json["session_id"] as? String,
            !sessionID.isEmpty,
            sessionID.count <= maxSessionIDLength,
            isNonEmptyString(json["timestamp"])
        else { return nil }

        let parsed: ClabotchEvent
        switch event {
        case "session_start":
            parsed = .sessionStart(sessionID: sessionID)
        case "tool_start":
            guard let toolName = validToolName(json["tool_name"]) else { return nil }
            parsed = .toolStart(sessionID: sessionID, toolName: toolName)
        case "tool_end":
            guard
                let toolName = validToolName(json["tool_name"]),
                let durationMs = json["duration_ms"] as? Int,
                durationMs >= 0,
                let isError = json["is_error"] as? Bool
            else { return nil }
            parsed = .toolEnd(
                sessionID: sessionID, toolName: toolName,
                durationMs: durationMs, isError: isError,
                errorMessage: json["error_message"] as? String
            )
        case "session_done":
            guard
                let elapsedMs = json["elapsed_ms"] as? Int,
                elapsedMs >= 0
            else { return nil }
            parsed = .sessionDone(sessionID: sessionID, elapsedMs: elapsedMs)
        default:
            let rawJSON = String(data: data, encoding: .utf8) ?? ""
            parsed = .unknown(rawJSON: rawJSON)
        }

        return ClabotchEnvelope(eventID: eventID, event: parsed)
    }

    // MARK: - フィールド検証ヘルパー

    /// 値が空でない String であることを検証する（timestamp は app では値未使用のため存在検証のみ）。
    private static func isNonEmptyString(_ value: Any?) -> Bool {
        guard let s = value as? String else { return false }
        return !s.isEmpty
    }

    /// tool_name の型と長さ上限を検証する。
    private static func validToolName(_ value: Any?) -> String? {
        guard let name = value as? String, name.count <= maxToolNameLength else { return nil }
        return name
    }
}
