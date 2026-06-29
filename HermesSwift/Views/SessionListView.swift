import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var organization: SessionOrganizationStore
    @Binding var path: [HermesSession]
    @State private var showSettings = false
    @State private var showNewChat = false
    @State private var searchText = ""
    @State private var selectedSource = "All"
    @State private var sessionToRename: HermesSession?
    @State private var hideTinySessions = false

    private var sourceOptions: [String] {
        let sources = Set(store.sessions.compactMap { normalizedSource($0.source) }.filter { !$0.isEmpty })
        return ["All", "Pinned", "Archived"] + sources.sorted()
    }

    private var filteredSessions: [HermesSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.sessions.filter { session in
            if hideTinySessions && isTinyNoise(session) { return false }
            if selectedSource != "Archived" && organization.isArchived(session) { return false }
            if selectedSource == "Pinned" && !organization.isPinned(session) { return false }
            if selectedSource == "Archived" && !organization.isArchived(session) { return false }
            if selectedSource != "All" && selectedSource != "Pinned" && selectedSource != "Archived" && normalizedSource(session.source) != selectedSource { return false }
            guard !query.isEmpty else { return true }
            return searchableText(for: session).contains(query)
        }
        .sorted { lhs, rhs in
            let leftPinned = organization.isPinned(lhs)
            let rightPinned = organization.isPinned(rhs)
            if selectedSource != "Archived", leftPinned != rightPinned { return leftPinned && !rightPinned }
            return (lhs.lastActive ?? lhs.startedAt ?? 0) > (rhs.lastActive ?? rhs.startedAt ?? 0)
        }
    }

    var body: some View {
        List {
            if let error = store.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(TerminalTheme.secondaryText)
                    TextField("Search sessions, source, model…", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(TerminalTheme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sourceOptions, id: \.self) { source in
                            Button { selectedSource = source } label: {
                                Label(source, systemImage: iconName(for: source))
                                    .font(.caption)
                                    .foregroundStyle(TerminalTheme.text)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selectedSource == source ? TerminalTheme.userBubble : TerminalTheme.fieldFill, in: Capsule())
                                    .overlay { Capsule().strokeBorder(selectedSource == source ? TerminalTheme.border : TerminalTheme.faintBorder, lineWidth: 0.8) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Toggle("Hide tiny/noisy sessions", isOn: $hideTinySessions)
                    .font(.caption)
            }

            Section {
                if filteredSessions.isEmpty && !store.isLoadingSessions {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Sessions" : "No Matches",
                        systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "Pull to refresh or create a new chat." : "Try a title, source, model, or session id.")
                    )
                } else {
                    ForEach(filteredSessions) { session in
                        NavigationLink(value: session) {
                            SessionRow(
                                session: session,
                                displayTitle: organization.displayTitle(for: session),
                                isPinned: organization.isPinned(session),
                                isArchived: organization.isArchived(session)
                            )
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { organization.togglePinned(session) } label: {
                                Label(organization.isPinned(session) ? "Unpin" : "Pin", systemImage: organization.isPinned(session) ? "pin.slash" : "pin.fill")
                            }
                            .tint(.yellow)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { organization.toggleArchived(session) } label: {
                                Label(organization.isArchived(session) ? "Unarchive" : "Archive", systemImage: organization.isArchived(session) ? "archivebox.fill" : "archivebox")
                            }
                            .tint(.gray)

                            Button { sessionToRename = session } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button { organization.togglePinned(session) } label: {
                                Label(organization.isPinned(session) ? "Unpin" : "Pin", systemImage: organization.isPinned(session) ? "pin.slash" : "pin.fill")
                            }
                            Button { sessionToRename = session } label: {
                                Label("Rename Locally", systemImage: "pencil")
                            }
                            if organization.titleOverrides[session.id] != nil {
                                Button { organization.resetLocalTitle(session) } label: {
                                    Label("Reset Local Title", systemImage: "arrow.counterclockwise")
                                }
                            }
                            Button { organization.toggleArchived(session) } label: {
                                Label(organization.isArchived(session) ? "Unarchive" : "Archive", systemImage: organization.isArchived(session) ? "archivebox.fill" : "archivebox")
                            }
                        }
                        .listRowBackground(TerminalTheme.background)
                    }
                }
            } header: {
                Text(headerText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TerminalTheme.background)
        .foregroundStyle(TerminalTheme.text)
        .overlay {
            if store.isLoadingSessions && store.sessions.isEmpty { ProgressView("Loading sessions…") }
        }
        .navigationTitle("HermesSwift")
        .navigationDestination(for: HermesSession.self) { session in
            ChatView(session: session)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gear") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                    .disabled(store.isLoadingSessions)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet(defaultProfile: settings.selectedProfile, defaultModel: settings.selectedModel) { request in
                await createSession(request: request)
            }
        }
        .sheet(item: $sessionToRename) { session in
            RenameSessionSheet(session: session, currentTitle: organization.displayTitle(for: session)) { newTitle in
                organization.rename(session, to: newTitle)
            }
        }
    }

    private var headerText: String {
        let base = searchText.isEmpty ? selectedSourceLabel : "Matches"
        return "\(base) (\(filteredSessions.count) of \(visibleSessionCount))"
    }

    private var selectedSourceLabel: String {
        selectedSource == "All" ? "Sessions" : selectedSource
    }

    private var visibleSessionCount: Int {
        selectedSource == "Archived" ? store.sessions.filter { organization.isArchived($0) }.count : store.sessions.filter { !organization.isArchived($0) }.count
    }

    private func load() async {
        guard let client = try? settings.makeClient() else { return }
        await store.loadSessions(client: client)
    }

    private func createSession(request: NewChatRequest) async {
        guard let client = try? settings.makeClient() else { return }
        let profile = request.profile == "current" ? settings.selectedProfileForRequest : normalizedProfileForRequest(request.profile)
        let model = request.model == "current" ? settings.selectedModelForRequest : normalizedModelForRequest(request.model)
        if let session = await store.createSession(client: client, title: request.title, model: model, profile: profile) {
            path.append(session)
            if request.pin { organization.togglePinned(session) }
            let message = request.firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty {
                store.startSend(client: client, text: message, model: model, profile: profile)
            }
        }
    }

    private func normalizedProfileForRequest(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "default" ? nil : trimmed
    }

    private func normalizedModelForRequest(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "hermes-agent" ? nil : trimmed
    }

    private func normalizedSource(_ source: String?) -> String {
        let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return "Other" }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private func isTinyNoise(_ session: HermesSession) -> Bool {
        let count = session.messageCount ?? 0
        let preview = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return count <= 1 && preview.isEmpty
    }

    private func searchableText(for session: HermesSession) -> String {
        [organization.displayTitle(for: session), session.id, session.source, session.model, session.preview, session.detailLine]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }

    private func iconName(for source: String) -> String {
        switch source.lowercased() {
        case "all": return "tray.full"
        case "pinned": return "pin.fill"
        case "archived": return "archivebox.fill"
        case "telegram": return "paperplane.fill"
        case "discord": return "bubble.left.and.bubble.right.fill"
        case "matrix": return "lock.shield.fill"
        case "api", "api_server": return "network"
        case "cli": return "terminal.fill"
        default: return "circle.grid.2x2.fill"
        }
    }
}

private struct SessionRow: View {
    let session: HermesSession
    let displayTitle: String
    let isPinned: Bool
    let isArchived: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
                if isArchived {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(TerminalTheme.secondaryText)
                        .font(.caption)
                }
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(2)
            }

            if !session.subtitle.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: session.source))
                    Text(session.subtitle)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !session.detailLine.isEmpty {
                Text(session.detailLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 6)
    }

    private func iconName(for source: String?) -> String {
        switch source?.lowercased() {
        case "telegram": return "paperplane.fill"
        case "discord": return "bubble.left.and.bubble.right.fill"
        case "matrix": return "lock.shield.fill"
        case "api", "api_server": return "network"
        case "cli": return "terminal.fill"
        default: return "circle.grid.2x2.fill"
        }
    }
}

private struct RenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: HermesSession
    let currentTitle: String
    let onSave: (String) -> Void
    @State private var title: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Local Rename") {
                    TextField("Session title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    Text("This only changes the title inside the iPhone app. The Hermes server session id/title is untouched.")
                        .font(.caption)
                        .foregroundStyle(TerminalTheme.secondaryText)
                }
                Section("Session") {
                    Text(session.id)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Rename Session")
            .onAppear { title = currentTitle }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title)
                        dismiss()
                    }
                }
            }
        }
    }
}
