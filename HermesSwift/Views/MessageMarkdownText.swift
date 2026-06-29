import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct MessageMarkdownText: View {
    let text: String
    let alignment: TextAlignment

    private var parts: [MarkdownPart] { MarkdownPart.parse(text) }

    var body: some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let value):
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(attributed(value))
                            .foregroundStyle(TerminalTheme.text)
                            .textSelection(.enabled)
                            .multilineTextAlignment(alignment)
                    }
                case .code(let language, let value):
                    CodeBlockView(language: language, code: value)
                }
            }
        }
    }

    private func attributed(_ value: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(value)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(languageLabel, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TerminalTheme.secondaryText)
                Spacer()
                Button {
                    copy(code)
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? TerminalTheme.text : TerminalTheme.secondaryText)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(TerminalTheme.text)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            TerminalTheme.card,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(TerminalTheme.border, lineWidth: 0.8)
        }
    }

    private var languageLabel: String {
        let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "CODE" : raw.uppercased()
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        Haptics.success()
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { copied = false }
        }
    }
}

private enum MarkdownPart: Hashable {
    case text(String)
    case code(language: String?, String)

    static func parse(_ text: String) -> [MarkdownPart] {
        var result: [MarkdownPart] = []
        var remaining = text[...]
        while let start = remaining.range(of: "```") {
            let before = String(remaining[..<start.lowerBound])
            if !before.isEmpty { result.append(.text(before)) }
            remaining = remaining[start.upperBound...]
            let languageLineEnd = remaining.firstIndex(of: "\n")
            var language: String?
            if let languageLineEnd {
                let rawLanguage = String(remaining[..<languageLineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                language = rawLanguage.isEmpty ? nil : rawLanguage
                remaining = remaining[remaining.index(after: languageLineEnd)...]
            } else {
                result.append(.code(language: nil, String(remaining)))
                return result
            }
            if let end = remaining.range(of: "```") {
                result.append(.code(language: language, String(remaining[..<end.lowerBound]).trimmingCharacters(in: .newlines)))
                remaining = remaining[end.upperBound...]
            } else {
                result.append(.code(language: language, String(remaining).trimmingCharacters(in: .newlines)))
                return result
            }
        }
        let tail = String(remaining)
        if !tail.isEmpty { result.append(.text(tail)) }
        return result.isEmpty ? [.text(text)] : result
    }
}
