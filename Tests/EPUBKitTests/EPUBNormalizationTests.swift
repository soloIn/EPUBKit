import AEXML
import Foundation
import Testing
@testable import EPUBKit

@Suite("EPUB Normalization Tests", .serialized)
struct EPUBNormalizationTests {

    @Test("Parser normalizes anchor-split chapters and keeps API-compatible outputs")
    func parserNormalizesAnchorSplitChapters() throws {
        let epubDirectory = try makeAnchorSplitEPUBDirectory(includeNav: true)
        defer { try? FileManager.default.removeItem(at: epubDirectory) }

        let document = try EPUBParser().parse(documentAt: epubDirectory)

        #expect(document.spine.pageProgressionDirection == .rightToLeft)
        #expect(document.spine.items.count == 5)

        let chapterItems = document.manifest.items.values.filter { item in
            item.path.contains("chapter_") && item.mediaType == .xHTML
        }
        #expect(chapterItems.count == 5)
        #expect(document.manifest.items.values.contains(where: { $0.path == "nav.xhtml" }))
        #expect(document.manifest.items.values.contains(where: { $0.path == "toc.ncx" }))

        let coverPath = try tocItemPath(label: "Cover", in: document.tableOfContents)
        #expect(!coverPath.contains("#"))
        let coverHTML = try String(
            contentsOf: document.contentDirectory.appendingPathComponent(coverPath),
            encoding: .utf8
        )
        #expect(!coverHTML.contains("<p>28</p>"))
        #expect(!coverHTML.contains("href=\"#p34\""))

        let chapter1Path = try tocItemPath(label: "Chapter 1", in: document.tableOfContents)
        let chapter1HTML = try String(
            contentsOf: document.contentDirectory.appendingPathComponent(chapter1Path),
            encoding: .utf8
        )
        #expect(chapter1HTML.contains("<img"))
    }

    @Test("TOC locator selection prefers nav over spine.toc NCX")
    func tocSelectionPrefersNav() throws {
        let epubDirectory = try makeAnchorSplitEPUBDirectory(includeNav: true)
        defer { try? FileManager.default.removeItem(at: epubDirectory) }

        let document = try EPUBParser().parse(documentAt: epubDirectory)

        // nav.xhtml title should win over NCX title when both exist.
        #expect(document.tableOfContents.label == "Navigation TOC")
    }

    @Test("NCX parser reads dtb:uid meta correctly")
    func ncxParserReadsDtbUID() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="urn:book:uid:123"/>
          </head>
          <docTitle><text>Book</text></docTitle>
          <navMap>
            <navPoint id="n1">
              <navLabel><text>One</text></navLabel>
              <content src="chapter1.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """

        let root = try AEXMLDocument(xml: Data(xml.utf8)).root
        let parser = EPUBTableOfContentsParserImplementation()
        let toc = parser.parse(root)

        #expect(toc.item == "urn:book:uid:123")
    }

    @Test("Spine parser reads page-progression-direction attribute")
    func spineParserReadsPageDirectionAttribute() throws {
        let xml = """
        <spine toc="ncx" page-progression-direction="rtl">
          <itemref idref="chapter1"/>
        </spine>
        """

        let element = try AEXMLDocument(xml: Data(xml.utf8)).root
        let parser = EPUBSpineParserImplementation()
        let spine = parser.parse(element)

        #expect(spine.pageProgressionDirection == .rightToLeft)
    }
}

private extension EPUBNormalizationTests {

    func makeAnchorSplitEPUBDirectory(includeNav: Bool) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epubkit-normalize-\(UUID().uuidString)")
        let metaInf = root.appendingPathComponent("META-INF")
        let oebps = root.appendingPathComponent("OEBPS")
        let text = oebps.appendingPathComponent("Text")

        try fm.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try fm.createDirectory(at: text, withIntermediateDirectories: true)

        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """,
            to: metaInf.appendingPathComponent("container.xml")
        )

        let navManifestItem = includeNav
            ? #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
            : ""
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="BookId" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Normalization Fixture</dc:title>
                <dc:identifier id="BookId">urn:test:normalize</dc:identifier>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="split" href="Text/index_split_000.html" media-type="application/xhtml+xml"/>
                <item id="appendix" href="Text/appendix.xhtml" media-type="application/xhtml+xml"/>
                <item id="style" href="Text/book.css" media-type="text/css"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                \(navManifestItem)
              </manifest>
              <spine toc="ncx" page-progression-direction="rtl">
                <itemref idref="split" linear="yes"/>
                <itemref idref="appendix" linear="no"/>
              </spine>
            </package>
            """,
            to: oebps.appendingPathComponent("content.opf")
        )

        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head>
                <meta name="dtb:uid" content="urn:test:normalize"/>
              </head>
              <docTitle><text>NCX Fallback TOC</text></docTitle>
              <navMap>
                <navPoint id="fallback-1">
                  <navLabel><text>Fallback Chapter</text></navLabel>
                  <content src="Text/index_split_000.html#p10"/>
                </navPoint>
              </navMap>
            </ncx>
            """,
            to: oebps.appendingPathComponent("toc.ncx")
        )

        if includeNav {
            try write(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                  <head><title>Navigation TOC</title></head>
                  <body>
                    <nav epub:type="toc">
                      <ol>
                        <li><a href="Text/index_split_000.html#cover">Cover</a></li>
                        <li><a href="Text/index_split_000.html#p10">Chapter 1</a></li>
                        <li>
                          <a href="Text/index_split_000.html#p23">Chapter 2</a>
                          <ol>
                            <li><a href="Text/index_split_000.html#p30">Section 2.1</a></li>
                          </ol>
                        </li>
                        <li><a href="Text/appendix.xhtml">Appendix</a></li>
                      </ol>
                    </nav>
                  </body>
                </html>
                """,
                to: oebps.appendingPathComponent("nav.xhtml")
            )
        }

        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head>
                <title>Split</title>
                <link rel="stylesheet" href="book.css" type="text/css"/>
              </head>
              <body>
                <p id="cover">Cover page</p>
                <p><a href="#p34">Ice Cream</a></p>
                <p>28</p>
                <h1 id="p10">Chapter 1</h1>
                <p>Body paragraph<img src="img.png" alt="x"/></p>
                <h1 id="p23">Chapter 2</h1>
                <p>Chapter 2 text</p>
                <h2 id="p30">Section 2.1</h2>
                <p>Section 2.1 text</p>
                <h2 id="p34">Appendix Jump Target</h2>
              </body>
            </html>
            """,
            to: text.appendingPathComponent("index_split_000.html")
        )

        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Appendix</title></head>
              <body><p>Appendix body</p></body>
            </html>
            """,
            to: text.appendingPathComponent("appendix.xhtml")
        )

        try write("body { font-family: serif; }", to: text.appendingPathComponent("book.css"))

        return root
    }

    func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func tocItemPath(label: String, in toc: EPUBTableOfContents) throws -> String {
        if toc.label == label, let item = toc.item, !item.isEmpty {
            return item
        }

        if let children = toc.subTable {
            for child in children {
                if let found = try? tocItemPath(label: label, in: child) {
                    return found
                }
            }
        }

        throw NSError(domain: "EPUBNormalizationTests", code: 404)
    }
}
