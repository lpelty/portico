import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// Brand from `hello` (spec section 8): the name, the accent colour on
/// controls, the icon where the app shows one. View-free.
@MainActor
final class BrandTests: XCTestCase {

    func testDefaultsWithoutAHello() {
        let shown = BrandPresentation(brand: nil)
        XCTAssertEqual(shown.name, "Portico")
        XCTAssertNil(shown.accent, "no accent means the system accent")
        XCTAssertNil(shown.iconImage)
    }

    func testAccentParsesCSSHexAndFallsBackOnAnythingElse() {
        XCTAssertEqual(BrandPresentation.color(hex: "#3B6EF5"), Color(red: 0x3B / 255.0, green: 0x6E / 255.0, blue: 0xF5 / 255.0, opacity: 1))
        XCTAssertEqual(BrandPresentation.color(hex: "3b6ef5"), BrandPresentation.color(hex: "#3B6EF5"), "the hash and the case do not matter")
        XCTAssertEqual(BrandPresentation.color(hex: "#fff"), Color(red: 1, green: 1, blue: 1, opacity: 1))
        XCTAssertEqual(BrandPresentation.color(hex: "#3B6EF580"), Color(red: 0x3B / 255.0, green: 0x6E / 255.0, blue: 0xF5 / 255.0, opacity: 0x80 / 255.0))
        XCTAssertNil(BrandPresentation.color(hex: "blue"))
        XCTAssertNil(BrandPresentation.color(hex: "#12345"))
        XCTAssertNil(BrandPresentation.color(hex: ""))

        let branded = BrandPresentation(brand: Brand(name: "Acme Agent", agentName: "Acme", accent: "#3B6EF5"))
        XCTAssertEqual(branded.name, "Acme Agent")
        XCTAssertNotNil(branded.accent)
        let unparsable = BrandPresentation(brand: Brand(name: "Acme Agent", agentName: "Acme", accent: "navy"))
        XCTAssertNil(unparsable.accent, "an accent the app cannot read falls back to the system accent")
    }

    func testTheDockIconIsReplacedOnlyWhenTheBundleHasNone() {
        // A `swift run` build: no Info.plist icon, the brand's icon goes in the Dock.
        XCTAssertTrue(BrandPresentation.shouldReplaceApplicationIcon(bundleInfo: nil))
        XCTAssertTrue(BrandPresentation.shouldReplaceApplicationIcon(bundleInfo: ["CFBundleName": "Portico"]))
        XCTAssertTrue(BrandPresentation.shouldReplaceApplicationIcon(bundleInfo: ["CFBundleIconFile": " "]), "a blank name is no icon")
        // A built .app keeps the icon it was built with.
        XCTAssertFalse(BrandPresentation.shouldReplaceApplicationIcon(bundleInfo: ["CFBundleIconFile": "AppIcon"]))
        XCTAssertFalse(BrandPresentation.shouldReplaceApplicationIcon(bundleInfo: ["CFBundleIconName": "AppIcon"]))
        XCTAssertFalse(BrandPresentation.shouldReplaceApplicationIcon(bundleInfo: ["CFBundleIconFile": "AppIcon.icns", "CFBundleIconName": "AppIcon"]))
    }

    func testIconLoadsFromAnImageFileAndIsNilOtherwise() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-brand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("icon.png")
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: path)

        XCTAssertNotNil(BrandPresentation(brand: Brand(name: "A", agentName: "A", icon: path.path)).iconImage)
        XCTAssertNil(BrandPresentation(brand: Brand(name: "A", agentName: "A", icon: dir.appendingPathComponent("missing.png").path)).iconImage)
        XCTAssertNil(BrandPresentation(brand: Brand(name: "A", agentName: "A", icon: nil)).iconImage)
    }

    func testHelloBrandFlowsToThePresentation() {
        let model = AppModel()
        let hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: "epoch-A",
            brand: Brand(name: "Acme Agent", agentName: "Acme", accent: "#3B6EF5", icon: nil),
            actions: [], roots: [], commands: [], capabilities: [])
        model.apply(.hello(hello))
        let shown = model.brand
        XCTAssertEqual(shown.name, "Acme Agent")
        XCTAssertEqual(shown.accent, BrandPresentation.color(hex: "#3B6EF5"))
    }

    func testTheStartScreensMarkIsTheBrandIconWhenThereIsOneElseTheSparkleAndBigger() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-mark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("icon.png")
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: path)

        let branded = BrandPresentation(brand: Brand(name: "A", agentName: "A", icon: path.path))
        guard case .icon = StartView.GreetingMark(brand: branded) else { return XCTFail("expected the brand icon") }
        XCTAssertEqual(StartView.GreetingMark(brand: BrandPresentation(brand: nil)), .sparkle)
        let unreadable = BrandPresentation(brand: Brand(name: "A", agentName: "A", icon: dir.appendingPathComponent("missing.png").path))
        XCTAssertEqual(StartView.GreetingMark(brand: unreadable), .sparkle)
        XCTAssertGreaterThanOrEqual(StartView.markSize, 34 * 1.5, "noticeably bigger than the v0.3 mark")
        XCTAssertLessThanOrEqual(StartView.markSize, 34 * 2)
    }
}
