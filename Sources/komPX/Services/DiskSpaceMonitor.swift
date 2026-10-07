import Foundation
import Combine

struct DiskSpaceIssue: Identifiable, Sendable {
    let id: String
    let locationDescription: String
    let availableBytes: Int64?

    var message: String {
        if let availableBytes {
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .decimal)
            return locationDescription + " has only " + available + " free."
        }
        return "The available space on " + locationDescription + " could not be verified."
    }
}

final class DiskSpaceMonitor: ObservableObject {
    static let minimumSafeFreeBytes: Int64 = 1_073_741_824

    @Published private(set) var availableBytes: Int64?
    @Published private(set) var totalBytes: Int64?

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)
        let total = values?.volumeTotalCapacity.map(Int64.init)

        let update = {
            self.availableBytes = available
            self.totalBytes = total
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    static func writeSpaceIssues(
        for outputDirectory: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [DiskSpaceIssue] {
        let fileManager = FileManager.default
        var seenVolumes = Set<String>()
        var issues: [DiskSpaceIssue] = []

        for location in [outputDirectory, temporaryDirectory] {
            guard fileManager.fileExists(atPath: location.path) else { continue }
            let values = try? location.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
                .volumeNameKey,
                .volumeUUIDStringKey
            ])
            let volumeURL = location.standardizedFileURL
            let volumeID = values?.volumeUUIDString ?? volumeURL.path
            guard seenVolumes.insert(volumeID).inserted else { continue }

            let availableBytes = values?.volumeAvailableCapacityForImportantUsage
                ?? values?.volumeAvailableCapacity.map(Int64.init)
            let volumeName = values?.volumeName ?? volumeURL.lastPathComponent
            guard availableBytes == nil || availableBytes! < minimumSafeFreeBytes else { continue }
            issues.append(
                DiskSpaceIssue(
                    id: volumeID,
                    locationDescription: volumeName.isEmpty ? volumeURL.path : volumeName,
                    availableBytes: availableBytes
                )
            )
        }

        return issues
    }
}
