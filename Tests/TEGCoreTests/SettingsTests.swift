import XCTest
@testable import TEGCore

final class SettingsTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let s = AppSettings.default
        XCTAssertEqual(s.leftZoneWidth, 0.15)
        XCTAssertEqual(s.rightZoneWidth, 0.15)
        XCTAssertTrue(s.mediaOnly)
        XCTAssertTrue(s.hapticsEnabled)
        XCTAssertEqual(s.hapticIntervalPoints, 10)
        XCTAssertEqual(s.sensitivity, 1.2, accuracy: 0.0001)
    }

    func testZoneWidthsClamp() {
        var s = AppSettings.default
        s.leftZoneWidth = 0.01
        s.rightZoneWidth = 0.9
        let v = s.validated()
        XCTAssertEqual(v.leftZoneWidth, 0.08, accuracy: 0.0001)
        XCTAssertEqual(v.rightZoneWidth, 0.30, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(v.leftZoneWidth + v.rightZoneWidth, 0.60 + 0.0001)
    }

    func testNaNAndRangeClamp() {
        var s = AppSettings.default
        s.sensitivity = .nan
        s.minMovement = 5
        s.volumeSensitivity = -3
        s.hapticIntervalPoints = 7
        let v = s.validated()
        XCTAssertEqual(v.sensitivity, 0.5)
        XCTAssertEqual(v.minMovement, 0.08)
        XCTAssertEqual(v.volumeSensitivity, 0.5)
        XCTAssertEqual(v.hapticIntervalPoints, 10)
    }

    func testRoundTripAndCorruptData() {
        let suite = UserDefaults(suiteName: "tegtests.\(UUID().uuidString)")!
        let storage = SettingsStorage(defaults: suite, key: "k")
        XCTAssertEqual(storage.load(), AppSettings.default)

        var s = AppSettings.default
        s.leftZoneWidth = 0.2
        s.hapticsEnabled = false
        storage.save(s)
        XCTAssertEqual(storage.load(), s.validated())

        suite.set(Data("not json".utf8), forKey: "k")
        XCTAssertEqual(storage.load(), AppSettings.default)

        storage.save(s)
        storage.reset()
        XCTAssertEqual(storage.load(), AppSettings.default)
    }
}
