import XCTest
import SwiftUI
@testable import OctokanSDK

final class OctokanSDKTests: XCTestCase {
    func testHexColorParsing() {
        XCTAssertNotNil(Color(octokanHex: "#ff3b24"))
        XCTAssertNil(Color(octokanHex: "nope"))
    }

    func testResetClearsStoredState() {
        Octokan.configure(appId: "app_test", baseURL: URL(string: "https://example.com")!)
        Octokan.defaults.set("token", forKey: Octokan.tokenKey("app_test"))
        Octokan.identify(id: "1", email: "a@b.c", name: "A")
        Octokan.reset()
        XCTAssertNil(Octokan.defaults.string(forKey: Octokan.tokenKey("app_test")))
        XCTAssertNil(Octokan.user)
    }
}
