import XCTest
@testable import AtticCore

final class MIMEParserTests: XCTestCase {

    private let sample = """
    From: =?UTF-8?B?Sm9zw6kgR2FyY8OtYQ==?= <jose@example.com>
    To: "Smith, Anne" <anne@example.com>, Blair, Lynn </O=ENRON/OU=NA/CN=RECIPIENTS/CN=Lblair>, bob@example.com
    Subject: =?iso-8859-1?Q?Caf=E9?= =?iso-8859-1?Q?_menu?=
     continued
    Date: Mon, 29 Oct 2001 22:16:28 -0800 (PST),Mon, 29 Oct 2001 22:16:28 -0800  (PST)
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="outer"

    preamble
    --outer
    Content-Type: multipart/alternative; boundary=inner

    --inner
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Hello caf=C3=A9 soft=
    break
    --inner
    Content-Type: text/html; charset=utf-8

    <html><head><style>p{}</style></head><body><p>Hello &amp; welcome<br>line2 <img src="cid:img1@x"></p></body></html>
    --inner--
    --outer
    Content-Type: image/png
    Content-ID: <img1@x>
    Content-Transfer-Encoding: base64

    iVBORw0KGgo=
    --outer
    Content-Type: application/pdf; name="=?utf-8?Q?R=C3=A9sum=C3=A9.pdf?="
    Content-Disposition: attachment; filename*=utf-8''R%C3%A9sum%C3%A9%20final.pdf
    Content-Transfer-Encoding: base64

    JVBERi0xLjQK
    --outer--
    """.replacingOccurrences(of: "\n", with: "\r\n")

    func testHeadersAndAddresses() {
        let m = MIMEParser.parse(Data(sample.utf8))
        XCTAssertEqual(m.from?.name, "José García")
        XCTAssertEqual(m.from?.address, "jose@example.com")
        XCTAssertEqual(m.to.map(\.display), ["Smith, Anne", "Blair, Lynn", "bob@example.com"])
        XCTAssertEqual(m.subject, "Café menu continued")
        XCTAssertNotNil(m.date)
    }

    func testBodiesAndAttachments() {
        let m = MIMEParser.parse(Data(sample.utf8))
        XCTAssertEqual(m.textBody, "Hello café softbreak")
        XCTAssertEqual(m.inlineParts.first?.contentID, "img1@x")
        XCTAssertEqual(m.attachments.map(\.filename), ["Résumé final.pdf"])
        XCTAssertEqual(m.attachments.first?.data, Data("%PDF-1.4\n".utf8))
        XCTAssertEqual(TextDecoding.htmlToText(m.htmlBody ?? ""), "Hello & welcome\nline2")
    }

    func testOddStructures() {
        let lfOnly = "Subject: plain\nContent-Type: text/plain\n\nbody line\n"
        XCTAssertEqual(MIMEParser.parse(Data(lfOnly.utf8)).textBody, "body line\n")

        let unterminated = "Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nno close\n"
        XCTAssertEqual(MIMEParser.parse(Data(unterminated.utf8)).textBody?.hasPrefix("no close"), true)
    }
}

final class SearchQueryTests: XCTestCase {
    func testParsing() {
        let q = SearchQuery(parsing: #"from:smith "quarterly report" budg -newsletter has:attachment after:2001-01"#)
        XCTAssertEqual(q.matchExpression, #"sender : "smith"* AND "quarterly report" AND "budg"*"#)
        XCTAssertEqual(q.excludeExpression, #""newsletter"*"#)
        XCTAssertTrue(q.requiresAttachment)
        XCTAssertNotNil(q.after)
        XCTAssertTrue(SearchQuery(parsing: "  -  \" ").isEmpty)
    }
}

final class SearchFormTests: XCTestCase {
    func testFormBuildsQuery() {
        var form = SearchForm()
        form.from = "dan smith"
        form.to = "alice"
        form.subject = "\"quarterly report\""
        form.hasWords = "budget"
        form.doesntHave = "newsletter \"daily digest\""
        form.sizeValue = "5"
        form.sizeUnit = .mb
        form.hasAttachment = true
        XCTAssertEqual(form.queryString,
            #"from:dan from:smith to:alice subject:"quarterly report" budget -newsletter -"daily digest" larger:5MB has:attachment"#)
        XCTAssertTrue(SearchForm().isEmpty)
    }

    func testRoundTrip() {
        var form = SearchForm()
        form.from = "dan"
        form.subject = "invoice"
        form.hasWords = "cc:bob body:pipeline"
        form.doesntHave = "spam"
        form.sizeComparison = .lessThan
        form.sizeValue = "200"
        form.sizeUnit = .kb
        form.dateRange = .week
        form.dateText = "2019-03-10"
        form.hasAttachment = true
        let parsed = SearchForm(parsing: form.queryString)
        XCTAssertEqual(parsed.from, "dan")
        XCTAssertEqual(parsed.subject, "invoice")
        XCTAssertEqual(parsed.hasWords, "cc:bob body:pipeline")
        XCTAssertEqual(parsed.doesntHave, "spam")
        XCTAssertEqual(parsed.sizeComparison, .lessThan)
        XCTAssertEqual(parsed.sizeValue, "200")
        XCTAssertEqual(parsed.sizeUnit, .kb)
        XCTAssertEqual(parsed.dateRange, .week)
        XCTAssertEqual(parsed.date, form.date)
        XCTAssertTrue(parsed.hasAttachment)
        XCTAssertEqual(parsed.queryString, form.queryString)
    }

    func testDateRangeAndUnmatchedDates() {
        var form = SearchForm()
        form.dateRange = .month
        form.dateText = "2020-06-15"
        XCTAssertEqual(form.queryString, "after:2020-05-15 before:2020-07-16")
        // A hand-typed range that isn't "within X of a date" is kept as text, not lost.
        let odd = SearchForm(parsing: "after:2018-01-01 before:2018-03-07 report")
        XCTAssertEqual(odd.hasWords, "report after:2018-01-01 before:2018-03-07")
        XCTAssertNil(odd.date)
        var bad = SearchForm()
        bad.dateText = "next tuesday"
        XCTAssertTrue(bad.dateIsInvalid)
        XCTAssertEqual(bad.queryString, "")
    }

    func testSizeParsing() {
        XCTAssertEqual(SearchQuery.parseSize("5MB"), 5_000_000)
        XCTAssertEqual(SearchQuery.parseSize("1.5m"), 1_500_000)
        XCTAssertEqual(SearchQuery.parseSize("200k"), 200_000)
        XCTAssertEqual(SearchQuery.parseSize("300"), 300)
        XCTAssertNil(SearchQuery.parseSize("big"))
        let q = SearchQuery(parsing: "larger:1MB smaller:5MB")
        XCTAssertEqual(q.largerThan, 1_000_000)
        XCTAssertEqual(q.smallerThan, 5_000_000)
        XCTAssertNil(q.matchExpression)
    }
}

final class SnippetTests: XCTestCase {
    func testInvisiblePaddingIsDropped() {
        let preheader = String(repeating: "\u{034F}\u{200C} \u{00AD}", count: 40)
        XCTAssertEqual(TextDecoding.snippet(preheader + "Bath spaces these days"), "Bath spaces these days")
        XCTAssertEqual(TextDecoding.snippet(preheader), "")
        XCTAssertEqual(TextDecoding.snippet("Hi\u{00A0}\u{00A0}Rita,\n\n  thanks"), "Hi Rita, thanks")
        XCTAssertEqual(TextDecoding.snippet("Caf\u{00E9} ok 👍🏽"), "Café ok 👍🏽")
    }
}
