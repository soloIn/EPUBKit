# EPUB 解析兼容性盘点（2026-03-01）

## 目标与约束（来自需求）
- 对外 API 不变：`let document = try EPUBParser().parse(documentAt: epubURL)`。
- 外部继续通过 `document.spine`、`document.tableOfContents`、`document.manifest.items` 获取章节信息。
- 不新增外部必须依赖的新公开属性。
- 需要兼容 EPUB2 / EPUB3 / 非标准（如 Calibre 单 HTML + 锚点）。
- 标准化后 `spine.items` 应体现完整正文章节顺序，且不包含封面章节。
- 需保留前后附录项信息（Cover/Title Page/Contents/Document Outline/Credits/Copyright 等）。
- 优先用 TOC（NCX/nav）作为章节边界；TOC 层级不可丢。
- 要清洗非正文噪声（例如页码），且不能丢正文。

## 已适配能力（代码现状）
1. 对外 API 兼容
- `EPUBParser.parse(documentAt:)` 与 `EPUBDocument` 公开结构未变。

2. EPUB2/EPUB3 TOC 基础兼容
- 已支持 NCX (`toc.ncx`) 和 EPUB3 `nav.xhtml` 两类 TOC 入口。
- TOC 选择策略为：优先 Manifest `properties="nav"`，回退 `spine.toc`，再回退 NCX media-type。

3. TOC 层级展开与锚点切章
- 已实现 TOC 深度优先展开，支持同文件多锚点的章节切分。
- 已支持单 HTML 多锚点（Calibre 常见形态）标准化为多 `chapter_XXXX.xhtml`。
- 标准化后会同步重写 `manifest/spine/tableOfContents`，保持外部取数方式不变。

4. 非正文清洗（部分）
- 已清理部分目录型噪声（内部跳转段落、纯数字段落、TOC 标题段落）。
- 已避免误删含图片段落。

5. EPUB3/EPUB2 基础兼容测试
- 已有 `EPUBNormalizationTests` 验证 nav 优先、锚点切章、TOC 重写等场景。

## 真实世界 EPUB 形态与规范整理

### A. EPUB2（OPF + NCX + guide）
- OPF 2.0.1 `guide` 用于机器可处理的关键结构导航（cover/title-page/toc/text/copyright-page 等）。
- NCX 除 `navMap` 外还可能包含 `pageList` 与 `navList`。
- `spine@toc` 指向 manifest 中 NCX 条目在 EPUB2 中是核心路径。

### B. EPUB3（nav 文档）
- `nav epub:type="toc"` 是主目录来源；`page-list` 可表示静态页边界；`landmarks` 表达关键结构点（如 bodymatter/toc 等）。
- `toc/page-list/landmarks` 之外还可存在其他 `nav` 类型。
- `nav` 列表项允许 `a` 或 `span`，并允许嵌套 `ol`。

### C. Calibre/转换器常见非标准或工程化产物
- 通过转换参数可导致「单 HTML + 大量锚点」或「按页/按大小切分多 HTML」两类相反结构并存。
- `--dont-split-on-page-breaks` 常见于单文件输出；`--flow-size` 控制大文件切分。
- 实际书中常混有目录页、页码锚点、内部回跳链接，干扰正文切章与阅读顺序。

## 需要继续适配的任务（排除已适配项）

### P0（必须先做，直接对应你的强约束）
1. 正文 spine 过滤：去除封面章节，但保留前后附录信息
- 现状缺口：标准化后 `spine` 仍会把 `Cover` 切片放入阅读顺序。
- 要求实现：
  - `spine.items` 仅保留正文与有效章节顺序（可含 Appendix 等正文后附录），明确排除封面页。
  - `tableOfContents` 保留 Cover/Title Page/Contents/Outline/Credits/Copyright 等导航信息。
  - `manifest.items` 继续保留全部资源，不做破坏性删除。

2. 前后附录识别规则统一（EPUB2 guide + EPUB3 landmarks + TOC 文本回退）
- 增加内部分类层（内部使用，不新增外部必需属性）：`frontmatter/bodymatter/backmatter/reference`。
- 识别来源优先级：
  - EPUB3 landmarks `a@epub:type`
  - EPUB2 guide `reference@type`
  - TOC label/路径启发式（仅回退）

3. 非正文清洗增强且“零正文丢失”
- 现状只覆盖 `<p>` 粒度和部分模式。
- 需扩展到常见页码标记：
  - `epub:type="pagebreak"` / `role="doc-pagebreak"`
  - 常见类名：`pagebreak/page_num/calibre_pb` 等
  - 非 `<p>` 场景（如 `<span>`,`<div>`,`<a>`）
- 增加“保守删除”策略：仅在满足页码特征时移除，避免误删正文数字。

4. TOC 边界切章稳健性
- 继续坚持“优先 TOC 边界”，但补足失配回退：
  - 锚点失效时支持更多定位策略（标题语义、就近块边界、多命名空间 id）。
  - 保证切章失败时不丢内容（降级为整文件章节，而不是丢节点）。

### P1（高优先，提升跨书源兼容率）
5. EPUB3 nav 解析增强（复杂 HTML 结构）
- 支持 `li > p > a`、`li` 内包裹层、非直接子节点 `ol`。
- 支持 `nav` 多命名空间与属性变体匹配（`epub:type`/前缀处理）。
- 对 `span` 节点保持层级但不错误生成空跳转章节。

6. NCX 扩展导航要素保留
- 在不破坏现有 API 的前提下，兼容 `pageList/navList` 的保留与过滤策略：
  - 可保留为 TOC 辅助节点（非正文）
  - 不注入正文 spine

7. 编码与容错
- 对 HTML/NCX/Nav 读取增加编码回退（UTF-8 失败时尝试声明编码）。
- 对不完整 HTML（无标准 `<head>/<body>`）进行容错解析，避免直接放弃标准化。

### P2（工程质量）
8. 测试夹具补强（必须）
- 增加最小回归集：
  - EPUB2 guide 标记前后附录
  - EPUB3 landmarks + toc/page-list 混合
  - Calibre 单文件锚点 + 页码噪声（多标签形态）
  - TOC 嵌套 + `span` 分类项 + 包裹层 `p/div`
  - 封面保留在 TOC 但不进入 spine

9. 结果一致性断言
- 断言 `spine` 与正文章节一一对应（顺序稳定、无封面）。
- 断言 `TOC` 层级不丢失，且前后附录节点仍可导航。
- 断言标准化前后正文文本覆盖率（防内容丢失）。

## 建议实施顺序
1. 先做 P0-1 / P0-2（章节分类 + spine 过滤策略）。
2. 再做 P0-3 / P0-4（清洗与边界容错，确保不丢正文）。
3. 再做 P1（nav/NCX 复杂结构兼容）。
4. 最后补齐 P2 测试并固化回归。

## 规范与资料来源
- EPUB 3.3 (W3C): https://www.w3.org/TR/epub-33/
- EPUB 2.0.1 OPF（含 guide / NCX 相关）: https://idpf.org/epub/20/spec/OPF_2.0_latest.htm
- EPUB 3 Structural Semantics Vocabulary 1.1: https://www.w3.org/TR/epub-ssv-11/
- Calibre `ebook-convert` 文档: https://manual.calibre-ebook.com/generated/en/ebook-convert.html
