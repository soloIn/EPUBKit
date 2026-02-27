//
//  EPUBTableOfContentsParser.swift
//  EPUBKit
//
//  Created by Witek Bobrowski on 30/06/2018.
//  Copyright © 2018 Witek Bobrowski. All rights reserved.
//

import AEXML
import Foundation

/// Protocol defining the interface for parsing EPUB table of contents (NCX) elements.
///
/// The table of contents parser is responsible for extracting hierarchical navigation
/// information from NCX (Navigation Control file for XML applications) documents.
protocol EPUBTableOfContentsParser {
    /// Parses an NCX XML element into an EPUBTableOfContents object.
    ///
    /// - Parameter xmlElement: The root XML element of the NCX document.
    /// - Returns: An `EPUBTableOfContents` object containing the parsed navigation hierarchy.
    func parse(_ xmlElement: AEXMLElement) -> EPUBTableOfContents
}

/// Concrete implementation of `EPUBTableOfContentsParser` that parses NCX navigation files.
///
/// This parser extracts hierarchical navigation information from NCX (Navigation Control file
/// for XML applications) documents. NCX files are used primarily in EPUB 2 for navigation,
/// though they're still supported in EPUB 3 for backward compatibility.
///
/// Expected NCX XML structure:
/// ```xml
/// <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
///     <head>
///         <meta name="dtb:uid" content="urn:uuid:12345678-1234-1234-1234-123456789012"/>
///     </head>
///     <docTitle>
///         <text>Book Title</text>
///     </docTitle>
///     <navMap>
///         <navPoint id="chapter1" playOrder="1">
///             <navLabel>
///                 <text>Chapter 1</text>
///             </navLabel>
///             <content src="chapter1.xhtml"/>
///             <navPoint id="section1" playOrder="2">
///                 <navLabel>
///                     <text>Section 1.1</text>
///                 </navLabel>
///                 <content src="chapter1.xhtml#section1"/>
///             </navPoint>
///         </navPoint>
///     </navMap>
/// </ncx>
/// ```
///
/// The NCX specification is part of the DAISY Digital Talking Book standard and provides
/// a structured way to represent navigation hierarchies in digital publications.
class EPUBTableOfContentsParserImplementation: EPUBTableOfContentsParser {

    /// add epub3 nav case
    func parse(_ xmlElement: AEXMLElement) -> EPUBTableOfContents {
        // 策略选择：根据根节点名称判断是 EPUB 2 (NCX) 还是 EPUB 3 (XHTML)
        if xmlElement.name == "ncx" {
            return parseNCX(xmlElement)
        } else {
            return parseEpub3Nav(xmlElement)
        }
    }
    /// Parses the NCX XML document to extract the complete navigation hierarchy.
    ///
    /// The parsing process:
    /// 1. Extracts the document title from the `<docTitle>` element
    /// 2. Looks for the unique identifier in the `<head>` metadata
    /// 3. Recursively parses the `<navMap>` to build the navigation tree
    /// 4. Creates a root `EPUBTableOfContents` object containing all navigation points
    ///
    /// The NCX format allows for deeply nested navigation structures, where each
    /// `<navPoint>` can contain child `<navPoint>` elements to represent sub-sections,
    /// sub-chapters, or other hierarchical content organization.
    ///
    /// - Parameter xmlElement: The root XML element of the NCX document.
    /// - Returns: An `EPUBTableOfContents` object representing the complete navigation hierarchy.
    func parseNCX(_ xmlElement: AEXMLElement) -> EPUBTableOfContents {
        // STEP 1: Extract the unique identifier from NCX head metadata
        // The dtb:uid meta element should match the dc:identifier in the package document
        // This provides a consistency check between the NCX and OPF files
        // POTENTIAL BUG: The attribute name appears to have a typo - "dtb=uid" should be "dtb:uid"
        // This may cause identifier extraction to fail for properly formatted NCX files
        let item = xmlElement["head"]["meta"]
            .all(withAttributes: ["name": "dtb:uid"])?
            .first?
            .attributes["content"]

        // STEP 2: Create the root table of contents object
        // The NCX docTitle provides the overall publication title for navigation
        // This may differ from the dc:title in metadata if a shorter form is desired
        var tableOfContents = EPUBTableOfContents(
            label: xmlElement["docTitle"]["text"].value ?? "",
            id: "0",  // Root level uses a synthetic ID since NCX root has no id attribute
            item: item,  // Reference to the unique identifier for cross-document validation
            subTable: []  // Will be populated recursively with the navigation hierarchy
        )

        // STEP 3: Recursively parse the navigation map to build the complete hierarchy
        // The navMap contains the root-level navPoints, each of which may contain
        // nested navPoints creating a tree structure for complex documents
        tableOfContents.subTable = evaluateChildren(from: xmlElement["navMap"])

        return tableOfContents
    }

    /// 解析 EPUB 3 导航文档 (nav.xhtml)
    /// 结构通常为: <nav epub:type="toc"><ol><li><a href="...">Title</a></li></ol></nav>
    private func parseEpub3Nav(_ xmlElement: AEXMLElement)
        -> EPUBTableOfContents
    {
        // 1. 寻找 <nav> 元素
        // <nav> 可能在 html -> body -> nav，也可能被 section 包裹，这里做一个简单的路径查找
        // 优先查找带有 epub:type="toc" 的 nav，如果 AEXML 处理命名空间有问题，则降级查找普通 nav
        var navElement: AEXMLElement?

        // 尝试从 body 查找
        let body = xmlElement["body"]

        // 查找所有 nav 元素
        if let navs = body["nav"].all {
            // 优先找 toc 类型的 nav
            navElement =
                navs.first(where: { $0.attributes["epub:type"] == "toc" })
                ?? navs.first
        } else if let nestedNav = body["section"]["nav"].first {
            // 处理一些非标准的嵌套情况
            navElement = nestedNav
        }

        // 如果找不到 nav 标签，尝试直接解析 body（容错）
        let rootNav = navElement ?? body

        // 2. 获取标题 (通常在 nav 之前的 h1/h2 或 title 标签，EPUB3 Nav doc 标题提取比较模糊，这里取页面 title)
        let docTitle = xmlElement["head"]["title"].value ?? "Table of Contents"

        var tableOfContents = EPUBTableOfContents(
            label: docTitle,
            id: "0",
            item: nil,  // Nav doc 通常没有 dtb:uid
            subTable: []
        )

        // 3. 递归解析 <ol> 列表
        if let rootList = rootNav["ol"].first {
            tableOfContents.subTable = evaluateNavChildren(from: rootList)
        }

        return tableOfContents
    }

}

extension EPUBTableOfContentsParserImplementation {

    /// Recursively evaluates navigation points to build the hierarchical table of contents.
    ///
    /// This method processes `<navPoint>` elements within the NCX document, extracting:
    /// - Navigation labels (display text for the table of contents)
    /// - Content sources (file paths or URLs to the actual content)
    /// - Unique identifiers for each navigation point
    /// - Nested navigation points for sub-sections
    ///
    /// The recursive nature allows for unlimited nesting depth, supporting complex
    /// document structures with multiple levels of organization (parts, chapters,
    /// sections, subsections, etc.).
    ///
    /// Each navPoint structure in NCX:
    /// ```xml
    /// <navPoint id="unique-id" playOrder="sequence-number">
    ///     <navLabel>
    ///         <text>Display Text</text>
    ///     </navLabel>
    ///     <content src="path/to/content.xhtml#optional-fragment"/>
    ///     <!-- Optional nested navPoints -->
    /// </navPoint>
    /// ```
    ///
    /// - Parameter xmlElement: The XML element containing navPoint children (navMap or navPoint).
    /// - Returns: An array of `EPUBTableOfContents` objects representing the navigation hierarchy.
    private func evaluateChildren(from xmlElement: AEXMLElement)
        -> [EPUBTableOfContents]
    {
        // STEP 1: Get all navPoint elements from the current level
        // Return empty array if no navPoints exist (base case for recursion)
        guard let points = xmlElement["navPoint"].all else { return [] }

        // STEP 2: Process each navPoint to create table of contents entries
        // This mapping operation transforms XML navPoint elements into our domain model
        let subs: [EPUBTableOfContents] = points.map { point in
            EPUBTableOfContents(
                // Extract the display label from navLabel/text
                // This is the text that will be shown in the table of contents UI
                // Fallback to empty string for malformed NCX files
                label: point["navLabel"]["text"].value ?? "",

                // Extract the unique ID attribute (required by NCX specification)
                // Force unwrap is safe here because valid NCX files must have IDs
                // Invalid NCX files should fail fast rather than continue with corrupted data
                id: point.attributes["id"]!,

                // Extract the content source from the content element
                // This href points to the actual XHTML content file, potentially with a fragment identifier
                // The src attribute is required by NCX spec, so force unwrap is appropriate
                item: point["content"].attributes["src"]!,

                // RECURSIVE STEP: Process any nested navPoints
                // This is the core of the recursive algorithm - each navPoint can contain
                // child navPoints, creating unlimited nesting depth for complex documents
                // The recursion naturally handles the tree traversal and construction
                subTable: evaluateChildren(from: point)
            )
        }

        return subs
    }

    /// 递归解析 <ol> -> <li> 结构
    private func evaluateNavChildren(from olElement: AEXMLElement)
        -> [EPUBTableOfContents]
    {
        guard let listItems = olElement["li"].all else { return [] }

        return listItems.compactMap { li -> EPUBTableOfContents? in
            // EPUB 3 标准：li 内部必须包含一个 <a> (链接) 或者 <span> (仅标题)
            // 且可能包含另一个 <ol> (子目录)

            var label: String = ""
            var src: String = ""

            // 尝试获取 <a> 标签
            if let anchor = li["a"].first {
                label = anchor.value ?? ""
                src = anchor.attributes["href"] ?? ""
            }
            // 如果没有 <a>，尝试获取 <span> (非可点击的分类标题)
            else if let span = li["span"].first {
                label = span.value ?? ""
                // 对于 span，没有跳转链接，我们可以留空或指向当前 nav 文件
            } else {
                // 如果既没有 a 也没有 span，直接取 li 的文本（容错）
                label = li.value ?? ""
            }

            // 如果标签和链接都为空，可能是一个纯粹的嵌套容器，跳过或保留视需求而定
            if label.isEmpty && src.isEmpty { return nil }

            // 递归查找嵌套的 <ol>
            let subTable = evaluateNavChildren(from: li["ol"])

            return EPUBTableOfContents(
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                id: UUID().uuidString,  // EPUB 3 li 通常没有 ID，生成一个临时的
                item: src,
                subTable: subTable
            )
        }
    }

}
