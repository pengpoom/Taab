import Foundation

struct GlideSidebarPinnedApp: Codable, Equatable {
    let bundleIdentifier: String
    let displayName: String
    let bundlePath: String?
}

enum GlideSidebarPinnedReorder {
    /// Converts a drop slot in the original list (`0...itemCount`) into the item's final index.
    /// The source item still occupies a row while AppKit reports the insertion slot, so slots
    /// after it shift left once the source is removed.
    static func finalIndex(itemCount: Int, sourceIndex: Int, insertionIndex: Int) -> Int? {
        guard itemCount > 0,
              (0..<itemCount).contains(sourceIndex),
              (0...itemCount).contains(insertionIndex) else { return nil }
        let finalIndex = insertionIndex > sourceIndex ? insertionIndex - 1 : insertionIndex
        guard (0..<itemCount).contains(finalIndex) else { return nil }
        return finalIndex
    }
}

final class GlideSidebarPinnedAppsStore {
    static let preferenceKey = "taab.sidebar.pinned-apps"

    private let defaults: UserDefaults
    private let didSave: () -> Void

    init(defaults: UserDefaults = .standard, didSave: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.didSave = didSave
    }

    func applications() -> [GlideSidebarPinnedApp] {
        guard let json = defaults.string(forKey: Self.preferenceKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([GlideSidebarPinnedApp].self, from: data) else {
            return []
        }

        var seenBundleIdentifiers = Set<String>()
        return decoded.compactMap { app in
            let bundleIdentifier = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleIdentifier.isEmpty,
                  seenBundleIdentifiers.insert(bundleIdentifier).inserted else { return nil }
            let displayName = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return GlideSidebarPinnedApp(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName.isEmpty ? bundleIdentifier : displayName,
                bundlePath: normalizedPath(app.bundlePath))
        }
    }

    func isPinned(_ bundleIdentifier: String) -> Bool {
        applications().contains { $0.bundleIdentifier == bundleIdentifier }
    }

    @discardableResult
    func pin(bundleIdentifier: String, displayName: String, bundlePath: String?) -> Bool {
        let normalizedIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty else { return false }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = GlideSidebarPinnedApp(
            bundleIdentifier: normalizedIdentifier,
            displayName: normalizedName.isEmpty ? normalizedIdentifier : normalizedName,
            bundlePath: normalizedPath(bundlePath))

        var current = applications()
        if let index = current.firstIndex(where: { $0.bundleIdentifier == normalizedIdentifier }) {
            guard current[index] != app else { return false }
            current[index] = app
        } else {
            current.append(app)
        }
        save(current)
        return true
    }

    @discardableResult
    func unpin(bundleIdentifier: String) -> Bool {
        var current = applications()
        let oldCount = current.count
        current.removeAll { $0.bundleIdentifier == bundleIdentifier }
        guard current.count != oldCount else { return false }
        save(current)
        return true
    }

    @discardableResult
    func move(bundleIdentifier: String, to finalIndex: Int) -> Bool {
        let normalizedIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = applications()
        guard !normalizedIdentifier.isEmpty,
              current.indices.contains(finalIndex),
              let sourceIndex = current.firstIndex(where: {
                  $0.bundleIdentifier == normalizedIdentifier
              }),
              sourceIndex != finalIndex else { return false }
        let application = current.remove(at: sourceIndex)
        current.insert(application, at: finalIndex)
        save(current)
        return true
    }

    private func save(_ applications: [GlideSidebarPinnedApp]) {
        guard let data = try? JSONEncoder().encode(applications),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.preferenceKey)
        didSave()
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return path
    }
}
