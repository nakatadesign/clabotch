import XCTest
import ApplicationServices
@testable import Clabotch

/// RealAXProvider.axValue の型検証テスト。
/// patch_022: force cast をやめ、不正な AX 応答（型不一致）を nil として
/// 通常のフォールバック（.terminalInOtherSpace）に流すクラッシュ回避経路を検証する。
final class AXProviderValueValidationTests: XCTestCase {

    func testNilRefReturnsNil() {
        XCTAssertNil(RealAXProvider.axValue(nil, as: .cgPoint, into: CGPoint.zero))
    }

    func testNonAXValueTypeReturnsNil() {
        // AXValue でない CFTypeRef（CFString）→ CFGetTypeID 検証で nil
        let notAXValue = "not-an-axvalue" as CFString
        XCTAssertNil(RealAXProvider.axValue(notAXValue, as: .cgPoint, into: CGPoint.zero))
    }

    func testMismatchedAXValueTypeReturnsNil() {
        // cgPoint の AXValue を cgSize として要求 → AXValueGetType 検証で nil
        var point = CGPoint(x: 10, y: 20)
        guard let pointValue = AXValueCreate(.cgPoint, &point) else {
            XCTFail("AXValueCreate に失敗")
            return
        }
        XCTAssertNil(RealAXProvider.axValue(pointValue, as: .cgSize, into: CGSize.zero))
    }

    func testMatchingPointValueReturnsValue() {
        var point = CGPoint(x: 10, y: 20)
        guard let pointValue = AXValueCreate(.cgPoint, &point) else {
            XCTFail("AXValueCreate に失敗")
            return
        }
        XCTAssertEqual(
            RealAXProvider.axValue(pointValue, as: .cgPoint, into: CGPoint.zero),
            CGPoint(x: 10, y: 20)
        )
    }

    func testMatchingSizeValueReturnsValue() {
        var size = CGSize(width: 800, height: 600)
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            XCTFail("AXValueCreate に失敗")
            return
        }
        XCTAssertEqual(
            RealAXProvider.axValue(sizeValue, as: .cgSize, into: CGSize.zero),
            CGSize(width: 800, height: 600)
        )
    }
}
