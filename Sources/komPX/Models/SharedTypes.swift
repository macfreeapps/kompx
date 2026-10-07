import Foundation
import UniformTypeIdentifiers
import Darwin

enum MediaMemoryBudget {
    static let targetUtilization = 0.75
    static let minimumAvailableBytes: UInt64 = 256 * 1024 * 1024
    static let minimumReservationBytes: UInt64 = 64 * 1024 * 1024
    static let maximumWaitTime: TimeInterval = 30

    static var imageWorkerLimit: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    static var videoWorkerLimit: Int {
        // Two hardware pipelines are enough to improve throughput without letting
        // VideoToolbox create an unbounded number of decoder/encoder surfaces.
        min(2, max(1, ProcessInfo.processInfo.activeProcessorCount / 4))
    }

    static func availableBytes() -> UInt64 {
        let processRemaining = processLimitBytesRemaining()
        let systemAvailable = systemAvailableBytes()

        if let processRemaining, let systemAvailable {
            return min(processRemaining, systemAvailable)
        }
        if let processRemaining { return processRemaining }
        if let systemAvailable { return systemAvailable }
        return ProcessInfo.processInfo.physicalMemory / 2
    }

    static func estimatedImageWorkingSetBytes(
        width: Int,
        height: Int,
        maxResolution: Double
    ) -> UInt64 {
        let sourceWidth = Double(max(1, width))
        let sourceHeight = Double(max(1, height))
        let longestSide = max(sourceWidth, sourceHeight)
        let scale = min(1, maxResolution / longestSide)
        let outputWidth = max(1, sourceWidth * scale)
        let outputHeight = max(1, sourceHeight * scale)

        // ImageIO may hold a decoded source, a resized image, and encoder buffers
        // briefly at the same time. Keep enough headroom for all three.
        let sourceBytes = sourceWidth * sourceHeight * 4
        let outputBytes = outputWidth * outputHeight * 4
        let estimate = sourceBytes * 2 + outputBytes * 2 + Double(minimumReservationBytes)
        return UInt64(min(estimate, Double(UInt64.max)))
    }

    static func estimatedVideoWorkingSetBytes(
        width: Double,
        height: Double,
        maxResolution: Double
    ) -> UInt64 {
        let sourceWidth = max(1, width)
        let sourceHeight = max(1, height)
        let longestSide = max(sourceWidth, sourceHeight)
        let scale = min(1, maxResolution / longestSide)
        let outputWidth = max(1, sourceWidth * scale)
        let outputHeight = max(1, sourceHeight * scale)

        // The video pipeline streams frames, but AVFoundation and VideoToolbox
        // keep several pixel buffers and codec surfaces alive during encoding.
        let outputBytes = outputWidth * outputHeight * 4
        let estimate = outputBytes * 8 + Double(128 * 1024 * 1024)
        return UInt64(min(estimate, Double(UInt64.max)))
    }

    private static func processLimitBytesRemaining() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, info.limit_bytes_remaining > 0 else { return nil }
        return info.limit_bytes_remaining
    }

    private static func systemAvailableBytes() -> UInt64? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let availablePages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        return availablePages * UInt64(vm_page_size)
    }
}

final class MediaMemoryGate: @unchecked Sendable {
    static let shared = MediaMemoryGate()

    private let lock = NSLock()
    private var reservedBytes: UInt64 = 0

    func acquire(
        estimatedBytes: UInt64,
        cancellationCheck: @escaping @Sendable () -> Bool,
        onWait: @escaping @Sendable () -> Void
    ) async -> Bool {
        let request = max(estimatedBytes, MediaMemoryBudget.minimumReservationBytes)
        let deadline = Date().addingTimeInterval(MediaMemoryBudget.maximumWaitTime)
        var didNotifyWait = false

        while !Task.isCancelled && !cancellationCheck() && Date() < deadline {
            let acquired = lock.withLock {
                let available = MediaMemoryBudget.availableBytes()
                let targetBytes = UInt64(Double(available) * MediaMemoryBudget.targetUtilization)
                guard available >= MediaMemoryBudget.minimumAvailableBytes,
                      request <= targetBytes,
                      reservedBytes <= targetBytes - request else {
                    return false
                }
                reservedBytes += request
                return true
            }

            if acquired { return true }
            if !didNotifyWait {
                didNotifyWait = true
                onWait()
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func release(estimatedBytes: UInt64) {
        let reservation = max(estimatedBytes, MediaMemoryBudget.minimumReservationBytes)
        lock.withLock {
            reservedBytes = reservedBytes > reservation ? reservedBytes - reservation : 0
        }
    }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case sameAsSource = "Same as Original"
    case custom = "Custom Folder..."
    var id: String { self.rawValue }
}

enum CompressionOutcome: String, Sendable {
    case compressed
    case unchanged
    case failed
}

struct CompressionItemResult: Identifiable, Sendable {
    let id: URL
    let outputURL: URL?
    let originalByteCount: Int64
    let outputByteCount: Int64?
    let outcome: CompressionOutcome
    let didReplaceOriginal: Bool
    let didMoveOriginalToTrash: Bool
    let message: String?

    init(
        inputURL: URL,
        outputURL: URL? = nil,
        originalByteCount: Int64,
        outputByteCount: Int64? = nil,
        outcome: CompressionOutcome,
        didReplaceOriginal: Bool = false,
        didMoveOriginalToTrash: Bool = false,
        message: String? = nil
    ) {
        self.id = inputURL
        self.outputURL = outputURL
        self.originalByteCount = originalByteCount
        self.outputByteCount = outputByteCount
        self.outcome = outcome
        self.didReplaceOriginal = didReplaceOriginal
        self.didMoveOriginalToTrash = didMoveOriginalToTrash
        self.message = message
    }

    var savedByteCount: Int64? {
        guard let outputByteCount, outcome == .compressed else { return nil }
        return max(0, originalByteCount - outputByteCount)
    }

    var reductionPercentage: Int? {
        guard let savedByteCount, originalByteCount > 0 else { return nil }
        return Int((Double(savedByteCount) / Double(originalByteCount) * 100).rounded())
    }
}

enum SupportedMediaFiles {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff"]
    static let mixedExtensions = videoExtensions.union(imageExtensions)
}

enum DroppedFileLoader {
    static func matchingURLsAsync(
        from droppedURLs: [URL],
        allowedExtensions: Set<String>
    ) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            matchingURLs(from: droppedURLs, allowedExtensions: allowedExtensions)
        }.value
    }

    static func matchingURLs(
        from droppedURLs: [URL],
        allowedExtensions: Set<String>
    ) -> [URL] {
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(droppedURLs.count)
        var matchingURLs: [URL] = []

        for droppedURL in droppedURLs {
            for url in expand(droppedURL, allowedExtensions: allowedExtensions) {
                if seenPaths.insert(url.path).inserted {
                    matchingURLs.append(url)
                }
            }
        }
        return matchingURLs
    }

    static func fileSizesAsync(for urls: [URL]) async -> [String: Int64] {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            return urls.reduce(into: [String: Int64]()) { result, url in
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let value = attributes[.size] as? NSNumber else { return }
                result[url.path] = value.int64Value
            }
        }.value
    }

    private static func expand(_ url: URL, allowedExtensions: Set<String>) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }

        if isDirectory.boolValue {
            return ((try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter {
                allowedExtensions.contains($0.pathExtension.lowercased())
            }
        }

        return allowedExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
    }
}
