import Foundation

struct EPUBNormalizationResult {
    let manifest: EPUBManifest
    let spine: EPUBSpine
    let tableOfContents: EPUBTableOfContents
}

final class EPUBChapterStandardizer {

    private struct TOCLocator {
        let tocID: String
        let filePath: String
        let fragment: String?
        let canonicalKey: String
    }

    private struct SourceDocument {
        let htmlAttributes: String
        let headInner: String
        let bodyAttributes: String
        let bodyInner: String
    }

    private struct ChapterOutput {
        let manifestID: String
        let filePath: String
        let sourceFilePath: String
        let linear: Bool
    }

    func normalize(
        contentDirectory: URL,
        tocPath: String,
        manifest: EPUBManifest,
        spine: EPUBSpine,
        tableOfContents: EPUBTableOfContents
    ) throws -> EPUBNormalizationResult? {
        let tocDirectory = contentDirectory
            .appendingPathComponent(tocPath)
            .deletingLastPathComponent()

        let locators = flattenTOC(
            tableOfContents,
            tocDirectory: tocDirectory,
            contentDirectory: contentDirectory
        )

        guard !locators.isEmpty else { return nil }

        let groupedByFile = Dictionary(
            grouping: locators.filter { $0.fragment?.isEmpty == false },
            by: { $0.filePath }
        )

        // Only normalize when TOC points to multiple anchors inside at least one file.
        guard groupedByFile.values.contains(where: { $0.count > 1 }) else {
            return nil
        }

        let linearBySourcePath = linearMapBySourcePath(manifest: manifest, spine: spine)

        let uniqueLocators = deduplicateLocators(locators)
        var chapterOutputs: [ChapterOutput] = []
        var chapterPathByCanonicalKey: [String: String] = [:]
        var nextIndex = 1

        let locatorsByFile = Dictionary(grouping: uniqueLocators, by: { $0.filePath })
        var sourceDocumentCache: [String: SourceDocument] = [:]

        for locator in uniqueLocators {
            guard let fileLocators = locatorsByFile[locator.filePath],
                  let localIndex = fileLocators.firstIndex(where: { $0.canonicalKey == locator.canonicalKey })
            else {
                continue
            }

            let sourceDocument: SourceDocument
            if let cached = sourceDocumentCache[locator.filePath] {
                sourceDocument = cached
            } else {
                let sourceURL = contentDirectory.appendingPathComponent(locator.filePath)
                let sourceHTML = try String(contentsOf: sourceURL, encoding: .utf8)
                guard let parsed = parseSourceDocument(sourceHTML) else {
                    return nil
                }
                sourceDocument = parsed
                sourceDocumentCache[locator.filePath] = parsed
            }

            let startOffset = try findBoundary(
                for: locator,
                in: sourceDocument.bodyInner,
                defaultOffset: 0
            )
            let endOffset: Int
            if localIndex + 1 < fileLocators.count {
                let nextLocator = fileLocators[localIndex + 1]
                endOffset = try findBoundary(
                    for: nextLocator,
                    in: sourceDocument.bodyInner,
                    defaultOffset: sourceDocument.bodyInner.utf16.count
                )
            } else {
                endOffset = sourceDocument.bodyInner.utf16.count
            }

            guard startOffset < endOffset,
                  let rawSlice = substring(
                      sourceDocument.bodyInner,
                      fromUTF16: startOffset,
                      toUTF16: endOffset
                  )
            else {
                return nil
            }

            let cleanedSlice = cleanChapterHTML(rawSlice)
            let chapterPath = chapterFilePath(
                for: locator.filePath,
                index: nextIndex
            )

            let chapterHTML = buildChapterDocument(
                source: sourceDocument,
                bodyFragment: cleanedSlice
            )

            let chapterURL = contentDirectory.appendingPathComponent(chapterPath)
            try chapterHTML.write(to: chapterURL, atomically: true, encoding: .utf8)

            let chapterID = String(format: "std_chapter_%04d", nextIndex)
            chapterOutputs.append(
                ChapterOutput(
                    manifestID: chapterID,
                    filePath: chapterPath,
                    sourceFilePath: locator.filePath,
                    linear: linearBySourcePath[locator.filePath] ?? true
                )
            )
            chapterPathByCanonicalKey[locator.canonicalKey] = chapterPath
            nextIndex += 1
        }

        guard !chapterOutputs.isEmpty else { return nil }

        let tocPathByID: [String: String] = Dictionary(uniqueKeysWithValues: locators.compactMap { locator in
            guard let chapterPath = chapterPathByCanonicalKey[locator.canonicalKey] else {
                return nil
            }
            return (locator.tocID, chapterPath)
        })

        let updatedTOC = rewriteTOC(tableOfContents, mappingByID: tocPathByID)

        let replacedSourcePaths = Set(chapterOutputs.map { $0.sourceFilePath })
        var updatedManifestItems: [String: EPUBManifestItem] = [:]

        for (id, item) in manifest.items {
            let isReplacedChapter =
                replacedSourcePaths.contains(item.path)
                && item.mediaType == .xHTML
                && !(item.property?.contains("nav") == true)

            if !isReplacedChapter {
                updatedManifestItems[id] = item
            }
        }

        for output in chapterOutputs {
            var chapterID = output.manifestID
            var suffix = 1
            while updatedManifestItems[chapterID] != nil {
                chapterID = "\(output.manifestID)_\(suffix)"
                suffix += 1
            }

            updatedManifestItems[chapterID] = EPUBManifestItem(
                id: chapterID,
                path: output.filePath,
                mediaType: .xHTML,
                property: nil
            )
        }

        let manifestIDByChapterPath: [String: String] = Dictionary(
            uniqueKeysWithValues: updatedManifestItems.values.map { ($0.path, $0.id) }
        )

        var newSpineItems: [EPUBSpineItem] = chapterOutputs.compactMap { output in
            guard let idref = manifestIDByChapterPath[output.filePath] else { return nil }
            return EPUBSpineItem(id: nil, idref: idref, linear: output.linear)
        }

        for originalSpineItem in spine.items {
            guard let originalPath = manifest.items[originalSpineItem.idref]?.path else {
                continue
            }
            if replacedSourcePaths.contains(originalPath) {
                continue
            }
            if updatedManifestItems[originalSpineItem.idref] == nil {
                continue
            }
            newSpineItems.append(originalSpineItem)
        }

        let updatedManifest = EPUBManifest(id: manifest.id, items: updatedManifestItems)
        let updatedSpine = EPUBSpine(
            id: spine.id,
            toc: spine.toc,
            pageProgressionDirection: spine.pageProgressionDirection,
            items: newSpineItems
        )

        return EPUBNormalizationResult(
            manifest: updatedManifest,
            spine: updatedSpine,
            tableOfContents: updatedTOC
        )
    }
}

private extension EPUBChapterStandardizer {

    private func flattenTOC(
        _ root: EPUBTableOfContents,
        tocDirectory: URL,
        contentDirectory: URL
    ) -> [TOCLocator] {
        var result: [TOCLocator] = []
        var currentFilePath: String?

        func walk(_ node: EPUBTableOfContents) {
            if let source = node.item?.trimmingCharacters(in: .whitespacesAndNewlines),
               !source.isEmpty,
               let resolved = resolveTOCTarget(
                   source,
                   tocDirectory: tocDirectory,
                   contentDirectory: contentDirectory,
                   inheritedFilePath: currentFilePath
               ) {
                currentFilePath = resolved.filePath
                result.append(
                    TOCLocator(
                        tocID: node.id,
                        filePath: resolved.filePath,
                        fragment: resolved.fragment,
                        canonicalKey: canonicalKey(
                            filePath: resolved.filePath,
                            fragment: resolved.fragment
                        )
                    )
                )
            }

            node.subTable?.forEach { walk($0) }
        }

        root.subTable?.forEach { walk($0) }
        return result
    }

    private func deduplicateLocators(_ locators: [TOCLocator]) -> [TOCLocator] {
        var seen: Set<String> = []
        var deduped: [TOCLocator] = []

        for locator in locators {
            if seen.insert(locator.canonicalKey).inserted {
                deduped.append(locator)
            }
        }
        return deduped
    }

    func linearMapBySourcePath(
        manifest: EPUBManifest,
        spine: EPUBSpine
    ) -> [String: Bool] {
        var map: [String: Bool] = [:]

        for spineItem in spine.items {
            guard let path = manifest.items[spineItem.idref]?.path else { continue }
            if map[path] == nil {
                map[path] = spineItem.linear
            }
        }

        return map
    }

    func resolveTOCTarget(
        _ source: String,
        tocDirectory: URL,
        contentDirectory: URL,
        inheritedFilePath: String?
    ) -> (filePath: String, fragment: String?)? {
        let parts = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawFile = parts.first.map(String.init) ?? ""
        let rawFragment = parts.count > 1 ? String(parts[1]) : nil
        let decodedRawFile = rawFile.removingPercentEncoding ?? rawFile

        let filePath: String
        if decodedRawFile.isEmpty {
            guard let inheritedFilePath else { return nil }
            filePath = inheritedFilePath
        } else {
            let absolute = tocDirectory.appendingPathComponent(decodedRawFile).standardizedFileURL
            guard let relative = relativize(url: absolute, to: contentDirectory) else {
                return nil
            }
            filePath = relative
        }

        return (
            filePath,
            rawFragment?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func relativize(url: URL, to base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let absolutePath = url.standardizedFileURL.path
        guard absolutePath.hasPrefix(basePath) else { return nil }

        var relative = String(absolutePath.dropFirst(basePath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }

    func canonicalKey(filePath: String, fragment: String?) -> String {
        if let fragment, !fragment.isEmpty {
            return "\(filePath)#\(fragment)"
        }
        return filePath
    }

    private func parseSourceDocument(_ html: String) -> SourceDocument? {
        guard let htmlAttributes = firstMatch(in: html, pattern: #"(?is)<html\b([^>]*)>"#, group: 1),
              let headInner = firstMatch(in: html, pattern: #"(?is)<head\b[^>]*>(.*?)</head>"#, group: 1),
              let bodyAttributes = firstMatch(in: html, pattern: #"(?is)<body\b([^>]*)>"#, group: 1),
              let bodyInner = firstMatch(in: html, pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#, group: 1)
        else {
            return nil
        }

        return SourceDocument(
            htmlAttributes: htmlAttributes,
            headInner: headInner,
            bodyAttributes: bodyAttributes,
            bodyInner: bodyInner
        )
    }

    func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range(at: group), in: text)
        else {
            return nil
        }

        return String(text[range])
    }

    private func findBoundary(
        for locator: TOCLocator,
        in body: String,
        defaultOffset: Int
    ) throws -> Int {
        guard let fragment = locator.fragment, !fragment.isEmpty else {
            return defaultOffset
        }

        if let offset = findAnchorOffset(fragment: fragment, in: body) {
            return offset
        }

        throw EPUBParserError.tableOfContentsMissing
    }

    func findAnchorOffset(fragment: String, in text: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: fragment)
        let patterns = [
            #"(?is)<[^>]*\bid\s*=\s*"# + #"[\"']"# + escaped + #"[\"'][^>]*>"#,
            #"(?is)<[^>]*\bname\s*=\s*"# + #"[\"']"# + escaped + #"[\"'][^>]*>"#
        ]

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            if let match = regex.firstMatch(in: text, options: [], range: nsRange) {
                return match.range.location
            }
        }

        return nil
    }

    func substring(_ text: String, fromUTF16 start: Int, toUTF16 end: Int) -> String? {
        guard start >= 0,
              end >= start,
              end <= text.utf16.count
        else {
            return nil
        }
        
        let utf16 = text.utf16
        guard let startUTF16 = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
              let endUTF16 = utf16.index(utf16.startIndex, offsetBy: end, limitedBy: utf16.endIndex),
              let startIndex = String.Index(startUTF16, within: text),
              let endIndex = String.Index(endUTF16, within: text)
        else { return nil }

        return String(text[startIndex..<endIndex])
    }

    func chapterFilePath(for sourcePath: String, index: Int) -> String {
        let directory = (sourcePath as NSString).deletingLastPathComponent
        let fileName = String(format: "chapter_%04d.xhtml", index)
        if directory.isEmpty || directory == "." {
            return fileName
        }
        return (directory as NSString).appendingPathComponent(fileName)
    }

    private func buildChapterDocument(source: SourceDocument, bodyFragment: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html\(source.htmlAttributes)>
        <head>\(source.headInner)</head>
        <body\(source.bodyAttributes)>\(bodyFragment)</body>
        </html>
        """
    }

    func cleanChapterHTML(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<p\b([^>]*)>(.*?)</p>"#,
            options: []
        ) else {
            return html
        }

        var result = html
        let matches = regex.matches(
            in: result,
            options: [],
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let paragraph = String(result[fullRange])

            if shouldRemoveParagraph(paragraph) {
                result.removeSubrange(fullRange)
            }
        }

        return result
    }

    func shouldRemoveParagraph(_ paragraph: String) -> Bool {
        let lower = paragraph.lowercased()

        // Safety guards: keep any paragraph that anchors structure or embeds images.
        if lower.contains("<img") || paragraph.range(of: #"(?is)\bid\s*=\s*['"][^'"]+['"]"#, options: .regularExpression) != nil {
            return false
        }

        let inner = paragraph
            .replacingOccurrences(
                of: #"(?is)^<p\b[^>]*>|</p>$"#,
                with: "",
                options: .regularExpression
            )

        let textOnly = inner
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove pure numeric page number paragraphs.
        if textOnly.range(of: #"^\d{1,6}$"#, options: .regularExpression) != nil {
            return true
        }

        let compactInner = inner.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove paragraphs that only contain internal anchor links.
        let internalOnlyPattern = #"(?is)^<a\b[^>]*href\s*=\s*['\"]#[^'\"]+['\"][^>]*>.*?</a>$"#
        if compactInner.range(of: internalOnlyPattern, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    func rewriteTOC(
        _ node: EPUBTableOfContents,
        mappingByID: [String: String]
    ) -> EPUBTableOfContents {
        var updated = node

        if let rewritten = mappingByID[node.id] {
            updated.item = rewritten
        }

        if let children = node.subTable {
            updated.subTable = children.map { rewriteTOC($0, mappingByID: mappingByID) }
        }

        return updated
    }
}
