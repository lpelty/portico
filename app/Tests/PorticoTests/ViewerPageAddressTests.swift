import XCTest

@testable import Portico

/// v0.13 decision 5 (Pen AL4): after a link leaves the file, the header
/// shows the site's address.
@MainActor
final class ViewerPageAddressTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/chat/signup-form.html")

    func test_a_web_page_reached_from_a_file_is_outside() {
        let site = URL(string: "https://example.com/docs/start")!
        XCTAssertEqual(ViewerPageAddress.outside(current: site, loaded: .html(file)), site)
        XCTAssertEqual(ViewerPageAddress.outside(current: site, loaded: .markdown(file)), site)
    }

    func test_the_file_itself_and_the_opened_address_are_not_outside() {
        XCTAssertNil(ViewerPageAddress.outside(current: URL(string: "portico-view://page/signup-form.html")!, loaded: .html(file)))
        XCTAssertNil(ViewerPageAddress.outside(current: file, loaded: .html(file)))
        XCTAssertNil(ViewerPageAddress.outside(current: nil, loaded: .html(file)))
        let opened = URL(string: "https://www.figma.com/file/abc")!
        XCTAssertNil(ViewerPageAddress.outside(current: opened, loaded: .url(opened)))
        XCTAssertNil(ViewerPageAddress.outside(current: URL(string: "https://figma.com/login")!, loaded: .url(opened)),
                     "the opened site's own pages and redirects are not outside")
        let dev = URL(string: "http://localhost:5173/")!
        XCTAssertNil(ViewerPageAddress.outside(current: URL(string: "http://localhost:5173/settings")!, loaded: .url(dev)))
        let other = URL(string: "https://example.com/")!
        XCTAssertEqual(ViewerPageAddress.outside(current: other, loaded: .url(opened)), other)
    }

    func test_display_is_host_and_path_without_scheme_or_www() {
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/")!), "example.com")
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://www.figma.com/file/abc?x=1")!), "figma.com/file/abc")
    }
}
