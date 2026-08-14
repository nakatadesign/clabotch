import XCTest
@testable import Clabotch

// MARK: - EventParserTests（pure function テスト）
// v11 §10.2: 共通フィールドはすべて必須（timestamp 含む）。
// patch_022: session_done.elapsed_ms 必須化 / 負数拒否 / 空 session_id 拒否 / 長さ上限。

final class EventParserTests: XCTestCase {

    private let ts = "2026-03-10T09:00:00Z"

    // MARK: - 正常系

    // 1. session_start
    func testParseSessionStart() {
        let json = makeTestNDJSON(event: "session_start", sessionID: "ses-001")
        let data = Data(json.utf8)
        let envelope = EventParser.parse(data)
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionStart(sessionID: "ses-001"))
    }

    // 2. tool_start
    func testParseToolStart() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"tool_start","session_id":"ses-002","timestamp":"\(ts)","tool_name":"Read"}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.eventID, id)
        XCTAssertEqual(envelope?.event, .toolStart(sessionID: "ses-002", toolName: "Read"))
    }

    // 3. tool_end（エラーメッセージあり）
    func testParseToolEnd() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"tool_end","session_id":"ses-003","timestamp":"\(ts)","tool_name":"Bash","duration_ms":150,"is_error":true,"error_message":"タイムアウト"}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .toolEnd(
            sessionID: "ses-003", toolName: "Bash",
            durationMs: 150, isError: true, errorMessage: "タイムアウト"))
    }

    // 4. session_done
    func testParseSessionDone() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"session_done","session_id":"ses-004","timestamp":"\(ts)","elapsed_ms":5000}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionDone(sessionID: "ses-004", elapsedMs: 5000))
    }

    // 5. session_done（elapsed_ms = 0 は正当な値。ツール未使用セッション）
    func testParseSessionDoneZeroElapsed() {
        let json = makeTestNDJSON(event: "session_done", sessionID: "ses-005", elapsedMs: 0)
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionDone(sessionID: "ses-005", elapsedMs: 0))
    }

    // 6. tool_end（error_message 省略 → nil）
    func testParseToolEndWithoutErrorMessage() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"tool_end","session_id":"s","timestamp":"\(ts)","tool_name":"Read","duration_ms":100,"is_error":false}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .toolEnd(
            sessionID: "s", toolName: "Read",
            durationMs: 100, isError: false, errorMessage: nil))
    }

    // MARK: - 共通フィールドのエラー系

    // 7. schema_version 欠落
    func testMissingSchemaVersion() {
        let json = """
        {"event_id":"\(UUID().uuidString)","event":"session_start","session_id":"s","timestamp":"\(ts)"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 8. schema_version 不一致
    func testWrongSchemaVersion() {
        let json = """
        {"schema_version":"2","event_id":"\(UUID().uuidString)","event":"session_start","session_id":"s","timestamp":"\(ts)"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 9. event_id 欠落
    func testMissingEventID() {
        let json = """
        {"schema_version":"1","event":"session_start","session_id":"s","timestamp":"\(ts)"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 10. event_id 不正（UUID でない文字列）
    func testInvalidEventID() {
        let json = """
        {"schema_version":"1","event_id":"not-a-uuid","event":"session_start","session_id":"s","timestamp":"\(ts)"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 11. event フィールド欠落
    func testMissingEvent() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","session_id":"s","timestamp":"\(ts)"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 12. session_id 欠落
    func testMissingSessionID() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","event":"session_start","timestamp":"\(ts)"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 13. session_id 空文字列
    func testEmptySessionID() {
        let json = makeTestNDJSON(event: "session_start", sessionID: "")
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 14. session_id 長さ上限超過
    func testOverlongSessionID() {
        let longID = String(repeating: "a", count: EventParser.maxSessionIDLength + 1)
        let json = makeTestNDJSON(event: "session_start", sessionID: longID)
        XCTAssertNil(EventParser.parse(Data(json.utf8)))

        let maxID = String(repeating: "a", count: EventParser.maxSessionIDLength)
        XCTAssertNotNil(EventParser.parse(Data(makeTestNDJSON(event: "session_start", sessionID: maxID).utf8)))
    }

    // 15. timestamp 欠落（v11 §10.2 で必須）
    func testMissingTimestamp() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","event":"session_start","session_id":"s"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 16. timestamp 空文字列
    func testEmptyTimestamp() {
        let json = makeTestNDJSON(event: "session_start", sessionID: "s", timestamp: "")
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // MARK: - イベント別フィールドのエラー系

    // 17. tool_start で tool_name 欠落
    func testToolStartMissingToolName() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","event":"tool_start","session_id":"s","timestamp":"\(ts)"}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 18. tool_start で tool_name 長さ上限超過
    func testToolStartOverlongToolName() {
        let longName = String(repeating: "T", count: EventParser.maxToolNameLength + 1)
        let json = makeTestNDJSON(event: "tool_start", sessionID: "s", toolName: longName)
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 19. tool_end で必須フィールド欠落（duration_ms なし）
    func testToolEndMissingDurationMs() {
        let json = """
        {"schema_version":"1","event_id":"\(UUID().uuidString)","event":"tool_end","session_id":"s","timestamp":"\(ts)","tool_name":"Read","is_error":false}
        """
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 20. tool_end で duration_ms が負数
    func testToolEndNegativeDurationMs() {
        let json = makeTestNDJSON(
            event: "tool_end", sessionID: "s",
            toolName: "Read", durationMs: -1, isError: false)
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 21. session_done で elapsed_ms 欠落（v11 §10.2 で必須。デフォルト 0 に丸めない）
    func testSessionDoneMissingElapsedMs() {
        let json = makeTestNDJSON(event: "session_done", sessionID: "ses-021")
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // 22. session_done で elapsed_ms が負数
    func testSessionDoneNegativeElapsedMs() {
        let json = makeTestNDJSON(event: "session_done", sessionID: "s", elapsedMs: -500)
        XCTAssertNil(EventParser.parse(Data(json.utf8)))
    }

    // MARK: - 不正入力

    // 23. 不正バイト列（JSONSerialization がエラーを返す）
    func testInvalidJSON() {
        let data = Data([0xFF, 0xFE, 0x00])
        XCTAssertNil(EventParser.parse(data))
    }

    // 24. トップレベルが Array（Object でない）
    func testJSONArray() {
        let data = Data("[1,2,3]".utf8)
        XCTAssertNil(EventParser.parse(data))
    }

    // MARK: - forward-compatible

    // 25. 未知イベントは unknown(rawJSON:) として保持
    func testUnknownEventPreservesRawJSON() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"future_event","session_id":"s","timestamp":"\(ts)","extra":42}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.eventID, id)
        if case .unknown(let rawJSON) = envelope?.event {
            XCTAssertTrue(rawJSON.contains("future_event"))
        } else {
            XCTFail("unknown ケースを期待: \(String(describing: envelope?.event))")
        }
    }

    // 26. 既知イベントに余分なフィールドがあっても無視して正常パース
    func testExtraFieldsIgnored() {
        let id = UUID()
        let json = """
        {"schema_version":"1","event_id":"\(id.uuidString)","event":"session_start","session_id":"ses-extra","timestamp":"\(ts)","bonus":"ignored"}
        """
        let envelope = EventParser.parse(Data(json.utf8))
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .sessionStart(sessionID: "ses-extra"))
    }
}
