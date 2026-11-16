import SwiftUI
import SynapseCore

/// Model output rendered as Markdown: blocks from `MarkdownBlock.parse`, inline styles (bold, italics, inline code,
/// links) from Foundation. Works on partial text while a reply streams.
struct MarkdownView: View {
    let text: String
    // Regular weight, so **bold** and headings stand out from the body.
    var font: Font = .title3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s).font(font)
        case .heading(let level, let s):
            inline(s).font(level <= 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.bold) : .headline)
                .padding(.top, 4)
        case .listItem(let marker, let s, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(font).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                inline(s).font(font)
            }
            .padding(.leading, CGFloat(depth) * 20)
        case .code(let language, let s):
            VStack(alignment: .leading, spacing: 6) {
                if let language { Text(language).font(.mono(.caption2)).foregroundStyle(.secondary) }
                ScrollView(.horizontal) {
                    Text(s).font(.mono(.callout)).fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 2)
                inline(s).font(font).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: options)) ?? AttributedString(s))
    }
}
