import Foundation

@MainActor
final class SessionOrganizationStore: ObservableObject {
    @Published private(set) var pinnedIDs: Set<String> = []
    @Published private(set) var archivedIDs: Set<String> = []
    @Published private(set) var titleOverrides: [String: String] = [:]

    private let pinnedKey = "sessionOrgPinnedIDs"
    private let archivedKey = "sessionOrgArchivedIDs"
    private let titlesKey = "sessionOrgTitleOverrides"

    init() {
        pinnedIDs = Self.loadStringSet(key: pinnedKey)
        archivedIDs = Self.loadStringSet(key: archivedKey)
        titleOverrides = Self.loadStringMap(key: titlesKey)
    }

    func isPinned(_ session: HermesSession) -> Bool { pinnedIDs.contains(session.id) }
    func isArchived(_ session: HermesSession) -> Bool { archivedIDs.contains(session.id) }

    func displayTitle(for session: HermesSession) -> String {
        if let override = titleOverrides[session.id], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return session.displayTitle
    }

    func togglePinned(_ session: HermesSession) {
        setPinned(session, pinned: !pinnedIDs.contains(session.id))
    }

    func setPinned(_ session: HermesSession, pinned: Bool) {
        if pinned { pinnedIDs.insert(session.id) } else { pinnedIDs.remove(session.id) }
        persistStringSet(pinnedIDs, key: pinnedKey)
    }

    func toggleArchived(_ session: HermesSession) {
        setArchived(session, archived: !archivedIDs.contains(session.id))
    }

    func setArchived(_ session: HermesSession, archived: Bool) {
        if archived {
            archivedIDs.insert(session.id)
            pinnedIDs.remove(session.id)
            persistStringSet(pinnedIDs, key: pinnedKey)
        } else {
            archivedIDs.remove(session.id)
        }
        persistStringSet(archivedIDs, key: archivedKey)
    }

    func rename(_ session: HermesSession, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == session.displayTitle {
            titleOverrides.removeValue(forKey: session.id)
        } else {
            titleOverrides[session.id] = clean
        }
        persistStringMap(titleOverrides, key: titlesKey)
    }

    func resetLocalTitle(_ session: HermesSession) {
        titleOverrides.removeValue(forKey: session.id)
        persistStringMap(titleOverrides, key: titlesKey)
    }

    private func persistStringSet(_ set: Set<String>, key: String) {
        UserDefaults.standard.set(set.sorted().joined(separator: ","), forKey: key)
        objectWillChange.send()
    }

    private func persistStringMap(_ map: [String: String], key: String) {
        if let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key)
        }
        objectWillChange.send()
    }

    private static func loadStringSet(key: String) -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private static func loadStringMap(key: String) -> [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: key), let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
