import SwiftUI

struct MarkdownNoteEditor: View {
    @Binding var text: String
    @State private var mode: Mode = .write

    private enum Mode: String, CaseIterable {
        case write = "Write"
        case preview = "Preview"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                if mode == .write {
                    Divider()
                        .frame(height: 20)
                    formatButton("H1", help: "Heading") { insert("\n# Heading\n") }
                    formatButton("B", help: "Bold") { insert("**bold text**") }
                    formatButton("I", help: "Italic") { insert("_italic text_") }
                    Button {
                        insert("\n- ")
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .help("Bulleted list")
                    Button {
                        insert("\n- [ ] ")
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .help("Checklist")
                    Button {
                        insert("[link](https://)")
                    } label: {
                        Image(systemName: "link")
                    }
                    .help("Link")
                }
                Spacer()
                Text("Markdown · autosaved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if mode == .write {
                TextEditor(text: $text)
                    .font(.body)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(12)
            } else {
                ScrollView {
                    Text(rendered)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: text.isEmpty ? "_Nothing here yet._" : text,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(text)
    }

    private func insert(_ value: String) {
        text += value
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
