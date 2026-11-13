import XCTest
import LuckgramUI

/// specs#160: backup hosts for the website, help center and package downloads.
final class LuckgramMirrorsTests: XCTestCase {
    private let spec: [String: String] = [
        "luckgram.cc": "lg-www.cat158.com",
        "www.luckgram.cc": "lg-www.cat158.com",
        "wiki.luckgram.cc": "lg-wiki.cat158.com",
        "dl.luckgram.cc": "lg-dl.cat158.com",
        "web.luckgram.cc": "lgweb.cat158.com",
    ]

    private var m: LuckgramMirrors {
        return LuckgramMirrors.parse(spec)
    }

    func testParse() {
        XCTAssertEqual(m.hosts, spec)
        let junk: [String: Any] = [" WIKI.Luckgram.cc ": "LG-WIKI.cat158.com", "x": "a.b", "a.b": "a.b", "c.d": 1, "https://e.f": "g.h"]
        XCTAssertEqual(LuckgramMirrors.parse(junk).hosts, ["wiki.luckgram.cc": "lg-wiki.cat158.com"])
        XCTAssertEqual(LuckgramMirrors.parse(nil).hosts, [:])
    }

    func testMirror() {
        XCTAssertEqual(m.mirror("https://dl.luckgram.cc/ios/ios-13.1.1-36373/Luckgram-13.1.1-36373.ipa"), "https://lg-dl.cat158.com/ios/ios-13.1.1-36373/Luckgram-13.1.1-36373.ipa")
        XCTAssertEqual(m.mirror("https://wiki.luckgram.cc/getting-started/install.html"), "https://lg-wiki.cat158.com/getting-started/install.html")
        XCTAssertEqual(m.mirror("https://luckgram.cc/privacy-policy/"), "https://lg-www.cat158.com/privacy-policy/")
        XCTAssertEqual(m.mirror("https://WWW.luckgram.cc/en/?a=1#top"), "https://lg-www.cat158.com/en/?a=1#top")
        // web version (specs#160 follow-up): deep links keep path, query and fragment
        XCTAssertEqual(m.mirror("https://web.luckgram.cc/#@luckgram"), "https://lgweb.cat158.com/#@luckgram")
        XCTAssertEqual(m.mirror("https://web.luckgram.cc/k/?tgaddr=x"), "https://lgweb.cat158.com/k/?tgaddr=x")
        XCTAssertEqual(m.mirror("https://luckgram.cc"), "https://lg-www.cat158.com")
        XCTAssertEqual(m.mirror("HTTPS://luckgram.cc./"), "https://lg-www.cat158.com/")
        XCTAssertNil(m.mirror("https://api.luckgram.cc/v1/version"))
        XCTAssertNil(m.mirror("https://telegram.org/faq"))
        XCTAssertNil(m.mirror("http://luckgram.cc/"))
        XCTAssertNil(m.mirror("https://luckgram.cc.example.com/"))
        XCTAssertNil(m.mirror("https://user@luckgram.cc/"))
        XCTAssertNil(m.mirror("https://luckgram.cc:8443/"))
        XCTAssertNil(m.mirror(""))
    }

    func testForSite() {
        let wiki = "https://wiki.luckgram.cc/faq/"
        XCTAssertEqual(m.forSite(wiki, apiOnBackup: false), wiki)
        XCTAssertEqual(m.forSite(wiki, apiOnBackup: true), "https://lg-wiki.cat158.com/faq/")
        XCTAssertEqual(m.forSite("https://t.me/luckgram", apiOnBackup: true), "https://t.me/luckgram")
        XCTAssertEqual(m.forSite("https://web.luckgram.cc/", apiOnBackup: false), "https://web.luckgram.cc/")
        XCTAssertEqual(m.forSite("https://web.luckgram.cc/", apiOnBackup: true), "https://lgweb.cat158.com/")
    }
}
