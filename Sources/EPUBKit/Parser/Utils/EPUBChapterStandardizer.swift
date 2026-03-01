import AEXML
import Foundation

/// 标准化后的 EPUB 核心结构输出。
struct EPUBNormalizationResult {
    let manifest: EPUBManifest
    let spine: EPUBSpine
    let tableOfContents: EPUBTableOfContents
}

/// 将“单 HTML 多锚点章节”标准化为“每章独立 XHTML”。
///
/// 设计目标：
/// - 外部 API 保持不变（`EPUBParser` 与 `EPUBDocument` 不变）
/// - 优先基于 TOC 分章并保持层级
/// - 在内存中同步更新 `manifest/spine/tableOfContents`
final class EPUBChapterStandardizer {

    private struct TOCLocator {
        let tocID: String?
        let label: String?
        let level: Int
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
        let kind: ChapterKind
        let excludeFromSpine: Bool
    }
    
    private struct ResolvedLocator {
        let locator: TOCLocator
        let startOffset: Int
    }
    
    /// Internal structural classification used for normalization decisions.
    /// This is intentionally internal-only to keep public API unchanged.
    private enum ChapterKind: String {
        case frontmatter
        case bodymatter
        case backmatter
        case reference
    }

    // MARK: - 标准化主流程

    /// 执行章节标准化。
    ///
    /// - Returns: 若不满足标准化条件（例如非锚点分章 EPUB）返回 `nil`，否则返回重写后的结构。
    func normalize(
        contentDirectory: URL,
        tocPath: String,
        navPath: String?,
        guideElement: AEXMLElement?,
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

        // 仅当同一文件存在多个 TOC 锚点时才进入切章逻辑。
        let groupedByFile = Dictionary(
            grouping: locators.filter { $0.fragment?.isEmpty == false },
            by: { $0.filePath }
        )

        // 至少一个文件包含多个 TOC 锚点时，才有必要进行分章标准化。
        guard groupedByFile.values.contains(where: { $0.count > 1 }) else {
            return nil
        }

        let linearBySourcePath = linearMapBySourcePath(manifest: manifest, spine: spine)
        let semanticByCanonicalKey = buildSemanticHints(
            contentDirectory: contentDirectory,
            navPath: navPath,
            guideElement: guideElement,
            tocLocators: locators
        )
        let coverCanonicalKeys = buildCoverHints(
            contentDirectory: contentDirectory,
            navPath: navPath,
            guideElement: guideElement,
            tocLocators: locators
        )

        let uniqueLocators = deduplicateLocators(locators)
        var chapterOutputs: [ChapterOutput] = []
        var chapterPathByCanonicalKey: [String: String] = [:]
        var removedTOCIDs: Set<String> = []
        var nextIndex = 1

        let orderedFiles = uniqueLocators.map(\.filePath).reduce(into: [String]()) { partial, path in
            if !partial.contains(path) { partial.append(path) }
        }
        var sourceDocumentCache: [String: SourceDocument] = [:]
        
        for filePath in orderedFiles {
            let tocFileLocators = uniqueLocators.filter { $0.filePath == filePath }
            guard !tocFileLocators.isEmpty else {
                continue
            }
            
            let sourceDocument: SourceDocument
            if let cached = sourceDocumentCache[filePath] {
                sourceDocument = cached
            } else {
                let sourceURL = contentDirectory.appendingPathComponent(filePath)
                let sourceHTML = try String(contentsOf: sourceURL, encoding: .utf8)
                guard let parsed = parseSourceDocument(sourceHTML) else {
                    return nil
                }
                sourceDocument = parsed
                sourceDocumentCache[filePath] = parsed
            }
            let resolvedLocators = tocFileLocators.map { locator in
                let boundary = findBoundary(
                    for: locator,
                    in: sourceDocument.bodyInner,
                    defaultOffset: 0
                ) ?? 0
                return ResolvedLocator(locator: locator, startOffset: boundary)
            }
            
            let orderedLocators = resolvedLocators.sorted { lhs, rhs in
                if lhs.startOffset != rhs.startOffset {
                    return lhs.startOffset < rhs.startOffset
                }
                return lhs.locator.canonicalKey < rhs.locator.canonicalKey
            }
            
            var index = 0
            var lastChapterPath: String?
            while index < orderedLocators.count {
                let startOffset = orderedLocators[index].startOffset
                var endOfSameStart = index + 1
                while endOfSameStart < orderedLocators.count
                    && orderedLocators[endOfSameStart].startOffset == startOffset
                {
                    endOfSameStart += 1
                }
                
                var nextGreater = endOfSameStart
                while nextGreater < orderedLocators.count
                    && orderedLocators[nextGreater].startOffset <= startOffset
                {
                    nextGreater += 1
                }
                let endOffset = nextGreater < orderedLocators.count
                    ? orderedLocators[nextGreater].startOffset
                    : sourceDocument.bodyInner.utf16.count
                
                let sharedLocators = orderedLocators[index..<endOfSameStart].map(\.locator)
                let primaryLocator = sharedLocators.first!
                
                let normalizedSlice: String?
                if startOffset < endOffset,
                   let rawSlice = substring(
                       sourceDocument.bodyInner,
                       fromUTF16: startOffset,
                       toUTF16: endOffset
                   )
                {
                    let cleanedSlice = cleanChapterHTML(
                        rawSlice,
                        tocLabel: primaryLocator.label ?? ""
                    )
                    let withHeading = injectHeadingIfNeeded(
                        in: cleanedSlice,
                        locator: primaryLocator
                    )
                    normalizedSlice = normalizeFragmentMarkup(withHeading)
                } else {
                    normalizedSlice = nil
                }
                
                if let normalizedSlice,
                   !isEffectivelyEmptyChapter(normalizedSlice),
                   !isTOCHeadingOnlyChapter(
                       normalizedSlice,
                       tocLabel: primaryLocator.label ?? ""
                   )
                {
                    let chapterPath = chapterFilePath(
                        for: primaryLocator.filePath,
                        index: nextIndex
                    )
                    
                    let chapterHTML = buildChapterDocument(
                        source: sourceDocument,
                        bodyFragment: normalizedSlice
                    )
                    
                    let chapterURL = contentDirectory.appendingPathComponent(chapterPath)
                    try chapterHTML.write(to: chapterURL, atomically: true, encoding: .utf8)
                    
                    let chapterID = String(format: "std_chapter_%03d", nextIndex)
                    let kind = classifyChapterKind(
                        locators: sharedLocators,
                        semanticByCanonicalKey: semanticByCanonicalKey
                    )
                    let excludeFromSpine = shouldExcludeFromSpine(
                        kind: kind,
                        locators: sharedLocators,
                        coverCanonicalKeys: coverCanonicalKeys
                    )
                    chapterOutputs.append(
                        ChapterOutput(
                            manifestID: chapterID,
                            filePath: chapterPath,
                            sourceFilePath: primaryLocator.filePath,
                            linear: linearBySourcePath[primaryLocator.filePath] ?? true,
                            kind: kind,
                            excludeFromSpine: excludeFromSpine
                        )
                    )
                    for locator in sharedLocators {
                        chapterPathByCanonicalKey[locator.canonicalKey] = chapterPath
                    }
                    lastChapterPath = chapterPath
                    nextIndex += 1
                } else if let fallbackPath = lastChapterPath {
                    for locator in sharedLocators {
                        chapterPathByCanonicalKey[locator.canonicalKey] = fallbackPath
                    }
                } else {
                    if let firstOutput = chapterOutputs.first(where: { $0.sourceFilePath == filePath }) {
                        for locator in sharedLocators {
                            chapterPathByCanonicalKey[locator.canonicalKey] = firstOutput.filePath
                        }
                    } else {
                        // 最后兜底：至少保留该源文件完整正文，避免内容丢失。
                        let fallbackBody = normalizeFragmentMarkup(sourceDocument.bodyInner)
                        if !isEffectivelyEmptyChapter(fallbackBody) {
                            let chapterPath = chapterFilePath(
                                for: primaryLocator.filePath,
                                index: nextIndex
                            )
                            let chapterHTML = buildChapterDocument(
                                source: sourceDocument,
                                bodyFragment: fallbackBody
                            )
                            let chapterURL = contentDirectory.appendingPathComponent(chapterPath)
                            try chapterHTML.write(to: chapterURL, atomically: true, encoding: .utf8)
                            
                            let chapterID = String(format: "std_chapter_%04d", nextIndex)
                            let kind = classifyChapterKind(
                                locators: sharedLocators,
                                semanticByCanonicalKey: semanticByCanonicalKey
                            )
                            let excludeFromSpine = shouldExcludeFromSpine(
                                kind: kind,
                                locators: sharedLocators,
                                coverCanonicalKeys: coverCanonicalKeys
                            )
                            chapterOutputs.append(
                                ChapterOutput(
                                    manifestID: chapterID,
                                    filePath: chapterPath,
                                    sourceFilePath: primaryLocator.filePath,
                                    linear: linearBySourcePath[primaryLocator.filePath] ?? true,
                                    kind: kind,
                                    excludeFromSpine: excludeFromSpine
                                )
                            )
                            for locator in sharedLocators {
                                chapterPathByCanonicalKey[locator.canonicalKey] = chapterPath
                            }
                            lastChapterPath = chapterPath
                            nextIndex += 1
                        } else {
                            for locator in sharedLocators {
                                if let tocID = locator.tocID {
                                    removedTOCIDs.insert(tocID)
                                }
                            }
                        }
                    }
                }
                
                index = endOfSameStart
            }
        }

        guard !chapterOutputs.isEmpty else { return nil }

        let tocPathByID: [String: String] = Dictionary(uniqueKeysWithValues: locators.compactMap { locator in
            guard let tocID = locator.tocID else { return nil }
            guard let chapterPath = chapterPathByCanonicalKey[locator.canonicalKey] else {
                return nil
            }
            return (tocID, chapterPath)
        })

        guard let updatedTOC = rewriteTOC(
            tableOfContents,
            mappingByID: tocPathByID,
            removedIDs: removedTOCIDs
        ) else {
            return nil
        }

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

        var newSpineItems: [EPUBSpineItem] = []
        let chapterOutputsBySourcePath = Dictionary(grouping: chapterOutputs, by: { $0.sourceFilePath })
        
        // 保持原 spine 顺序：命中被替换源文件时，在原位置展开新章节。
        for originalSpineItem in spine.items {
            guard let originalPath = manifest.items[originalSpineItem.idref]?.path else {
                continue
            }
            
            if let replacements = chapterOutputsBySourcePath[originalPath], !replacements.isEmpty {
                for output in replacements {
                    if output.excludeFromSpine {
                        continue
                    }
                    guard let idref = manifestIDByChapterPath[output.filePath] else { continue }
                    newSpineItems.append(EPUBSpineItem(id: nil, idref: idref, linear: output.linear))
                }
                continue
            }
            
            if updatedManifestItems[originalSpineItem.idref] != nil {
                if shouldExcludeOriginalSpineItem(
                    path: originalPath,
                    coverCanonicalKeys: coverCanonicalKeys
                ) {
                    continue
                }
                newSpineItems.append(originalSpineItem)
            }
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

    // MARK: - TOC 展开与路径解析

    /// 深度优先展开目录树并生成定位器列表。
    ///
    /// 解析 EPUB 的 `tableOfContents` 结构，按照层次遍历所有节点，
    /// 并将每个可解析的 href 转换为 `TOCLocator`。同一文件的后代节点会继承
    /// 其父节点解析出的文件路径，以便在单 HTML 多锚点场景下能够正确定位。
    ///
    /// - Parameters:
    ///   - root: 根级 `EPUBTableOfContents` 对象。
    ///   - tocDirectory: TOC 文件所在目录 URL，用于解析相对路径。
    ///   - contentDirectory: EPUB 内容根目录 URL，用于计算相对路径。
    /// - Returns: 扁平化后的 `TOCLocator` 数组，保持原始 TOC 层级顺序。
    private func flattenTOC(
        _ root: EPUBTableOfContents,
        tocDirectory: URL,
        contentDirectory: URL
    ) -> [TOCLocator] {
        var result: [TOCLocator] = []

        func walk(
            _ node: EPUBTableOfContents,
            level: Int,
            inheritedFilePath: String?
        ) {
            var effectiveFilePath = inheritedFilePath
            if let source = node.item?.trimmingCharacters(in: .whitespacesAndNewlines),
               !source.isEmpty,
               let resolved = resolveTOCTarget(
                   source,
                   tocDirectory: tocDirectory,
                   contentDirectory: contentDirectory,
                   inheritedFilePath: inheritedFilePath
               ) {
                effectiveFilePath = resolved.filePath
                result.append(
                    TOCLocator(
                        tocID: node.id,
                        label: node.label,
                        level: level,
                        filePath: resolved.filePath,
                        fragment: resolved.fragment,
                        canonicalKey: canonicalKey(
                            filePath: resolved.filePath,
                            fragment: resolved.fragment
                        )
                    )
                )
            }

            node.subTable?.forEach {
                walk($0, level: level + 1, inheritedFilePath: effectiveFilePath)
            }
        }

        root.subTable?.forEach {
            walk($0, level: 1, inheritedFilePath: nil)
        }
        return result
    }

    /// 根据 `canonicalKey` 去重 TOC 定位器数组。
    ///
    /// 由于目录可能包含重复的条目（比如嵌套 TOC 或多个指向相同片段的链接），
    /// 此方法只保留第一次出现的定位信息并丢弃后续重复项，返回的顺序与输入保持一致。
    ///
    /// - Parameter locators: 待去重的定位器列表。
    /// - Returns: 去重后的定位器数组。
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
    
    /// 记录原始 spine 对应文件的 `linear` 语义，后续写入新章节。
    /// 构建源文件路径到 `linear` 属性的映射。
    ///
    /// EPUB Spine 中每个项目都有一个 `linear` 标记，表示是否应按顺序阅读。
    /// 在执行章节拆分后，新的章节需要继承其源文件对应的线性语义。
    /// 此方法遍历原始 spine 并记录首次出现的线性值。
    ///
    /// - Parameters:
    ///   - manifest: EPUB 清单对象。
    ///   - spine: EPUB Spine 对象。
    /// - Returns: 一个字典，键为源文件相对路径，值为其对应的 `linear` 布尔值。
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

    /// 解析 TOC 项目的 href 并规范化为内容目录内的相对路径。
    ///
    /// TOC 中的 `source` 可能包含文件名和可选的 fragment（锚点）。
    /// 函数会处理 URL 解码、相对路径转换，并在需要时继承父节点的路径。
    ///
    /// - Parameters:
    ///   - source: 原始 href 字符串，例如 `chapter.xhtml#p3`。
    ///   - tocDirectory: TOC 文档所在目录 URL。
    ///   - contentDirectory: EPUB 内容根目录 URL。
    ///   - inheritedFilePath: 从父节点继承的文件路径（用于空 href 的情况）。
    /// - Returns: 元组 `(filePath: 相对路径, fragment: 可选锚点)`，若解析失败则返回 `nil`。
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

    /// 将绝对 URL 转换为相对于指定基目录的相对路径。
    ///
    /// 仅在 `url` 位于 `base` 目录下时返回非空字符串，否则返回 `nil`。
    ///
    /// - Parameters:
    ///   - url: 要转换的绝对文件 URL。
    ///   - base: 基础目录 URL。
    /// - Returns: 相对路径字符串，如果无法相对化则返回 `nil`。
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

    /// 生成用于唯一标识 TOC 定位点的键。
    ///
    /// 键由文件路径加上可选的 fragment 构成，用于后续去重和映射。
    /// - Parameters:
    ///   - filePath: 相对文件路径。
    ///   - fragment: 可选的锚点 ID。
    /// - Returns: 拼接后的规范键。
    func canonicalKey(filePath: String, fragment: String?) -> String {
        if let fragment, !fragment.isEmpty {
            return "\(filePath)#\(fragment)"
        }
        return filePath
    }
    
    // MARK: - 结构语义识别（guide / landmarks / TOC 文本回退）
    
    /// 构建每个内容位置对应的语义提示集。
    ///
    /// 根据 EPUB 的 `<guide>`、导航文档的 landmarks 以及 TOC 文本回退，
    /// 为每一个 canonicalKey 记录可能的章节种类（前言、正文、附录、参考）。
    /// 这些语义信息在后续用于章节分类、封面识别等决策。
    ///
    /// - Parameters:
    ///   - contentDirectory: EPUB 内容目录 URL，用于解析相对路径。
    ///   - navPath: 可选的导航文档路径。
    ///   - guideElement: 可选的 `<guide>` 元素。
    ///   - tocLocators: 已扁平化的 TOC 定位器列表。
    /// - Returns: 字典，键为 canonicalKey，值为该位置的可能章节类型集合。
    private func buildSemanticHints(
        contentDirectory: URL,
        navPath: String?,
        guideElement: AEXMLElement?,
        tocLocators: [TOCLocator]
    ) -> [String: Set<ChapterKind>] {
        var mapping: [String: Set<ChapterKind>] = [:]
        
        func add(kind: ChapterKind, for key: String) {
            mapping[key, default: []].insert(kind)
        }
        
        if let guideElement,
           let references = guideElement["reference"].all {
            for reference in references {
                let type = reference.attributes["type"] ?? ""
                let title = reference.attributes["title"] ?? ""
                guard let href = reference.attributes["href"],
                      let resolved = resolveReferenceTarget(
                          href,
                          baseDirectory: contentDirectory,
                          contentDirectory: contentDirectory
                      )
                else { continue }
                let key = canonicalKey(filePath: resolved.filePath, fragment: resolved.fragment)
                add(kind: classifyBySemantic(type: type, label: title), for: key)
            }
        }
        
        if let navPath {
            let navURL = contentDirectory.appendingPathComponent(navPath)
            if let navHTML = try? String(contentsOf: navURL, encoding: .utf8) {
                for reference in parseLandmarks(from: navHTML) {
                    guard let resolved = resolveReferenceTarget(
                        reference.href,
                        baseDirectory: navURL.deletingLastPathComponent(),
                        contentDirectory: contentDirectory
                    ) else { continue }
                    let key = canonicalKey(filePath: resolved.filePath, fragment: resolved.fragment)
                    add(kind: classifyBySemantic(type: reference.type, label: reference.label), for: key)
                }
            }
        }
        
        // 回退：基于 TOC 文本做最小语义兜底。
        for locator in tocLocators {
            guard let label = locator.label else { continue }
            let byLabel = classifyByTOCLabel(label)
            guard byLabel != .bodymatter else { continue }
            add(kind: byLabel, for: locator.canonicalKey)
        }
        
        return mapping
    }
    
    /// 构建疑似封面位置的键集合。
    ///
    /// 从 `<guide>` 引用、导航文档 landmarks 以及 TOC 标签文本中
    /// 收集所有可能表示封面（cover）的 canonicalKey。结果用于后续
    /// 决定哪些章节应从 spine 中排除。
    ///
    /// - Parameters:
    ///   - contentDirectory: EPUB 内容根目录 URL。
    ///   - navPath: 可选的导航文档路径。
    ///   - guideElement: 可选 `<guide>` 元素。
    ///   - tocLocators: 扁平化后的 TOC 定位器列表。
    /// - Returns: 一个包含封面相关 canonicalKey 的集合。
    private func buildCoverHints(
        contentDirectory: URL,
        navPath: String?,
        guideElement: AEXMLElement?,
        tocLocators: [TOCLocator]
    ) -> Set<String> {
        var keys: Set<String> = []
        
        if let guideElement,
           let references = guideElement["reference"].all {
            for reference in references {
                let type = reference.attributes["type"]
                let title = reference.attributes["title"]
                guard isCoverSemantic(type: type, label: title),
                      let href = reference.attributes["href"],
                      let resolved = resolveReferenceTarget(
                          href,
                          baseDirectory: contentDirectory,
                          contentDirectory: contentDirectory
                      )
                else { continue }
                keys.insert(canonicalKey(filePath: resolved.filePath, fragment: resolved.fragment))
                keys.insert(canonicalKey(filePath: resolved.filePath, fragment: nil))
            }
        }
        
        if let navPath {
            let navURL = contentDirectory.appendingPathComponent(navPath)
            if let navHTML = try? String(contentsOf: navURL, encoding: .utf8) {
                for reference in parseLandmarks(from: navHTML) {
                    guard isCoverSemantic(type: reference.type, label: reference.label),
                          let resolved = resolveReferenceTarget(
                              reference.href,
                              baseDirectory: navURL.deletingLastPathComponent(),
                              contentDirectory: contentDirectory
                          ) else { continue }
                    keys.insert(canonicalKey(filePath: resolved.filePath, fragment: resolved.fragment))
                    keys.insert(canonicalKey(filePath: resolved.filePath, fragment: nil))
                }
            }
        }
        
        for locator in tocLocators where isCoverLabel(locator.label) {
            keys.insert(locator.canonicalKey)
            keys.insert(canonicalKey(filePath: locator.filePath, fragment: nil))
        }
        
        return keys
    }
    
    /// 根据一组 TOC 定位器及语义提示确定章节类型。
    ///
    /// 函数首先查看 `semanticByCanonicalKey` 中是否存在显式语义；
    /// 若没有则回退至 TOC 标签文本分析。若存在多种语义，
    /// 按优先级依次选取 frontmatter > backmatter > reference > bodymatter。
    ///
    /// - Parameters:
    ///   - locators: 属于该章的 TOC 定位器。
    ///   - semanticByCanonicalKey: 预先计算的语义线索字典。
    /// - Returns: 最终判定的 `ChapterKind`。
    private func classifyChapterKind(
        locators: [TOCLocator],
        semanticByCanonicalKey: [String: Set<ChapterKind>]
    ) -> ChapterKind {
        var buckets: [ChapterKind: Int] = [:]
        for locator in locators {
            if let kinds = semanticByCanonicalKey[locator.canonicalKey] {
                for kind in kinds {
                    buckets[kind, default: 0] += 1
                }
            } else if let label = locator.label {
                buckets[classifyByTOCLabel(label), default: 0] += 1
            }
        }
        
        if buckets[.frontmatter, default: 0] > 0 { return .frontmatter }
        if buckets[.backmatter, default: 0] > 0 { return .backmatter }
        if buckets[.reference, default: 0] > 0 { return .reference }
        return .bodymatter
    }
    
    /// 判断已拆分的章节是否应从新 spine 中排除。
    ///
    /// 目前仅在 `kind` 为 frontmatter 时才会考虑排除，且
    /// 进一步通过封面语义或文件名/锚点包含 "cover" 等关键词来判定。
    ///
    /// - Parameters:
    ///   - kind: 本章节推断出的类型。
    ///   - locators: 归属于本章节的 TOC 定位器。
    ///   - coverCanonicalKeys: 事先收集的封面线索集合。
    /// - Returns: 若章节应排除则返回 `true`。
    private func shouldExcludeFromSpine(
        kind: ChapterKind,
        locators: [TOCLocator],
        coverCanonicalKeys: Set<String>
    ) -> Bool {
        guard kind == .frontmatter else { return false }
        
        // 严格要求：封面不应进入 spine。优先使用显式 cover 线索，避免误伤其他 frontmatter。
        for locator in locators {
            let fileKey = canonicalKey(filePath: locator.filePath, fragment: nil)
            if coverCanonicalKeys.contains(locator.canonicalKey) || coverCanonicalKeys.contains(fileKey) {
                return true
            }
        }
        
        return locators.contains { locator in
            let fragment = normalizedText(locator.fragment ?? "")
            let file = normalizedText((locator.filePath as NSString).lastPathComponent)
            return isCoverLabel(locator.label)
                || fragment == "cover"
                || file.contains("cover")
        }
    }
    
    /// 检查原始 spine 项目是否为封面类文件而应在新 spine 中删除。
    ///
    /// - Parameters:
    ///   - path: 原始 spine 项目的相对路径。
    ///   - coverCanonicalKeys: 已识别的封面键集合。
    /// - Returns: 若原始项目被标记为封面则返回 `true`。
    private func shouldExcludeOriginalSpineItem(
        path: String,
        coverCanonicalKeys: Set<String>
    ) -> Bool {
        let key = canonicalKey(filePath: path, fragment: nil)
        return coverCanonicalKeys.contains(key)
    }
    
    /// 基于语义 type 或标题文本尝试分类章节类型。
    ///
    /// 用于处理 `<guide>` 或 landmarks 提供的 `type`/`title` 属性，
    /// 按常用语义关键字匹配不同章节类别。若无法从 `type` 识别，
    /// 则回退至 TOC 标签文本分析。
    ///
    /// - Parameters:
    ///   - type: 可能来自属性 `type` 的语义标签。
    ///   - label: 对应的人类可读标题。
    /// - Returns: 一种推断出的 `ChapterKind`。
    private func classifyBySemantic(type: String?, label: String?) -> ChapterKind {
        let normalizedType = normalizedText(type ?? "")
        let normalizedLabel = normalizedText(label ?? "")
        
        if normalizedType.contains("cover")
            || normalizedType == "toc"
        {
            return .frontmatter
        }
        
        if normalizedType.contains("copyright")
            || normalizedType.contains("credits")
            || normalizedType.contains("acknowledg")
            || normalizedType.contains("appendix")
            || normalizedType.contains("afterword")
            || normalizedType.contains("bibliography")
            || normalizedType.contains("index")
            || normalizedType.contains("glossary")
            || normalizedType.contains("colophon")
        {
            return .backmatter
        }
        
        if normalizedType.contains("landmark")
            || normalizedType.contains("reference")
            || normalizedType.contains("page-list")
            || normalizedType.contains("loa")
            || normalizedType.contains("lot")
        {
            return .reference
        }
        
        if normalizedType.contains("bodymatter")
            || normalizedType == "text"
            || normalizedType == "chapter"
        {
            return .bodymatter
        }
        
        return classifyByTOCLabel(normalizedLabel)
    }
    
    /// 根据 TOC 标签文本对章节进行简单分类。
    ///
    /// 此方法仅在无法从语义提示中获知章节类型时使用。
    /// 支持封面、版权页、附录、索引等常见关键词。
    ///
    /// - Parameter label: TOC 条目的文本标签。
    /// - Returns: 估计得到的 `ChapterKind`。
    private func classifyByTOCLabel(_ label: String) -> ChapterKind {
        let normalized = normalizedText(label)
        if normalized.isEmpty {
            return .bodymatter
        }
        
        if isCoverLabel(normalized)
        {
            return .frontmatter
        }
        
        if normalized == "credits"
            || normalized == "copyright"
            || normalized == "copyright page"
            || normalized == "acknowledgments"
            || normalized == "acknowledgements"
            || normalized == "appendix"
            || normalized == "index"
        {
            return .backmatter
        }
        
        if normalized == "page list" || normalized == "landmarks" {
            return .reference
        }
        
        return .bodymatter
    }
    
    /// 判断给定语义/标签是否暗示封面。
    ///
    /// 常用于解析 guide/landmark 条目的 `type` 或 `title`。
    ///
    /// - Parameters:
    ///   - type: 语义类型字符串。
    ///   - label: 文本标签。
    /// - Returns: 若任一字段表明封面则返回 `true`。
    private func isCoverSemantic(type: String?, label: String?) -> Bool {
        let normalizedType = normalizedText(type ?? "")
        if normalizedType.contains("cover") {
            return true
        }
        return isCoverLabel(label)
    }
    
    /// 检查标签文本是否属于“封面”相关。
    ///
    /// 文字匹配时会做小写、去重空格处理。
    ///
    /// - Parameter label: 可能的标签字符串。
    /// - Returns: 如果标签等于常见封面术语则返回 `true`。
    private func isCoverLabel(_ label: String?) -> Bool {
        let normalized = normalizedText(label ?? "")
        let candidates: Set<String> = [
            "cover",
            "book cover",
            "cover image",
            "cover page",
            "front cover",
            "封面"
        ]
        return candidates.contains(normalized)
    }
    
    /// 解析导航或引用元素中的 href，转换为内容目录下的相对路径。
    ///
    /// 与 `resolveTOCTarget` 类似，但不允许继承路径并且必须提供文件部分。
    ///
    /// - Parameters:
    ///   - source: 原始 href 字符串。
    ///   - baseDirectory: href 所在文档的目录 URL。
    ///   - contentDirectory: EPUB 内容根目录 URL。
    /// - Returns: `(filePath, fragment)` 元组，无法解析时返回 `nil`。
    private func resolveReferenceTarget(
        _ source: String,
        baseDirectory: URL,
        contentDirectory: URL
    ) -> (filePath: String, fragment: String?)? {
        let parts = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawFile = parts.first.map(String.init) ?? ""
        let rawFragment = parts.count > 1 ? String(parts[1]) : nil
        let decodedRawFile = rawFile.removingPercentEncoding ?? rawFile
        
        guard !decodedRawFile.isEmpty else { return nil }
        let absolute = baseDirectory.appendingPathComponent(decodedRawFile).standardizedFileURL
        guard let relative = relativize(url: absolute, to: contentDirectory) else {
            return nil
        }
        
        return (relative, rawFragment?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    /// 从导航 HTML 中提取 landmarks 链接信息。
    /// - Parameter navHTML: 导航页面的完整 HTML 字符串。
    /// - Returns: 包含 href、type 和 label 的元组数组。
    private func parseLandmarks(from navHTML: String) -> [(href: String, type: String?, label: String?)] {
        guard let navRegex = try? NSRegularExpression(
            pattern: #"(?is)<nav\b[^>]*(?:epub:type|type)\s*=\s*['"][^'"]*\blandmarks\b[^'"]*['"][^>]*>(.*?)</nav>"#
        ),
        let anchorRegex = try? NSRegularExpression(
            pattern: #"(?is)<a\b([^>]*)>(.*?)</a>"#
        ) else {
            return []
        }
        
        let nsRange = NSRange(navHTML.startIndex..<navHTML.endIndex, in: navHTML)
        let navBlocks = navRegex.matches(in: navHTML, options: [], range: nsRange)
        var results: [(href: String, type: String?, label: String?)] = []
        
        for block in navBlocks {
            guard let contentRange = Range(block.range(at: 1), in: navHTML) else { continue }
            let content = String(navHTML[contentRange])
            let contentNSRange = NSRange(content.startIndex..<content.endIndex, in: content)
            for anchor in anchorRegex.matches(in: content, options: [], range: contentNSRange) {
                guard let attrsRange = Range(anchor.range(at: 1), in: content),
                      let innerRange = Range(anchor.range(at: 2), in: content)
                else { continue }
                let attrs = String(content[attrsRange])
                guard let href = firstMatch(
                    in: attrs,
                    pattern: #"(?is)\bhref\s*=\s*['"]([^'"]+)['"]"#,
                    group: 1
                ) else { continue }
                
                let type = firstMatch(
                    in: attrs,
                    pattern: #"(?is)\b(?:epub:type|type)\s*=\s*['"]([^'"]+)['"]"#,
                    group: 1
                )
                let label = String(content[innerRange])
                    .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                results.append((href: href, type: type, label: label))
            }
        }
        
        return results
    }

    // MARK: - 源文档解析与边界定位

    /// 从原始 XHTML/HTML 文本中提取基础结构片段。
    ///
    /// 为后续章节拆分提供必要的 `<html>` 标签属性、`<head>` 内容以及
    /// `<body>` 属性和内部 HTML。若任何部分无法解析则返回 `nil`。
    ///
    /// - Parameter html: 完整的 XHTML/HTML 文档字符串。
    /// - Returns: 成功时返回 `SourceDocument` 否则为 `nil`。
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

    /// 在文本中查找指定正则表达式的第一个捕获组。
    ///
    /// 这是一个小型助手，用于从 HTML 片段中提取标签属性或内部内容。
    ///
    /// - Parameters:
    ///   - text: 被搜索的字符串。
    ///   - pattern: 正则表达式模式。
    ///   - group: 想要返回的捕获组编号（0 表示整个匹配）。
    /// - Returns: 匹配成功时对应组的内容，否则为 `nil`。
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

    /// 根据 TOC 定位器在 HTML 正文中查找切分起始偏移。
    ///
    /// 优先使用 fragment 定位锚点，并将结果对齐到最近的块级元素。
    /// 如果锚点无效则尝试使用 TOC 标签文本回退。若都失败则返回 nil。
    ///
    /// - Parameters:
    ///   - locator: 包含 fragment/label 信息的定位器。
    ///   - body: 源文件 `<body>` 的内部 HTML。
    ///   - defaultOffset: 未提供 fragment 时使用的默认偏移。
    /// - Returns: UTF-16 单元偏移量，或 `nil` 表示无法定位。
    private func findBoundary(
        for locator: TOCLocator,
        in body: String,
        defaultOffset: Int
    ) -> Int? {
        guard let fragment = locator.fragment, !fragment.isEmpty else {
            return defaultOffset
        }

        let candidates = [fragment, fragment.removingPercentEncoding]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for candidate in candidates {
            if let offset = findAnchorOffset(fragment: candidate, in: body) {
                // 对齐到块级元素起始，避免从标签中部切片导致坏标记。
                return alignedBlockBoundary(forUTF16: offset, in: body) ?? offset
            }
        }
        
        // 最小容错：锚点失效时尝试按标题文本定位。
        if let label = locator.label,
           let fallback = findLabelOffset(label, in: body) {
            return alignedBlockBoundary(forUTF16: fallback, in: body) ?? fallback
        }
        
        return nil
    }

    func findAnchorOffset(fragment: String, in text: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: fragment)
        // 依次匹配 id/name 锚点：`<... id="fragment" ...>` 或 `<... name="fragment" ...>`。
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
    
    private func findLabelOffset(_ label: String, in text: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        // 按标题语义回退：优先标题标签，其次段落/链接文本。
        let patterns = [
            #"(?is)<h[1-6]\b[^>]*>\s*(?:<[^>]+>\s*)*"# + escaped + #"(?:(?:\s*</[^>]+>)*)\s*</h[1-6]>"#,
            #"(?is)<p\b[^>]*>\s*(?:<[^>]+>\s*)*"# + escaped + #"(?:(?:\s*</[^>]+>)*)\s*</p>"#,
            #"(?is)<a\b[^>]*>\s*(?:<[^>]+>\s*)*"# + escaped + #"(?:(?:\s*</[^>]+>)*)\s*</a>"#
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
    
    private func alignedBlockBoundary(forUTF16 offset: Int, in text: String) -> Int? {
        guard offset > 0, offset <= text.utf16.count else { return nil }
        let range = NSRange(location: 0, length: offset)
        // 仅在常见块级标签上回退，避免落在行内标签中间。
        guard let openingRegex = try? NSRegularExpression(
            pattern: #"(?is)<\s*(p|div|section|h[1-6]|li|figure|table|blockquote)\b[^>]*>"#
        ) else { return nil }
        
        let openingMatches = openingRegex.matches(in: text, options: [], range: range)
        for match in openingMatches.reversed() {
            guard let tagRange = Range(match.range(at: 1), in: text) else { continue }
            let tagName = String(text[tagRange]).lowercased()
            let openingEnd = match.range.location + match.range.length
            guard openingEnd <= offset else { continue }
            
            let inBetween = NSRange(location: openingEnd, length: offset - openingEnd)
            let closingPattern = #"(?is)</\s*"#
                + NSRegularExpression.escapedPattern(for: tagName)
                + #"\s*>"#
            guard let closingRegex = try? NSRegularExpression(pattern: closingPattern, options: []) else {
                continue
            }
            if closingRegex.firstMatch(in: text, options: [], range: inBetween) == nil {
                return match.range.location
            }
        }
        return nil
    }

    // MARK: - HTML 组装与清洗

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

    /// 清理拆分片段中的噪音段落和结构元素。
    ///
    /// - Parameters:
    ///   - html: 待清洗的 HTML 片段。
    ///   - tocLabel: 当前片段对应的 TOC 标签，用于去除冗余标题。
    /// - Returns: 被净化后的 HTML。
    func cleanChapterHTML(
        _ html: String,
        tocLabel: String
    ) -> String {
        // 按段落粒度清洗，避免跨标签替换导致结构损坏。
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<p\b([^>]*)>(.*?)</p>"#,
            options: []
        ) else {
            return html
        }

        var result = html
        let paragraphs = paragraphList(from: html)
        let tocLike = isLikelyTOCBlock(paragraphs)
        let matches = regex.matches(
            in: result,
            options: [],
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let paragraph = String(result[fullRange])

            if shouldRemoveParagraph(
                paragraph,
                tocLike: tocLike,
                tocLabel: tocLabel
            ) {
                result.removeSubrange(fullRange)
            }
        }

        return removeStructuralNoise(from: result, tocLike: tocLike)
    }

    /// 决定是否将某段 `<p>` 删除。
    ///
    /// 使用一系列启发式规则判断段落是否为目录、页码、空锚点等无意义内容。
    ///
    /// - Parameters:
    ///   - paragraph: 段落的完整 HTML。
    ///   - tocLike: 是否处于类目录结构上下文。
    ///   - tocLabel: 对应 TOC 条目的文本标签。
    /// - Returns: 若应删除则返回 `true`。
    func shouldRemoveParagraph(
        _ paragraph: String,
        tocLike: Bool,
        tocLabel: String
    ) -> Bool {
        let lower = paragraph.lowercased()
        // 命中任意 id/name 属性都视为锚点段落。
        let hasAnchorMarker = paragraph.range(
            of: #"(?is)\b(?:id|name)\s*=\s*['"][^'"]+['"]"#,
            options: .regularExpression
        ) != nil
        let hasImage = lower.contains("<img")

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
        let normalizedTextOnly = textOnly.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let hasPageBreakSemantics = lower.contains("epub:type=\"pagebreak\"")
            || lower.contains("epub:type='pagebreak'")
            || lower.contains("role=\"doc-pagebreak\"")
            || lower.contains("role='doc-pagebreak'")
            || lower.range(
                of: #"\bclass\s*=\s*['"][^'"]*(?:pagebreak|page_num|pagenum|calibre_pb)[^'"]*['"]"#,
                options: .regularExpression
            ) != nil

        // 保留图片段落，避免误删视觉内容。
        if hasImage {
            return false
        }
        
        if hasPageBreakSemantics {
            if normalizedTextOnly.isEmpty {
                return true
            }
            if normalizedTextOnly.range(of: #"^\[?\d{1,6}\]?$"#, options: .regularExpression) != nil {
                return true
            }
        }
        
        // 普通正文中保留锚点段落，避免误删结构锚；TOC-like 切片例外。
        if hasAnchorMarker && !tocLike {
            return false
        }
        
        // 删除纯数字页码段落。
        if textOnly.range(of: #"^\d{1,6}$"#, options: .regularExpression) != nil {
            return true
        }

        let compactInner = inner.trimmingCharacters(in: .whitespacesAndNewlines)

        // 删除仅用于内部跳转的目录链接段落。
        // 例如：`<p><a href="#p34">Ice Cream</a></p>`
        let internalOnlyPattern = #"(?is)^<a\b[^>]*href\s*=\s*['\"]#[^'\"]+['\"][^>]*>.*?</a>$"#
        if tocLike
            && compactInner.range(of: internalOnlyPattern, options: .regularExpression) != nil {
            return true
        }

        // 仅在 TOC-like 切片中删除目录标题（如 Contents / Document Outline）。
        if tocLike && isTOCHeadingText(textOnly) {
            return true
        }
        if tocLike
            && !tocLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalizedText(textOnly) == normalizedText(tocLabel)
            && isTOCHeadingText(textOnly) {
            return true
        }
        
        // TOC-like 切片中，即使含本地锚点，也移除目录标题行。
        if tocLike && hasAnchorMarker && isTOCHeadingText(textOnly) {
            return true
        }

        return false
    }
    
    /// 从 HTML 中剥离表面结构噪音，如空 pagebreak 标签。
    ///
    /// 仅在 `tocLike` 为真时执行额外的目录特定清洗。
    ///
    /// - Parameters:
    ///   - html: 需要处理的 HTML 字符串。
    ///   - tocLike: 如果片段可能源自目录页面。
    /// - Returns: 清除噪音后的 HTML。
    private func removeStructuralNoise(from html: String, tocLike: Bool) -> String {
        var result = html
        
        // 清理 pagebreak 语义标签：覆盖 span/div/a/p，且只在“空文本或纯数字页码”时删除。
        let pairedPattern = #"(?is)<(span|div|a|p)\b([^>]*)>(.*?)</\1>"#
        if let pairedRegex = try? NSRegularExpression(pattern: pairedPattern) {
            var changed = true
            while changed {
                changed = false
                let matches = pairedRegex.matches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..<result.endIndex, in: result)
                ).reversed()
                for match in matches {
                    guard let fullRange = Range(match.range(at: 0), in: result),
                          let attrsRange = Range(match.range(at: 2), in: result),
                          let innerRange = Range(match.range(at: 3), in: result)
                    else { continue }
                    let attrs = String(result[attrsRange]).lowercased()
                    let inner = String(result[innerRange])
                    guard isPageBreakLike(attributes: attrs, textContent: inner) else { continue }
                    result.removeSubrange(fullRange)
                    changed = true
                }
            }
        }
        
        // 清理自闭合 pagebreak 标签。
        if let selfClosingRegex = try? NSRegularExpression(
            pattern: #"(?is)<(?:span|div|a|p)\b([^>]*)/>"#
        ) {
            let matches = selfClosingRegex.matches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result)
            ).reversed()
            for match in matches {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let attrsRange = Range(match.range(at: 1), in: result)
                else { continue }
                let attrs = String(result[attrsRange]).lowercased()
                guard isPageBreakLike(attributes: attrs, textContent: "") else { continue }
                result.removeSubrange(fullRange)
            }
        }
        
        // TOC-like 场景额外删除“纯内部页码回跳链接”。
        if tocLike {
            result = result.replacingOccurrences(
                of: #"(?is)<a\b[^>]*href\s*=\s*['"]#[^'"]+['"][^>]*>\s*\d{1,6}\s*</a>"#,
                with: ""
            )
        }
        
        return result
    }
    
    /// 判断给定属性与内容是否类似分页标记。
    ///
    /// 用于在 `removeStructuralNoise` 中识别并移除页码/分页 span、div 等元素。
    private func isPageBreakLike(attributes: String, textContent: String) -> Bool {
        let hasSemantic = attributes.contains("epub:type=\"pagebreak\"")
            || attributes.contains("epub:type='pagebreak'")
            || attributes.contains("role=\"doc-pagebreak\"")
            || attributes.contains("role='doc-pagebreak'")
            || attributes.range(
                of: #"\bclass\s*=\s*['"][^'"]*(?:pagebreak|page_num|pagenum|calibre_pb)[^'"]*['"]"#,
                options: .regularExpression
            ) != nil
        
        guard hasSemantic else { return false }
        
        let text = textContent
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if text.isEmpty {
            return true
        }
        
        return text.range(of: #"^\[?\d{1,6}\]?$"#, options: .regularExpression) != nil
    }

    private func paragraphList(from html: String) -> [String] {
        // 提取完整 `<p>...</p>` 片段用于 TOC-like 结构判定。
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<p\b[^>]*>.*?</p>"#
        ) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 0), in: html) else {
                return nil
            }
            return String(html[range])
        }
    }

    private func isLikelyTOCBlock(_ paragraphs: [String]) -> Bool {
        guard !paragraphs.isEmpty else { return false }
        let internalAnchorCount = paragraphs.filter { paragraph in
            let inner = paragraph
                .replacingOccurrences(
                    of: #"(?is)^<p\b[^>]*>|</p>$"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 统计“仅内部跳转链接”的段落比例，用于识别目录页切片。
            return inner.range(
                of: #"(?is)^<a\b[^>]*href\s*=\s*['\"]#[^'\"]+['\"][^>]*>.*?</a>$"#,
                options: .regularExpression
            ) != nil
        }.count

        return internalAnchorCount >= 3
            && internalAnchorCount * 2 >= paragraphs.count
    }

    private func isLikelyTOCBlockHTML(_ html: String) -> Bool {
        isLikelyTOCBlock(paragraphList(from: html))
    }

    private func isTOCHeadingText(_ text: String) -> Bool {
        let normalized = normalizedText(text)
        let candidates: Set<String> = [
            "contents",
            "table of contents",
            "document outline",
            "toc"
        ]
        return candidates.contains(normalized)
    }

    private func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func injectHeadingIfNeeded(
        in html: String,
        locator: TOCLocator
    ) -> String {
        guard let fragment = locator.fragment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fragment.isEmpty else {
            return html
        }

        let label = locator.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty else { return html }

        if isLikelyTOCBlockHTML(html) && isTOCHeadingText(label) {
            return html
        }

        if hasHeading(id: fragment, in: html) {
            return html
        }

        var result = stripLeadingAnchor(id: fragment, from: html)
        result = stripLeadingInlineTitle(label: label, from: result)
        result = stripLeadingBackLinkTitle(label: label, from: result)
        // 兜底去重：移除与新标题同文案的首段内部回跳标题。
        result = stripLeadingRedundantTitleParagraph(label: label, from: result)

        let headingLevel = min(max(locator.level, 1), 6)
        let heading = "<h\(headingLevel) id=\"\(escapedAttribute(fragment))\">\(escapedHTML(label))</h\(headingLevel)>"
        return heading + "\n" + result
    }

    private func hasHeading(id: String, in html: String) -> Bool {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        // 判定是否已存在绑定同一锚点 id 的标题标签。
        let pattern = #"(?is)<h[1-6]\b[^>]*\bid\s*=\s*['"]"# + escapedID + #"['"][^>]*>"#
        return html.range(of: pattern, options: .regularExpression) != nil
    }

    private func stripLeadingAnchor(id: String, from html: String) -> String {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        // 去除切片起始处独立锚点：`<a id="p10"></a>` / `<a name="p10"></a>`。
        let pattern = #"(?is)^\s*<a\b[^>]*(?:id|name)\s*=\s*['"]"# + escapedID + #"['"][^>]*>\s*</a>\s*"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }

    private func stripLeadingInlineTitle(label: String, from html: String) -> String {
        let escapedLabel = NSRegularExpression.escapedPattern(for: label)
        // 去除“以纯文本/加粗/span 包裹”的前置标题行。
        let pattern =
            #"(?is)^\s*(?:</p>\s*)?(?:<p\b[^>]*>\s*)?(?:<(?:b|strong|span)[^>]*>\s*)?"#
            + escapedLabel
            + #"(?:(?:\s*</(?:b|strong|span)>)?\s*)(?:</p>)?\s*"#

        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }
    
    private func stripLeadingBackLinkTitle(label: String, from html: String) -> String {
        let escapedLabel = NSRegularExpression.escapedPattern(for: label)
        // 去除“回链到目录”的前置标题行：`<a href="#p7">Title</a>`。
        let pattern =
            #"(?is)^\s*(?:</p>\s*)?(?:<p\b[^>]*>\s*)?<a\b[^>]*href\s*=\s*['"]#p\d+['"][^>]*>\s*(?:<[^>]+>\s*)*"#
            + escapedLabel
            + #"(\s*</[^>]+>\s*)*</a>\s*(?:</p>)?\s*"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }
    
    private func stripLeadingRedundantTitleParagraph(label: String, from html: String) -> String {
        // 仅处理“首个段落”，用于去掉注入标题后残留的重复标题段。
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)^\s*<p\b[^>]*>(.*?)</p>\s*"#
        ) else { return html }
        
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let innerRange = Range(match.range(at: 1), in: html),
              let fullRange = Range(match.range(at: 0), in: html)
        else {
            return html
        }
        
        let inner = String(html[innerRange])
        // 限定为内部跳转链接段，避免误删普通正文首段。
        let hasInternalLink = inner.range(
            of: #"(?is)<a\b[^>]*href\s*=\s*['"]#[^'"]+['"]"#,
            options: .regularExpression
        ) != nil
        let normalizedInnerText = normalizedText(
            inner
                .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
        )
        
        guard hasInternalLink,
              normalizedInnerText == normalizedText(label)
        else {
            return html
        }
        
        var result = html
        result.removeSubrange(fullRange)
        return result
    }

    private func normalizeFragmentMarkup(_ html: String) -> String {
        var result = html
            .replacingOccurrences(of: #"(?is)</body>|</html>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)^\s*</p>\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<p\b[^>]*>\s*$"#, with: "", options: .regularExpression)

        // 若片段以孤立 `</p>` 开头，进行防御性修剪，避免输出坏结构。
        while result.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("</p>") {
            result = result.replacingOccurrences(
                of: #"(?is)^\s*</p>\s*"#,
                with: "",
                options: .regularExpression
            )
        }
        return result
    }
    
    private func isEffectivelyEmptyChapter(_ html: String) -> Bool {
        let text = html
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = html.range(of: #"(?is)<img\b"#, options: .regularExpression) != nil
        return text.isEmpty && !hasImage
    }
    
    private func isTOCHeadingOnlyChapter(
        _ html: String,
        tocLabel: String
    ) -> Bool {
        let normalizedLabel = normalizedText(tocLabel)
        guard !normalizedLabel.isEmpty, isTOCHeadingText(tocLabel) else {
            return false
        }
        
        // 先去掉标题标签，再判断是否只剩目录标题文本。
        let withoutHeading = html.replacingOccurrences(
            of: #"(?is)<h[1-6]\b[^>]*>.*?</h[1-6]>"#,
            with: "",
            options: .regularExpression
        )
        let hasImage = withoutHeading.range(of: #"(?is)<img\b"#, options: .regularExpression) != nil
        if hasImage {
            return false
        }
        
        let text = withoutHeading
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if text.isEmpty {
            return true
        }
        
        return normalizedText(text) == normalizedLabel
    }

    private func escapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapedAttribute(_ value: String) -> String {
        escapedHTML(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - TOC 重写

    /// 递归对目录结构应用章节路径映射。
    ///
    /// 根据 `mappingByID` 将原始 TOC 节点的 `item` 替换为新的章节路径，
    /// 并移除列于 `removedIDs` 的节点。若某节点自身被删除，但其子节点
    /// 仍然有效，会保留子节点并清空当前条目内容以避免丢失层级信息。
    ///
    /// - Parameters:
    ///   - node: 当前处理的目录节点。
    ///   - mappingByID: 从原 TOC ID 到新文件路径的映射表。
    ///   - removedIDs: 需要从结果中删除的原 TOC ID 集合。
    /// - Returns: 重写后的节点；当整个子树被删除时返回 `nil`。
    func rewriteTOC(
        _ node: EPUBTableOfContents,
        mappingByID: [String: String],
        removedIDs: Set<String>
    ) -> EPUBTableOfContents? {
        if removedIDs.contains(node.id) {
            let survivingChildren = node.subTable?.compactMap {
                rewriteTOC($0, mappingByID: mappingByID, removedIDs: removedIDs)
            } ?? []
            if survivingChildren.isEmpty {
                return nil
            }
            var kept = node
            kept.item = nil
            kept.subTable = survivingChildren
            return kept
        }

        var updated = node

        if let rewritten = mappingByID[node.id] {
            updated.item = rewritten
        }

        if let children = node.subTable {
            updated.subTable = children.compactMap {
                rewriteTOC($0, mappingByID: mappingByID, removedIDs: removedIDs)
            }
        }

        return updated
    }
}
