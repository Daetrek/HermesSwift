import SwiftUI

struct NewChatRequest {
    let title: String?
    let firstMessage: String?
    let profile: String?
    let model: String?
    let pin: Bool
}

private struct NewChatPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let profile: String?
    let model: String?
    let titlePrefix: String
    let firstMessagePlaceholder: String
    let defaultPin: Bool

    static let presets: [NewChatPreset] = [
        .init(id: "general", title: "General", subtitle: "Default Hermes chat", icon: "sparkles", profile: "current", model: "current", titlePrefix: "General", firstMessagePlaceholder: "What do you want Hermes to handle?", defaultPin: false),
        .init(id: "coding", title: "Coding", subtitle: "Code, automation, debugging", icon: "hammer.fill", profile: "current", model: "current", titlePrefix: "Coding", firstMessagePlaceholder: "Build/debug this technical task…", defaultPin: true),
        .init(id: "research", title: "Research", subtitle: "Research and source-backed findings", icon: "magnifyingglass", profile: "current", model: "current", titlePrefix: "Research", firstMessagePlaceholder: "Research this topic and cite sources…", defaultPin: false),
        .init(id: "voice", title: "Voice", subtitle: "Start a chat meant for voice mode", icon: "phone.fill", profile: "current", model: "current", titlePrefix: "Voice", firstMessagePlaceholder: "Optional first voice context…", defaultPin: false)
    ]
}

struct NewChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var firstMessage = ""
    @State private var isCreating = false
    @State private var selectedPreset = NewChatPreset.presets[0]
    @State private var pinSession = false

    let defaultProfile: String
    let defaultModel: String
    let onCreate: (NewChatRequest) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(NewChatPreset.presets) { preset in
                                Button { apply(preset) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: preset.icon)
                                            .font(.title3)
                                        Text(preset.title)
                                            .font(.caption.weight(.semibold))
                                        Text(preset.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(width: 126, alignment: .leading)
                                    .padding(10)
                                    .background(selectedPreset == preset ? TerminalTheme.text.opacity(0.22) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .strokeBorder(selectedPreset == preset ? TerminalTheme.text.opacity(0.45) : Color.clear, lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    LabeledContent("Profile") { Text(displayProfile).foregroundStyle(.secondary) }
                    LabeledContent("Model") { Text(displayModel).foregroundStyle(.secondary) }
                }

                Section("New Chat") {
                    TextField("Optional title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField(selectedPreset.firstMessagePlaceholder, text: $firstMessage, axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.sentences)
                    Toggle("Pin this session", isOn: $pinSession)
                }

                Section("Flow") {
                    Label("Creates a Hermes session, opens it, applies the preset profile/model, then sends the first message if provided.", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Chat")
            .onAppear { apply(selectedPreset) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        Task { await create() }
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private var displayProfile: String {
        if selectedPreset.profile == "current" { return "Current: \(defaultProfile)" }
        return selectedPreset.profile ?? "default"
    }

    private var displayModel: String {
        if selectedPreset.model == "current" { return "Current: \(defaultModel)" }
        return selectedPreset.model ?? "hermes-agent"
    }

    private func apply(_ preset: NewChatPreset) {
        selectedPreset = preset
        pinSession = preset.defaultPin
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = suggestedTitle(for: preset)
        }
    }

    private func suggestedTitle(for preset: NewChatPreset) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return "\(preset.titlePrefix) • \(formatter.string(from: Date()))"
    }

    private func create() async {
        isCreating = true
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMessage = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        await onCreate(NewChatRequest(
            title: cleanTitle.isEmpty ? nil : cleanTitle,
            firstMessage: cleanMessage.isEmpty ? nil : cleanMessage,
            profile: selectedPreset.profile,
            model: selectedPreset.model,
            pin: pinSession
        ))
        isCreating = false
        dismiss()
    }
}
