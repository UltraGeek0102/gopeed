import Foundation

struct SharedProgress: Codable {
    var id: String
    var filename: String
    var progress: Double
    var downloadedBytes: Int64
    var totalBytes: Int64
    var speedBytesPerSec: Int64
    var updatedAt: Date
}

/// Thread-safe App Group store.
/// Runner target WRITES on every poll tick (from background DispatchQueue).
/// GopeedWidgets extension READS in getTimeline() and calls activity.update().
final class SharedProgressStore {
    static let shared = SharedProgressStore()
    private init() {}

    private let appGroup = "group.com.gopeed.gopeed"
    private let key      = "com.gopeed.live_activity_progress"
    private let lock     = NSLock()

    private var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    // MARK: - Write (called synchronously from poll thread)

    func update(id: String, filename: String, progress: Double,
                downloaded: Int64, total: Int64, speed: Int64) {
        lock.lock(); defer { lock.unlock() }
        var items = _read()
        let entry = SharedProgress(id: id, filename: filename, progress: progress,
                                   downloadedBytes: downloaded, totalBytes: total,
                                   speedBytesPerSec: speed, updatedAt: Date())
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = entry
        } else {
            items.append(entry)
        }
        _write(items)
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        var items = _read()
        items.removeAll { $0.id == id }
        _write(items)
    }

    // MARK: - Read (called from widget extension)

    func read() -> [SharedProgress] {
        lock.lock(); defer { lock.unlock() }
        return _read()
    }

    // MARK: - Private

    private func _write(_ items: [SharedProgress]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults?.set(data, forKey: key)
        defaults?.synchronize()
    }

    private func _read() -> [SharedProgress] {
        guard let data  = defaults?.data(forKey: key),
              let items = try? JSONDecoder().decode([SharedProgress].self, from: data)
        else { return [] }
        return items
    }
}
