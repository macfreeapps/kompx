import Foundation

enum RecoveryStore {
    private static let pendingPathsKey = "pendingCompressionRecoveryPaths"
    private static let lock = NSLock()

    static func savePending(_ urls: [URL]) {
        var seen = Set<String>()
        let paths = urls
            .map(\.path)
            .filter { seen.insert($0).inserted }
        // Recovery state is small, but it is still persistent I/O. Do not rewrite
        // the preferences plist when the queue has not changed.
        lock.withLock {
            let storedPaths = UserDefaults.standard.array(forKey: pendingPathsKey) as? [String]
            guard storedPaths != paths else { return }
            if paths.isEmpty {
                UserDefaults.standard.removeObject(forKey: pendingPathsKey)
            } else {
                UserDefaults.standard.set(paths, forKey: pendingPathsKey)
            }
        }
    }

    static func loadPendingURLs() -> [URL] {
        lock.withLock {
            guard let paths = UserDefaults.standard.array(forKey: pendingPathsKey) as? [String] else {
                return []
            }
            return paths.map { URL(fileURLWithPath: $0, isDirectory: false) }
        }
    }

    static func clear() {
        lock.withLock {
            guard UserDefaults.standard.object(forKey: pendingPathsKey) != nil else { return }
            UserDefaults.standard.removeObject(forKey: pendingPathsKey)
        }
    }
}
