import Foundation
import XCTest

@testable import Portico

/// The resource bundle is found in an assembled `.app`'s
/// `Contents/Resources` before SwiftPM's own lookup is consulted.
final class AppResourcesTests: XCTestCase {

    func testPackagedBundleInContentsResourcesWins() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("portico-res-\(UUID().uuidString)/Contents/Resources", isDirectory: true)
        let inner = resources.appendingPathComponent(AppResources.bundleName).appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: resources.deletingLastPathComponent().deletingLastPathComponent()) }
        try "marker".write(to: inner.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

        let bundle = try XCTUnwrap(AppResources.packagedBundle(in: resources))
        let url = try XCTUnwrap(AppResources.url(forResource: "probe", withExtension: "txt", bundle: bundle))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "marker")
    }

    func testNoPackagedBundleFallsBackToTheModule() {
        XCTAssertNil(AppResources.packagedBundle(in: FileManager.default.temporaryDirectory.appendingPathComponent("nothing-\(UUID().uuidString)")))
        XCTAssertNil(AppResources.packagedBundle(in: nil))
        // In the test run there is no .app: SwiftPM's bundle serves the page's files.
        XCTAssertNotNil(AppResources.bundle.resourceURL)
    }
}
