import SwiftUI
import AppKit

/// Modal sheet shown when `UpdateChecker` detects a newer GitHub release.
/// MVP only — renders the release's Markdown body via `AttributedString`
/// and offers a button that opens the release page in the browser so the
/// user can download the zip themselves. No auto-install.
struct UpdateAvailableSheet: View {
    let release: UpdateChecker.Release
    let currentVersion: String?
    @Binding var isPresented: Bool
    private let loc = Localizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Header
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(format: loc.t("update.sheet_title_fmt"), release.displayName))
                    .font(AppFont.sectionTitle)
                if let current = currentVersion {
                    Text(String(format: loc.t("update.current_version_fmt"), current))
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Release notes — block-level Markdown renderer. SwiftUI's
            // AttributedString handles inline (bold/italic/code/links) but
            // flattens block-level structure (headings, bullets), so we
            // split into blocks ourselves and style each one.
            ScrollView {
                MarkdownBlocksView(source: bodyOrEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, Spacing.sm)
            }
            .frame(minHeight: 260, maxHeight: 420)

            Divider()

            HStack(spacing: Spacing.sm) {
                Button(loc.t("update.skip_this_version")) {
                    UpdateChecker.shared.skip(release)
                    isPresented = false
                }
                Spacer()
                Button(loc.t("update.remind_later")) {
                    UpdateChecker.shared.dismissSheet()
                    isPresented = false
                }
                Button(loc.t("update.view_on_github")) {
                    NSWorkspace.shared.open(release.htmlUrl)
                    UpdateChecker.shared.dismissSheet()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
    }

    private var bodyOrEmpty: String {
        release.body.isEmpty ? loc.t("update.empty_release_notes") : release.body
    }
}

// MARK: - Markdown block renderer

/// Light block-level Markdown → SwiftUI renderer for release notes.
/// Handles what GitHub release bodies actually contain in practice:
/// H1/H2/H3 headings, `-` / `*` bullet lists, numbered lists, horizontal
/// rules, fenced code blocks, blank-line paragraph breaks. Inline styling
/// (bold, italic, inline code, links) is delegated to `AttributedString`
/// via its Markdown parser — SwiftUI's `Text` renders that correctly;
/// what it can't do is respect block-level structure, which is why we
/// tokenize blocks ourselves before handing each paragraph to it.
struct MarkdownBlocksView: View {
    let source: String

    private var blocks: [Block] { Self.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(blocks.indices, id: \.self) { i in
                render(blocks[i], isFirst: i == 0)
            }
        }
    }

    @ViewBuilder
    private func render(_ block: Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, isFirst ? 0 : 6)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(inline(text))
                .font(AppFont.body)
                .textSelection(.enabled)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .font(AppFont.body)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(inline(items[idx]))
                            .font(AppFont.body)
                            .textSelection(.enabled)
                    }
                }
            }
        case .code(let text):
            Text(text)
                .font(AppFont.monoCaption)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .textSelection(.enabled)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        default: return 14
        }
    }

    /// Inline Markdown via AttributedString — handles **bold**, *italic*,
    /// `code`, [links](…). Falls back to plain text on parse failure.
    private func inline(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: raw, options: options) {
            return attr
        }
        return AttributedString(raw)
    }

    // MARK: - Block tokenizer

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case list([String], ordered: Bool)
        case code(String)
        case rule
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var unordered: [String] = []
        var ordered: [String] = []
        var code: [String] = []
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }
        func flushLists() {
            if !unordered.isEmpty {
                blocks.append(.list(unordered, ordered: false))
                unordered.removeAll()
            }
            if !ordered.isEmpty {
                blocks.append(.list(ordered, ordered: true))
                ordered.removeAll()
            }
        }
        func flushAll() {
            flushParagraph()
            flushLists()
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine

            // Fenced code block boundaries (```...```). Inside the fence
            // we collect lines verbatim.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inFence = false
                } else {
                    flushAll()
                    inFence = true
                }
                continue
            }
            if inFence {
                code.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line — paragraph / list break.
            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            // ATX headings (# .. ######).
            if let heading = Self.matchHeading(trimmed) {
                flushAll()
                blocks.append(.heading(heading.level, heading.text))
                continue
            }

            // Unordered list.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                if !ordered.isEmpty { flushLists() }
                unordered.append(String(trimmed.dropFirst(2)))
                continue
            }

            // Ordered list (1. / 1)).
            if let orderedItem = Self.matchOrderedItem(trimmed) {
                flushParagraph()
                if !unordered.isEmpty { flushLists() }
                ordered.append(orderedItem)
                continue
            }

            // Regular paragraph line — accumulate. Adjacent lines merge
            // into one paragraph so bold/links don't break across.
            flushLists()
            paragraph.append(trimmed)
        }

        // Unclosed fence or trailing content.
        if inFence, !code.isEmpty {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func matchHeading(_ s: String) -> (level: Int, text: String)? {
        var i = 0
        for ch in s {
            if ch == "#" { i += 1 } else { break }
            if i > 6 { return nil }
        }
        guard i > 0, i < s.count else { return nil }
        let rest = s.index(s.startIndex, offsetBy: i)
        let afterHashes = String(s[rest...])
        guard afterHashes.hasPrefix(" ") else { return nil }
        return (i, String(afterHashes.dropFirst()))
    }

    private static func matchOrderedItem(_ s: String) -> String? {
        // 1. foo  |  1) foo
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
        guard idx != s.startIndex, idx < s.endIndex else { return nil }
        let sep = s[idx]
        guard sep == "." || sep == ")" else { return nil }
        let afterSep = s.index(after: idx)
        guard afterSep < s.endIndex, s[afterSep] == " " else { return nil }
        return String(s[s.index(after: afterSep)...])
    }
}
