import XCTest
@testable import LanLineCore

/// Smart items (beta.10); the PC runs the same cases ("smart items").
final class SmartTextTests: XCTestCase {
    func testOTP() {
        XCTAssertEqual(SmartText.analyze("482913").otp, "482913")
        XCTAssertEqual(SmartText.analyze("482 913").otp, "482913")
        XCTAssertEqual(SmartText.analyze(" 482-913 ").otp, "482913")
        XCTAssertEqual(SmartText.analyze("G-482913").otp, "482913")
        XCTAssertEqual(SmartText.analyze("Your verification code is 7731. It expires in 10 minutes.").otp, "7731")
        XCTAssertEqual(SmartText.analyze("G-482913 is your Google verification code.").otp, "482913")
        XCTAssertEqual(SmartText.analyze("Use 552 019 to sign in").otp, "552019")
        XCTAssertNil(SmartText.analyze("Meeting moved to 3:30 tomorrow").otp)
        XCTAssertNil(SmartText.analyze("The budget for 2026 is 450000 dollars").otp, "numbers without a code word")
        XCTAssertNil(SmartText.analyze("Your order 12345678901 shipped").otp, "too long")
        XCTAssertNil(SmartText.analyze("code version 1.2.3456").otp, "part of a version number")
    }

    /// Fullwidth "hex" letters pass Character.isHexDigit but don't parse: no colour, and above all no crash.
    func testFullwidthHexIsNotAColourAndDoesNotCrash() {
        for t in ["#ｆｆｆ", "#ＦＦＦ", "#ｆｆｆｆｆｆ", "#１２３", "#ff００ff", "#ｆｆｆｆｆｆｆｆ"] {
            XCTAssertNil(SmartText.color(t), t)
            _ = SmartText.analyze(t)
        }
        XCTAssertNotNil(SmartText.color("#FfF"))
    }

    func testColors() {
        XCTAssertEqual(SmartText.analyze("#3a7bd5").color, SmartColor(r: 58, g: 123, b: 213))
        XCTAssertEqual(SmartText.analyze("#FFF").color, SmartColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(SmartText.analyze("#3a7bd580").color?.hex, "#3A7BD580")
        XCTAssertEqual(SmartText.analyze("rgb(58, 123, 213)").color?.hex, "#3A7BD5")
        XCTAssertEqual(SmartText.analyze("rgba(0,0,0,0.5)").color?.rgb, "rgba(0, 0, 0, 0.5)")
        XCTAssertEqual(SmartText.analyze("hsl(215, 65%, 53%)").color?.hex, "#397AD5")   // worked by hand
        XCTAssertEqual(SmartColor(r: 58, g: 123, b: 213).hsl, "hsl(215, 65%, 53%)")
        XCTAssertEqual(SmartColor(r: 128, g: 128, b: 128).hsl, "hsl(0, 0%, 50%)")
        XCTAssertNil(SmartText.analyze("#12345").color)
        XCTAssertNil(SmartText.analyze("rgb(300, 0, 0)").color)
        XCTAssertNil(SmartText.analyze("my colour is #3a7bd5").color, "only a message that is just a colour")
    }

    func testCode() {
        let fenced = "```swift\nlet x = 1\nprint(x)\n```"
        XCTAssertEqual(SmartText.analyze(fenced).code, SmartCode(body: "let x = 1\nprint(x)", language: "swift"))
        let braces = "func hello() {\n    print(\"hi\")\n}"
        XCTAssertEqual(SmartText.analyze(braces).code?.body, braces)
        XCTAssertNotNil(SmartText.analyze("git fetch origin\ngit rebase origin/main").code)
        XCTAssertNil(SmartText.analyze("Can you send the deck?\nThe new one, with the icons.").code, "prose")
        XCTAssertNil(SmartText.analyze("let me know").code, "one line")
        XCTAssertNil(SmartText.analyze("```\nlet x = 1\n```").otp, "code isn't checked for codes or colours")
    }

    func testLinks() {
        let one = SmartText.analyze("https://example.com/a/b?c=1")
        XCTAssertEqual(one.singleLink?.absoluteString, "https://example.com/a/b?c=1")
        XCTAssertEqual(SmartText.analyze("www.example.org").singleLink?.absoluteString, "https://www.example.org")
        let many = SmartText.analyze("See https://a.com/x, and (https://b.org/y). Also https://a.com/x again; javascript:alert(1) file:///etc/passwd")
        XCTAssertEqual(many.links.map(\.absoluteString), ["https://a.com/x", "https://b.org/y"])
        XCTAssertNil(many.singleLink)
        XCTAssertEqual(SmartText.analyze("https://en.wikipedia.org/wiki/Foo_(bar)").links.first?.absoluteString, "https://en.wikipedia.org/wiki/Foo_(bar)", "balanced brackets stay")
        XCTAssertEqual(SmartText.analyze("ftp://x.org http://ok.org").links.map(\.absoluteString), ["http://ok.org"], "http(s) only")
    }

    func testLinkPreviewParse() {
        let base = URL(string: "https://www.example.com/post/1")!
        let og = #"<html><head><title>Fallback</title><meta property="og:title" content="Q4 &amp; Beyond"><meta content="Example News" property="og:site_name"><meta property="og:image" content="/img/hero.png"></head></html>"#
        let p = LinkPreview.parse(html: og, base: base)
        XCTAssertEqual(p, LinkPreview(title: "Q4 & Beyond", site: "Example News", image: URL(string: "https://www.example.com/img/hero.png")))
        XCTAssertEqual(LinkPreview.parse(html: "<title>\n  Just a   title\n</title>", base: base).title, "Just a title")
        XCTAssertNil(LinkPreview.parse(html: #"<meta property="og:image" content="javascript:alert(1)">"#, base: base).image, "http(s) images only")
        XCTAssertEqual(LinkPreview.host(base), "example.com")
    }
}
