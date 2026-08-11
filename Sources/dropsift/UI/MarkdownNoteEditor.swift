import AppKit
import SwiftUI

struct MarkdownNoteEditor: View {
    @Binding var text: String
    var placeholder = "Start writing…"
    var accessibilityIdentifier = "markdown-note-editor"

    @State private var command: MarkdownEditorCommand?
    @State private var showingLinkEditor = false
    @State private var linkDestination = "https://"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            ZStack(alignment: .topLeading) {
                RichMarkdownTextView(markdown: $text, command: command)
                    .accessibilityIdentifier(accessibilityIdentifier)

                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 7) {
            Menu {
                Button("Title") { send(.heading(1)) }
                Button("Heading") { send(.heading(2)) }
                Button("Subheading") { send(.heading(3)) }
                Divider()
                Button("Body") { send(.paragraph) }
            } label: {
                Label("Style", systemImage: "textformat.size")
            }
            .fixedSize()

            Divider()
                .frame(height: 20)

            formatButton("B", help: "Bold · ⌘B") { send(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            formatButton("I", help: "Italic · ⌘I") { send(.italic) }
                .keyboardShortcut("i", modifiers: .command)

            Button {
                send(.inlineCode)
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .help("Inline code")

            Button {
                showingLinkEditor = true
            } label: {
                Image(systemName: "link")
            }
            .help("Add link")
            .popover(isPresented: $showingLinkEditor, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Link destination")
                        .font(.headline)
                    TextField("https://", text: $linkDestination)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .onSubmit { applyLink() }
                    HStack {
                        Spacer()
                        Button("Cancel") { showingLinkEditor = false }
                        Button("Apply") { applyLink() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
            }

            Divider()
                .frame(height: 20)

            Button {
                send(.bulletList)
            } label: {
                Image(systemName: "list.bullet")
            }
            .help("Bulleted list")

            Button {
                send(.numberedList)
            } label: {
                Image(systemName: "list.number")
            }
            .help("Numbered list")

            Button {
                send(.checklist)
            } label: {
                Image(systemName: "checklist")
            }
            .help("Checklist")

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func send(_ action: MarkdownEditorAction) {
        command = MarkdownEditorCommand(action: action)
    }

    private func applyLink() {
        let destination = linkDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        send(.link(destination))
        showingLinkEditor = false
    }

    private func formatButton(
        _ label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .frame(minWidth: 18)
        }
        .help(help)
    }
}

private struct MarkdownEditorCommand: Equatable {
    let id = UUID()
    let action: MarkdownEditorAction
}

private enum MarkdownEditorAction: Equatable {
    case heading(Int)
    case paragraph
    case bold
    case italic
    case inlineCode
    case bulletList
    case numberedList
    case checklist
    case link(String)
}

private struct RichMarkdownTextView: NSViewRepresentable {
    @Binding var markdown: String
    let command: MarkdownEditorCommand?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.apply(markdown: markdown, preservingSelection: false)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if markdown != context.coordinator.lastMarkdown {
            context.coordinator.apply(markdown: markdown, preservingSelection: true)
        }
        if let command,
           command.id != context.coordinator.lastCommandID {
            context.coordinator.lastCommandID = command.id
            context.coordinator.perform(command.action)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichMarkdownTextView
        weak var textView: NSTextView?
        var lastMarkdown: String
        var lastCommandID: UUID?
        private var isApplyingMarkdown = false

        init(parent: RichMarkdownTextView) {
            self.parent = parent
            lastMarkdown = parent.markdown
        }

        func apply(markdown: String, preservingSelection: Bool) {
            guard let textView else { return }
            isApplyingMarkdown = true
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                MarkdownRichTextCodec.attributedString(from: markdown)
            )
            if preservingSelection {
                let location = min(selection.location, textView.string.utf16.count)
                let length = min(
                    selection.length,
                    max(0, textView.string.utf16.count - location)
                )
                textView.setSelectedRange(NSRange(location: location, length: length))
            }
            if textView.string.isEmpty {
                textView.typingAttributes = MarkdownRichTextCodec.visualTypingAttributes(
                    from: [.dropsiftBlock: MarkdownBlock.paragraph.rawValue]
                )
            }
            lastMarkdown = markdown
            isApplyingMarkdown = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingMarkdown else { return }
            publishMarkdown()
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let storage = textView.textStorage,
                  storage.length > 0
            else {
                return false
            }

            let selection = textView.selectedRange()
            let lookupLocation = min(
                max(0, selection.location - (selection.location == storage.length ? 1 : 0)),
                storage.length - 1
            )
            let block = MarkdownRichTextCodec.block(at: lookupLocation, in: storage)
            guard [.bullet, .numbered, .checklist, .checked].contains(block) else {
                return false
            }

            let source = storage.string as NSString
            let paragraphRange = source.paragraphRange(
                for: NSRange(location: lookupLocation, length: 0)
            )
            let line = source.substring(with: paragraphRange)
                .trimmingCharacters(in: .newlines)
            let prefixLength = block.visiblePrefixLength(in: line)
            let body = (line as NSString)
                .substring(from: min(prefixLength, (line as NSString).length))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if body.isEmpty {
                applyBlock(.paragraph, in: textView, storage: storage)
                return false
            }

            let prefix: String
            if block == .numbered {
                let number = Int(line.prefix { $0.isNumber }) ?? 0
                prefix = "\(number + 1). "
            } else if block == .bullet {
                prefix = MarkdownBlock.bullet.visiblePrefix
            } else {
                prefix = MarkdownBlock.checklist.visiblePrefix
            }
            textView.typingAttributes = MarkdownRichTextCodec.visualTypingAttributes(
                from: [.dropsiftBlock: block.rawValue]
            )
            textView.insertText("\n" + prefix, replacementRange: selection)
            if let updatedStorage = textView.textStorage {
                let updatedSource = updatedStorage.string as NSString
                let location = min(textView.selectedRange().location, updatedSource.length)
                let updatedParagraph = updatedSource.paragraphRange(
                    for: NSRange(location: location, length: 0)
                )
                updatedStorage.addAttribute(
                    .dropsiftBlock,
                    value: (block == .checked ? MarkdownBlock.checklist : block).rawValue,
                    range: updatedParagraph
                )
                MarkdownRichTextCodec.applyVisualStyles(to: updatedStorage)
            }
            publishMarkdown()
            return true
        }

        func perform(_ action: MarkdownEditorAction) {
            guard let textView, let storage = textView.textStorage else { return }
            switch action {
            case .heading(let level):
                applyBlock(.heading(level), in: textView, storage: storage)
            case .paragraph:
                applyBlock(.paragraph, in: textView, storage: storage)
            case .bulletList:
                applyBlock(.bullet, in: textView, storage: storage)
            case .numberedList:
                applyBlock(.numbered, in: textView, storage: storage)
            case .checklist:
                applyBlock(.checklist, in: textView, storage: storage)
            case .bold:
                toggleInline(.dropsiftStrong, in: textView, storage: storage)
            case .italic:
                toggleInline(.dropsiftEmphasis, in: textView, storage: storage)
            case .inlineCode:
                toggleInline(.dropsiftCode, in: textView, storage: storage)
            case .link(let destination):
                applyLink(destination, in: textView, storage: storage)
            }
        }

        private func toggleInline(
            _ key: NSAttributedString.Key,
            in textView: NSTextView,
            storage: NSMutableAttributedString
        ) {
            let selection = textView.selectedRange()
            if selection.length == 0 {
                var attributes = textView.typingAttributes
                if attributes[key] != nil {
                    attributes.removeValue(forKey: key)
                } else {
                    attributes[key] = true
                }
                textView.typingAttributes = MarkdownRichTextCodec.visualTypingAttributes(
                    from: attributes
                )
                return
            }

            let enabled = storage.attribute(
                key,
                at: min(selection.location, max(0, storage.length - 1)),
                effectiveRange: nil
            ) != nil
            if enabled {
                storage.removeAttribute(key, range: selection)
            } else {
                storage.addAttribute(key, value: true, range: selection)
            }
            MarkdownRichTextCodec.applyVisualStyles(to: storage)
            textView.setSelectedRange(selection)
            publishMarkdown()
        }

        private func applyLink(
            _ destination: String,
            in textView: NSTextView,
            storage: NSMutableAttributedString
        ) {
            var selection = textView.selectedRange()
            if selection.length == 0 {
                let label = destination
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                textView.insertText(
                    label.isEmpty ? "link" : label,
                    replacementRange: selection
                )
                selection = NSRange(
                    location: selection.location,
                    length: (label.isEmpty ? "link" : label).utf16.count
                )
            }
            storage.addAttribute(.link, value: destination, range: selection)
            MarkdownRichTextCodec.applyVisualStyles(to: storage)
            textView.setSelectedRange(selection)
            publishMarkdown()
        }

        private func applyBlock(
            _ block: MarkdownBlock,
            in textView: NSTextView,
            storage: NSMutableAttributedString
        ) {
            if storage.length == 0 {
                storage.append(NSAttributedString(string: block.visiblePrefix))
            }

            let selection = textView.selectedRange()
            let source = storage.string as NSString
            let safeLocation = min(selection.location, source.length)
            let safeLength = min(selection.length, max(0, source.length - safeLocation))
            let paragraphRange = source.paragraphRange(
                for: NSRange(location: safeLocation, length: safeLength)
            )

            var lineRanges: [NSRange] = []
            var cursor = paragraphRange.location
            while cursor < NSMaxRange(paragraphRange) {
                let line = source.lineRange(for: NSRange(location: cursor, length: 0))
                lineRanges.append(line)
                let next = NSMaxRange(line)
                if next <= cursor { break }
                cursor = next
            }
            if lineRanges.isEmpty {
                lineRanges = [paragraphRange]
            }

            for (reverseIndex, originalRange) in lineRanges.reversed().enumerated() {
                let lineNumber = lineRanges.count - reverseIndex
                let currentString = storage.string as NSString
                let boundedLocation = min(originalRange.location, currentString.length)
                let boundedLength = min(
                    originalRange.length,
                    max(0, currentString.length - boundedLocation)
                )
                var lineRange = currentString.lineRange(
                    for: NSRange(location: boundedLocation, length: boundedLength)
                )
                let currentBlock = MarkdownRichTextCodec.block(
                    at: lineRange.location,
                    in: storage
                )
                let existingPrefixLength = currentBlock.visiblePrefixLength(
                    in: storage.attributedSubstring(from: lineRange).string
                )
                if existingPrefixLength > 0 {
                    storage.replaceCharacters(
                        in: NSRange(
                            location: lineRange.location,
                            length: existingPrefixLength
                        ),
                        with: ""
                    )
                    lineRange.length -= existingPrefixLength
                }

                let prefix = block == .numbered ? "\(lineNumber). " : block.visiblePrefix
                if !prefix.isEmpty {
                    storage.insert(
                        NSAttributedString(string: prefix),
                        at: lineRange.location
                    )
                    lineRange.length += prefix.utf16.count
                }
                storage.addAttribute(
                    .dropsiftBlock,
                    value: block.rawValue,
                    range: lineRange
                )
            }

            MarkdownRichTextCodec.applyVisualStyles(to: storage)
            let newSource = storage.string as NSString
            let newLocation = min(selection.location, newSource.length)
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
            publishMarkdown()
        }

        private func publishMarkdown() {
            guard let storage = textView?.textStorage else { return }
            let markdown = MarkdownRichTextCodec.markdown(from: storage)
            lastMarkdown = markdown
            if parent.markdown != markdown {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.parent.markdown != markdown else { return }
                    self.parent.markdown = markdown
                }
            }
        }
    }
}

private extension NSAttributedString.Key {
    static let dropsiftBlock = NSAttributedString.Key("DropsiftMarkdownBlock")
    static let dropsiftStrong = NSAttributedString.Key("DropsiftMarkdownStrong")
    static let dropsiftEmphasis = NSAttributedString.Key("DropsiftMarkdownEmphasis")
    static let dropsiftCode = NSAttributedString.Key("DropsiftMarkdownCode")
}

private enum MarkdownBlock: Equatable {
    case paragraph
    case heading(Int)
    case bullet
    case numbered
    case checklist
    case checked
    case quote
    case codeBlock

    var rawValue: String {
        switch self {
        case .paragraph: "paragraph"
        case .heading(let level): "heading-\(level)"
        case .bullet: "bullet"
        case .numbered: "numbered"
        case .checklist: "checklist"
        case .checked: "checked"
        case .quote: "quote"
        case .codeBlock: "code-block"
        }
    }

    init(rawValue: String) {
        if rawValue.hasPrefix("heading-"),
           let level = Int(rawValue.dropFirst("heading-".count)) {
            self = .heading(level)
            return
        }
        switch rawValue {
        case "bullet": self = .bullet
        case "numbered": self = .numbered
        case "checklist": self = .checklist
        case "checked": self = .checked
        case "quote": self = .quote
        case "code-block": self = .codeBlock
        default: self = .paragraph
        }
    }

    var visiblePrefix: String {
        switch self {
        case .bullet: "• "
        case .numbered: "1. "
        case .checklist: "☐ "
        case .checked: "☑ "
        case .quote: "▍ "
        default: ""
        }
    }

    func visiblePrefixLength(in line: String) -> Int {
        let value = line as NSString
        switch self {
        case .bullet:
            return line.hasPrefix("• ") ? 2 : 0
        case .checklist:
            return line.hasPrefix("☐ ") ? 2 : 0
        case .checked:
            return line.hasPrefix("☑ ") ? 2 : 0
        case .quote:
            return line.hasPrefix("▍ ") ? 2 : 0
        case .numbered:
            let match = try? NSRegularExpression(pattern: #"^\d+\. "#)
                .firstMatch(in: line, range: NSRange(location: 0, length: value.length))
            return match?.range.length ?? 0
        default:
            return 0
        }
    }
}

enum MarkdownRichTextCodec {
    private struct InlinePattern {
        enum Kind {
            case strong
            case emphasis
            case code
            case link
        }

        let expression: NSRegularExpression
        let kind: Kind
        let contentGroup: Int
        let destinationGroup: Int?
    }

    private struct InlineSignature: Equatable {
        let strong: Bool
        let emphasis: Bool
        let code: Bool
        let link: String?
    }

    private static let inlinePatterns: [InlinePattern] = [
        InlinePattern(
            expression: try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]+)\)"#),
            kind: .link,
            contentGroup: 1,
            destinationGroup: 2
        ),
        InlinePattern(
            expression: try! NSRegularExpression(pattern: #"\*\*([^\n]+?)\*\*"#),
            kind: .strong,
            contentGroup: 1,
            destinationGroup: nil
        ),
        InlinePattern(
            expression: try! NSRegularExpression(pattern: #"__([^\n]+?)__"#),
            kind: .strong,
            contentGroup: 1,
            destinationGroup: nil
        ),
        InlinePattern(
            expression: try! NSRegularExpression(pattern: #"\*([^\n*]+?)\*"#),
            kind: .emphasis,
            contentGroup: 1,
            destinationGroup: nil
        ),
        InlinePattern(
            expression: try! NSRegularExpression(pattern: #"_([^\n_]+?)_"#),
            kind: .emphasis,
            contentGroup: 1,
            destinationGroup: nil
        ),
        InlinePattern(
            expression: try! NSRegularExpression(pattern: #"`([^\n`]+?)`"#),
            kind: .code,
            contentGroup: 1,
            destinationGroup: nil
        ),
    ]

    static func attributedString(from markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false

        for (index, sourceLine) in lines.enumerated() {
            if sourceLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }

            let parsed = parseBlock(sourceLine, inCodeBlock: inCodeBlock)
            let line = NSMutableAttributedString(string: parsed.block.visiblePrefix)
            let content = inCodeBlock
                ? NSMutableAttributedString(string: parsed.content)
                : parseInline(parsed.content)
            line.append(content)
            if line.length > 0 {
                line.addAttribute(
                    .dropsiftBlock,
                    value: parsed.block.rawValue,
                    range: NSRange(location: 0, length: line.length)
                )
            }
            output.append(line)
            if index < lines.count - 1 {
                let newline = NSMutableAttributedString(string: "\n")
                newline.addAttribute(
                    .dropsiftBlock,
                    value: parsed.block.rawValue,
                    range: NSRange(location: 0, length: 1)
                )
                output.append(newline)
            }
        }

        applyVisualStyles(to: output)
        return output
    }

    static func markdown(from attributedString: NSAttributedString) -> String {
        guard attributedString.length > 0 else { return "" }
        let source = attributedString.string as NSString
        var lines: [String] = []
        var cursor = 0
        var inCodeBlock = false

        while cursor < source.length {
            let fullRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            var contentLength = fullRange.length
            while contentLength > 0 {
                let character = source.character(at: fullRange.location + contentLength - 1)
                if character == 10 || character == 13 {
                    contentLength -= 1
                } else {
                    break
                }
            }
            var contentRange = NSRange(location: fullRange.location, length: contentLength)
            let block = self.block(at: fullRange.location, in: attributedString)
            let lineString = source.substring(with: contentRange)
            let prefixLength = block.visiblePrefixLength(in: lineString)
            contentRange.location += prefixLength
            contentRange.length = max(0, contentRange.length - prefixLength)

            if block == .codeBlock, !inCodeBlock {
                lines.append("```")
                inCodeBlock = true
            } else if block != .codeBlock, inCodeBlock {
                lines.append("```")
                inCodeBlock = false
            }

            let content = block == .codeBlock
                ? source.substring(with: contentRange)
                : inlineMarkdown(
                    from: attributedString.attributedSubstring(from: contentRange)
                )
            switch block {
            case .heading(let level):
                lines.append(String(repeating: "#", count: max(1, min(6, level))) + " " + content)
            case .bullet:
                lines.append("- " + content)
            case .numbered:
                let numberPrefix = lineString.prefix(prefixLength)
                lines.append((numberPrefix.isEmpty ? "1. " : String(numberPrefix)) + content)
            case .checklist:
                lines.append("- [ ] " + content)
            case .checked:
                lines.append("- [x] " + content)
            case .quote:
                lines.append("> " + content)
            case .paragraph, .codeBlock:
                lines.append(content)
            }

            let next = NSMaxRange(fullRange)
            if next <= cursor { break }
            cursor = next
        }
        if inCodeBlock {
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }

    static func applyVisualStyles(to storage: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }
        storage.removeAttribute(.font, range: fullRange)
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        storage.removeAttribute(.paragraphStyle, range: fullRange)
        storage.removeAttribute(.underlineStyle, range: fullRange)

        let snapshot = storage.copy() as! NSAttributedString
        snapshot.enumerateAttributes(in: fullRange) { attributes, range, _ in
            storage.addAttributes(visualAttributes(from: attributes), range: range)
        }
    }

    static func visualTypingAttributes(
        from attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        for key in [
            NSAttributedString.Key.font,
            .foregroundColor,
            .backgroundColor,
            .paragraphStyle,
            .underlineStyle,
        ] {
            result.removeValue(forKey: key)
        }
        result.merge(visualAttributes(from: result)) { _, new in new }
        return result
    }

    fileprivate static func block(
        at location: Int,
        in attributedString: NSAttributedString
    ) -> MarkdownBlock {
        guard attributedString.length > 0 else { return .paragraph }
        let safeLocation = min(max(0, location), attributedString.length - 1)
        let rawValue = attributedString.attribute(
            .dropsiftBlock,
            at: safeLocation,
            effectiveRange: nil
        ) as? String
        return MarkdownBlock(rawValue: rawValue ?? "paragraph")
    }

    private static func parseBlock(
        _ source: String,
        inCodeBlock: Bool
    ) -> (block: MarkdownBlock, content: String) {
        if inCodeBlock {
            return (.codeBlock, source)
        }
        if let match = source.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let marker = source[match].filter { $0 == "#" }
            return (.heading(marker.count), String(source[match.upperBound...]))
        }
        if source.hasPrefix("- [ ] ") {
            return (.checklist, String(source.dropFirst(6)))
        }
        if source.hasPrefix("- [x] ") || source.hasPrefix("- [X] ") {
            return (.checked, String(source.dropFirst(6)))
        }
        if source.hasPrefix("- ") || source.hasPrefix("* ") || source.hasPrefix("+ ") {
            return (.bullet, String(source.dropFirst(2)))
        }
        if let match = source.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return (.numbered, String(source[match.upperBound...]))
        }
        if source.hasPrefix("> ") {
            return (.quote, String(source.dropFirst(2)))
        }
        return (.paragraph, source)
    }

    private static func parseInline(
        _ source: String,
        inherited: [NSAttributedString.Key: Any] = [:]
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        let nsSource = source as NSString
        let searchRange = NSRange(location: 0, length: nsSource.length)
        var selected: (pattern: InlinePattern, match: NSTextCheckingResult)?

        for pattern in inlinePatterns {
            guard let match = pattern.expression.firstMatch(
                in: source,
                range: searchRange
            ) else { continue }
            if selected == nil || match.range.location < selected!.match.range.location {
                selected = (pattern, match)
            }
        }

        guard let selected else {
            result.append(NSAttributedString(string: source, attributes: inherited))
            return result
        }

        if selected.match.range.location > 0 {
            let before = nsSource.substring(
                with: NSRange(location: 0, length: selected.match.range.location)
            )
            result.append(NSAttributedString(string: before, attributes: inherited))
        }

        let contentRange = selected.match.range(at: selected.pattern.contentGroup)
        let content = nsSource.substring(with: contentRange)
        var childAttributes = inherited
        switch selected.pattern.kind {
        case .strong:
            childAttributes[.dropsiftStrong] = true
        case .emphasis:
            childAttributes[.dropsiftEmphasis] = true
        case .code:
            childAttributes[.dropsiftCode] = true
        case .link:
            if let group = selected.pattern.destinationGroup {
                childAttributes[.link] = nsSource.substring(
                    with: selected.match.range(at: group)
                )
            }
        }
        result.append(parseInline(content, inherited: childAttributes))

        let remainderLocation = NSMaxRange(selected.match.range)
        if remainderLocation < nsSource.length {
            let remainder = nsSource.substring(
                from: remainderLocation
            )
            result.append(parseInline(remainder, inherited: inherited))
        }
        return result
    }

    private static func visualAttributes(
        from attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let block = MarkdownBlock(
            rawValue: attributes[.dropsiftBlock] as? String ?? "paragraph"
        )
        let isCode = attributes[.dropsiftCode] != nil || block == .codeBlock
        let size: CGFloat
        let defaultWeight: NSFont.Weight
        switch block {
        case .heading(1):
            size = 28
            defaultWeight = .bold
        case .heading(2):
            size = 22
            defaultWeight = .semibold
        case .heading:
            size = 18
            defaultWeight = .semibold
        default:
            size = 15
            defaultWeight = .regular
        }

        var font = isCode
            ? NSFont.monospacedSystemFont(ofSize: max(13, size - 1), weight: defaultWeight)
            : NSFont.systemFont(ofSize: size, weight: defaultWeight)
        let manager = NSFontManager.shared
        if attributes[.dropsiftStrong] != nil {
            font = manager.convert(font, toHaveTrait: .boldFontMask)
        }
        if attributes[.dropsiftEmphasis] != nil {
            font = manager.convert(font, toHaveTrait: .italicFontMask)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = block == .paragraph ? 5 : 7
        if case .heading = block {
            paragraph.paragraphSpacingBefore = 8
            paragraph.paragraphSpacing = 7
        }

        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        if isCode {
            result[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.15)
        }
        if attributes[.link] != nil {
            result[.foregroundColor] = NSColor.linkColor
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }

    private static func inlineMarkdown(
        from attributedString: NSAttributedString
    ) -> String {
        guard attributedString.length > 0 else { return "" }
        var output = ""
        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length)
        ) { attributes, range, _ in
            let signature = InlineSignature(
                strong: attributes[.dropsiftStrong] != nil,
                emphasis: attributes[.dropsiftEmphasis] != nil,
                code: attributes[.dropsiftCode] != nil,
                link: linkString(from: attributes[.link])
            )
            var value = (attributedString.string as NSString).substring(with: range)
            if signature.code {
                value = "`\(value.replacingOccurrences(of: "`", with: "\\`"))`"
            } else {
                value = escapeInlineMarkdown(value)
                if signature.strong && signature.emphasis {
                    value = "***\(value)***"
                } else if signature.strong {
                    value = "**\(value)**"
                } else if signature.emphasis {
                    value = "*\(value)*"
                }
            }
            if let link = signature.link {
                value = "[\(value)](\(link))"
            }
            output += value
        }
        return output
    }

    private static func linkString(from value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private static func escapeInlineMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: #"\"# + "*")
            .replacingOccurrences(of: "_", with: #"\"# + "_")
    }
}
