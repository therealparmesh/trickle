import Foundation
import XCTest

final class RunnerTests: XCTestCase {

  func testPublishedBundleMetadata() throws {
    let productsDirectory = Bundle(for: RunnerTests.self).bundleURL.deletingLastPathComponent()
    let appBundle = try XCTUnwrap(
      Bundle(url: productsDirectory.appendingPathComponent("Runner.app"))
    )

    XCTAssertEqual(appBundle.bundleIdentifier, "com.parmscript.trickle")
    XCTAssertEqual(
      appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
      "trickle"
    )
  }
}
