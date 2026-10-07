import Foundation
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum ImageOutputFormatChoice: String, CaseIterable, Identifiable {
    case heic = "HEIC (smaller)"
    case automatic = "Keep original format"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .heic:
            return "Convert JPG/JPEG to HEIC for a smaller, high-quality image."
        case .automatic:
            return "Keep JPG/JPEG as JPG and use the existing format rules for other images."
        }
    }
}

enum ImageCompressionQuality: String, CaseIterable, Identifiable {
    case high = "High (90% Quality)"
    case balanced = "Balanced (70% Quality)"
    case aggressive = "Aggressive (40% Quality)"

    var id: String { rawValue }

    var maxResolution: CGFloat {
        switch self {
        case .high: return 3840
        case .balanced: return 1920
        case .aggressive: return 1280
        }
    }

    var shortName: String {
        switch self {
        case .high: return "High"
        case .balanced: return "Balanced"
        case .aggressive: return "Smallest"
        }
    }

    var detail: String {
        switch self {
        case .high: return "Up to 4K · 90% quality"
        case .balanced: return "Up to 1080p · recommended"
        case .aggressive: return "Up to 720p · 40% quality"
        }
    }
}

final class ImageCompressor: ObservableObject, @unchecked Sendable {
    @Published var isCompressing = false
    @Published var isPaused = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var queueTotal = 0
    @Published var queueCompleted = 0

    private var cancelled = false
    private let cancellationLock = NSLock()
    private let pauseController = CompressionPauseController()
    private var batchStartTime: Date?
    private var compressionTask: Task<Void, Never>?

    private var reservedURLs: Set<URL> = []
    private let reservedURLsLock = NSLock()
    private static let writableTypeIdentifiers = Set(
        (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    )

    private struct ImageOutputFormat: Sendable {
        let typeIdentifier: String
        let fileExtension: String
    }

    private struct StagedFile: Sendable {
        let originalURL: URL
        let tempURL: URL
        let finalURL: URL
        let moveOriginalToTrash: Bool
        let originalByteCount: Int64
        let outputByteCount: Int64
        let sourceModificationDate: Date?
    }

    private struct WorkResult: Sendable {
        let result: CompressionItemResult
        let stagedFile: StagedFile?
    }

    func compressImages(
        inputURLs: [URL],
        quality: ImageCompressionQuality,
        outputDirectory: URL? = nil,
        addCompressedSuffix: Bool = false,
        outputFormatPreference: ImageOutputFormatChoice = .automatic,
        itemStarted: ((URL) -> Void)? = nil,
        completion: (([CompressionItemResult]) -> Void)? = nil
    ) {
        guard !inputURLs.isEmpty, !isCompressing else { return }

        cancellationLock.withLock { cancelled = false }
        pauseController.reset()
        DispatchQueue.main.async {
            self.isCompressing = true
            self.isPaused = false
            self.progress = 0
            self.statusMessage = "Preparing your images…"
            self.queueTotal = inputURLs.count
            self.queueCompleted = 0
            self.batchStartTime = Date()
        }

        compressionTask = Task {
            defer {
                self.reservedURLsLock.withLock { self.reservedURLs.removeAll() }
            }

            let fileManager = FileManager.default
            let batchDirectory = self.stagingDirectory(
                for: inputURLs,
                outputDirectory: outputDirectory,
                fileManager: fileManager
            )

            do {
                try fileManager.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            } catch {
                await self.finishWithError("Could not prepare a safe temporary folder: " + error.localizedDescription, completion: completion)
                return
            }

            var results: [CompressionItemResult] = []
            var stagedFiles: [StagedFile] = []
            var lastQueueProgressPublication = 0.0

            await withTaskGroup(of: WorkResult.self) { group in
                var iterator = inputURLs.enumerated().makeIterator()
                let maxConcurrentTasks = MediaMemoryBudget.imageWorkerLimit

                func enqueueNext() {
                    guard !self.isCancellationRequested(), let (index, inputURL) = iterator.next() else { return }
                    DispatchQueue.main.async { itemStarted?(inputURL) }

                    group.addTask {
                        let originalByteCount = self.fileSize(of: inputURL, fileManager: fileManager) ?? 0
                        var tempURL: URL?
                        do {
                            guard originalByteCount > 0 else {
                                throw ImageCompressionError.invalidSource("The image size could not be read.")
                            }
                            try self.validateSource(inputURL, fileManager: fileManager)
                            let outputFormat = try self.outputFormat(
                                for: inputURL,
                                preference: outputFormatPreference
                            )
                            let directory = outputDirectory ?? inputURL.deletingLastPathComponent()
                            try self.validateOutputDirectory(directory, fileManager: fileManager)

                            let moveOriginalToTrash = outputDirectory == nil && !addCompressedSuffix
                            let finalURL = self.reserveOutputURL(
                                for: inputURL,
                                in: directory,
                                fileManager: fileManager,
                                addCompressedSuffix: addCompressedSuffix,
                                outputExtension: outputFormat.fileExtension,
                                moveOriginalToTrash: moveOriginalToTrash
                            )
                            let stagedTempURL = batchDirectory
                                .appendingPathComponent("image-" + String(index) + "-" + UUID().uuidString)
                                .appendingPathExtension(outputFormat.fileExtension)
                            tempURL = stagedTempURL
                            let sourceAttributes = try fileManager.attributesOfItem(atPath: inputURL.path)
                            let sourceModificationDate = sourceAttributes[.modificationDate] as? Date
                            let estimatedMemory = self.estimatedWorkingSetBytes(
                                for: inputURL,
                                quality: quality
                            )
                            guard await MediaMemoryGate.shared.acquire(
                                estimatedBytes: estimatedMemory,
                                cancellationCheck: { self.isCancellationRequested() },
                                onWait: {
                                    DispatchQueue.main.async {
                                        self.statusMessage = "Waiting for safe memory before \(inputURL.lastPathComponent)…"
                                    }
                                }
                            ) else {
                                if self.isCancellationRequested() || Task.isCancelled {
                                    throw CancellationError()
                                }
                                throw ImageCompressionError.resource(
                                    "Not enough available memory to process this image safely. Free memory and retry."
                                )
                            }
                            defer { MediaMemoryGate.shared.release(estimatedBytes: estimatedMemory) }

                            guard self.pauseController.waitIfPaused(cancellationCheck: { self.isCancellationRequested() }) else {
                                throw CancellationError()
                            }

                            try await self.runCompression(
                                inputURL: inputURL,
                                outputURL: stagedTempURL,
                                outputTypeIdentifier: outputFormat.typeIdentifier,
                                quality: quality
                            )
                            try self.validateOutput(stagedTempURL, fileManager: fileManager)

                            let outputByteCount = try self.fileSizeOrThrow(of: stagedTempURL, fileManager: fileManager)
                            guard originalByteCount > 0, outputByteCount < originalByteCount else {
                                try? fileManager.removeItem(at: stagedTempURL)
                                return WorkResult(
                                    result: CompressionItemResult(
                                        inputURL: inputURL,
                                        originalByteCount: originalByteCount,
                                        outputByteCount: outputByteCount,
                                        outcome: .unchanged,
                                        message: self.unchangedMessage(for: inputURL, outputFormat: outputFormat)
                                    ),
                                    stagedFile: nil
                                )
                            }

                            let stagedFile = StagedFile(
                                originalURL: inputURL,
                                tempURL: stagedTempURL,
                                finalURL: finalURL,
                                moveOriginalToTrash: moveOriginalToTrash,
                                originalByteCount: originalByteCount,
                                outputByteCount: outputByteCount,
                                sourceModificationDate: sourceModificationDate
                            )
                            return WorkResult(
                                result: CompressionItemResult(
                                    inputURL: inputURL,
                                    outputURL: finalURL,
                                    originalByteCount: originalByteCount,
                                    outputByteCount: outputByteCount,
                                    outcome: .compressed,
                                    didReplaceOriginal: finalURL.standardizedFileURL == inputURL.standardizedFileURL,
                                    didMoveOriginalToTrash: moveOriginalToTrash
                                ),
                                stagedFile: stagedFile
                            )
                        } catch {
                            if let tempURL { try? fileManager.removeItem(at: tempURL) }
                            return WorkResult(
                                result: CompressionItemResult(
                                    inputURL: inputURL,
                                    originalByteCount: originalByteCount,
                                    outcome: .failed,
                                    message: error.localizedDescription
                                ),
                                stagedFile: nil
                            )
                        }
                    }
                }

                for _ in 0..<min(maxConcurrentTasks, inputURLs.count) { enqueueNext() }
                for await workResult in group {
                    results.append(workResult.result)
                    if let stagedFile = workResult.stagedFile { stagedFiles.append(stagedFile) }

                    let completedCount = results.count
                    let now = ProcessInfo.processInfo.systemUptime
                    let shouldPublish = completedCount == inputURLs.count
                        || lastQueueProgressPublication == 0
                        || now - lastQueueProgressPublication >= 0.2
                    if shouldPublish {
                        lastQueueProgressPublication = now
                        DispatchQueue.main.async {
                            self.queueCompleted = completedCount
                            self.progress = Double(completedCount) / Double(max(1, self.queueTotal))
                            self.statusMessage = "Processed \(completedCount) of \(self.queueTotal) images…"
                        }
                    }
                    enqueueNext()
                }
            }

            if self.isCancellationRequested() {
                try? fileManager.removeItem(at: batchDirectory)
                await self.finishCancellation(completion: completion)
                return
            }

            do {
                try self.verifyStagingDirectory(
                    batchDirectory: batchDirectory,
                    stagedFiles: stagedFiles,
                    fileManager: fileManager
                )
                guard !stagedFiles.isEmpty else {
                    try? fileManager.removeItem(at: batchDirectory)
                    await self.finish(results: results, status: self.noSavingsMessage(for: results), completion: completion)
                    return
                }

                guard !self.isCancellationRequested() else {
                    try? fileManager.removeItem(at: batchDirectory)
                    await self.finishCancellation(completion: completion)
                    return
                }
                DispatchQueue.main.async { self.statusMessage = "Saving verified image results…" }
                try self.commitBatch(stagedFiles, fileManager: fileManager)
                try? fileManager.removeItem(at: batchDirectory)
                await self.finish(results: results, status: self.completionMessage(for: results), completion: completion)
            } catch {
                try? fileManager.removeItem(at: batchDirectory)
                let committedInputURLs = (error as? ImageCommitError)?.committedInputURLs ?? []
                let failedResults = results.map { result in
                    guard result.outcome == .compressed else { return result }
                    guard !committedInputURLs.contains(result.id) else { return result }
                    return CompressionItemResult(
                        inputURL: result.id,
                        originalByteCount: result.originalByteCount,
                        outcome: .failed,
                        message: "The verified copy could not be saved: " + error.localizedDescription
                    )
                }
                let status = committedInputURLs.isEmpty
                    ? "Could not save the verified image copies: \(error.localizedDescription) Originals were kept."
                    : "Some verified image results were saved before the remaining items failed: \(error.localizedDescription)"
                await self.finish(
                    results: failedResults,
                    status: status,
                    completion: completion
                )
            }
        }
    }

    func cancelCompression() {
        cancellationLock.withLock { cancelled = true }
        pauseController.resume()
        compressionTask?.cancel()
        DispatchQueue.main.async { self.statusMessage = "Stopping safely… Originals are not being changed." }
    }

    func pauseCompression() {
        guard isCompressing else { return }
        pauseController.pause()
        DispatchQueue.main.async {
            self.isPaused = true
            self.statusMessage = "Paused safely… Originals are not being changed."
        }
    }

    func resumeCompression() {
        pauseController.resume()
        DispatchQueue.main.async {
            self.isPaused = false
            if self.isCompressing { self.statusMessage = "Resuming safely…" }
        }
    }

    private func isCancellationRequested() -> Bool {
        cancellationLock.withLock { cancelled }
    }

    private func finish(
        results: [CompressionItemResult],
        status: String,
        completion: (([CompressionItemResult]) -> Void)?
    ) async {
        let orderedResults = results.sorted { $0.id.path < $1.id.path }
        DispatchQueue.main.async {
            self.isCompressing = false
            self.isPaused = false
            self.queueCompleted = self.queueTotal
            self.progress = 1
            self.statusMessage = status
            completion?(orderedResults)
        }
    }

    private func finishWithError(_ message: String, completion: (([CompressionItemResult]) -> Void)?) async {
        DispatchQueue.main.async {
            self.isCompressing = false
            self.isPaused = false
            self.queueCompleted = self.queueTotal
            self.statusMessage = "Error: \(message) Originals were kept."
            completion?([])
        }
    }

    private func finishCancellation(completion: (([CompressionItemResult]) -> Void)?) async {
        DispatchQueue.main.async {
            self.isCompressing = false
            self.isPaused = false
            self.queueCompleted = min(self.queueCompleted, self.queueTotal)
            self.progress = 0
            self.statusMessage = "Cancelled safely. Original images were kept."
            completion?([])
        }
    }

    private func validateSource(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ImageCompressionError.invalidSource("The source file is missing or is a folder.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageCompressionError.invalidSource("The image could not be read.")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ImageCompressionError.unsupported("Multi-page images are not changed because preserving every page is required.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else {
            throw ImageCompressionError.invalidSource("The image has no readable dimensions.")
        }
    }

    private func outputFormat(
        for url: URL,
        preference: ImageOutputFormatChoice
    ) throws -> ImageOutputFormat {
        let fileExtension = url.pathExtension.lowercased()
        if preference == .heic {
            guard Self.writableTypeIdentifiers.contains(UTType.heic.identifier) else {
                throw ImageCompressionError.unsupported("HEIC output is not available on this Mac.")
            }
            return ImageOutputFormat(typeIdentifier: UTType.heic.identifier, fileExtension: "heic")
        }

        switch fileExtension {
        case "png", "tif", "tiff":
            if Self.writableTypeIdentifiers.contains(UTType.heic.identifier) {
                return ImageOutputFormat(typeIdentifier: UTType.heic.identifier, fileExtension: "heic")
            }
            if Self.writableTypeIdentifiers.contains(UTType.jpeg.identifier) {
                return ImageOutputFormat(typeIdentifier: UTType.jpeg.identifier, fileExtension: "jpg")
            }
            throw ImageCompressionError.unsupported("PNG/TIFF conversion requires a writable HEIC or JPEG encoder.")
        default:
            guard !fileExtension.isEmpty,
                  let type = UTType(filenameExtension: fileExtension),
                  Self.writableTypeIdentifiers.contains(type.identifier) else {
                throw ImageCompressionError.unsupported("This image format cannot be written safely.")
            }
            return ImageOutputFormat(typeIdentifier: type.identifier, fileExtension: fileExtension)
        }
    }

    private func validateOutputDirectory(_ directory: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImageCompressionError.output("The output folder is no longer available.")
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw ImageCompressionError.output("The output folder is not writable.")
        }
    }

    private func stagingDirectory(
        for inputURLs: [URL],
        outputDirectory: URL?,
        fileManager: FileManager
    ) -> URL {
        // Stage on the destination volume. A temp file on the boot volume followed
        // by a cross-volume copy doubles the encoded output's write traffic.
        let parentDirectory: URL
        if let outputDirectory {
            parentDirectory = outputDirectory
        } else {
            let sourceDirectories = Set(inputURLs.map {
                $0.deletingLastPathComponent().standardizedFileURL.path
            })
            parentDirectory = sourceDirectories.count == 1
                ? inputURLs[0].deletingLastPathComponent()
                : fileManager.temporaryDirectory.appendingPathComponent("komPX", isDirectory: true)
        }
        var parentIsDirectory: ObjCBool = false
        let destinationIsUsable = fileManager.fileExists(
            atPath: parentDirectory.path,
            isDirectory: &parentIsDirectory
        ) && parentIsDirectory.boolValue
            && fileManager.isWritableFile(atPath: parentDirectory.path)
        let stagingParent = destinationIsUsable
            ? parentDirectory
            : fileManager.temporaryDirectory.appendingPathComponent("komPX", isDirectory: true)
        return stagingParent.appendingPathComponent(
            ".komPX-staging-" + UUID().uuidString,
            isDirectory: true
        )
    }

    private func reserveOutputURL(
        for inputURL: URL,
        in directory: URL,
        fileManager: FileManager,
        addCompressedSuffix: Bool,
        outputExtension: String,
        moveOriginalToTrash: Bool
    ) -> URL {
        if moveOriginalToTrash,
           inputURL.pathExtension.caseInsensitiveCompare(outputExtension) == .orderedSame {
            return inputURL
        }

        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let rootName = addCompressedSuffix ? baseName + "_compressed" : baseName
        return reservedURLsLock.withLock {
            var index = 0
            while true {
                let suffix = index == 0 ? "" : "_" + String(index)
                let candidate = directory.appendingPathComponent(rootName + suffix + "." + outputExtension)
                if !reservedURLs.contains(candidate) && !fileManager.fileExists(atPath: candidate.path) {
                    reservedURLs.insert(candidate)
                    return candidate
                }
                index += 1
            }
        }
    }

    private func verifyStagingDirectory(
        batchDirectory: URL,
        stagedFiles: [StagedFile],
        fileManager: FileManager
    ) throws {
        let files = try fileManager.contentsOfDirectory(
            at: batchDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard files.count == stagedFiles.count else {
            throw ImageCompressionError.staging("Temporary file count mismatch; no output was saved.")
        }
        for stagedFile in stagedFiles {
            guard fileManager.fileExists(atPath: stagedFile.tempURL.path) else {
                throw ImageCompressionError.staging("A verified image copy is missing.")
            }
            try validateOutput(stagedFile.tempURL, fileManager: fileManager)
            let currentSize = try fileSizeOrThrow(of: stagedFile.tempURL, fileManager: fileManager)
            guard currentSize == stagedFile.outputByteCount, currentSize < stagedFile.originalByteCount else {
                throw ImageCompressionError.staging("A verified image copy changed before saving.")
            }
        }
    }

    private func commitBatch(_ stagedFiles: [StagedFile], fileManager: FileManager) throws {
        var committedURLs: Set<URL> = []
        do {
            for stagedFile in stagedFiles {
                guard fileManager.fileExists(atPath: stagedFile.originalURL.path) else {
                    throw ImageCompressionError.sourceChanged("The source disappeared before its copy could be saved.")
                }
                let currentAttributes = try fileManager.attributesOfItem(atPath: stagedFile.originalURL.path)
                let currentSize = (currentAttributes[.size] as? NSNumber)?.int64Value
                let currentModificationDate = currentAttributes[.modificationDate] as? Date
                guard currentSize == stagedFile.originalByteCount,
                      currentModificationDate == stagedFile.sourceModificationDate else {
                    throw ImageCompressionError.sourceChanged("The source changed while it was being compressed.")
                }

                if stagedFile.moveOriginalToTrash {
                    try commitByMovingOriginalToTrash(stagedFile, fileManager: fileManager)
                    committedURLs.insert(stagedFile.originalURL)
                } else {
                    guard !fileManager.fileExists(atPath: stagedFile.finalURL.path) else {
                        throw ImageCompressionError.output("An output filename became occupied; try again.")
                    }
                    try moveItemSafely(from: stagedFile.tempURL, to: stagedFile.finalURL, fileManager: fileManager)
                    committedURLs.insert(stagedFile.originalURL)
                }
            }
        } catch {
            // A replacement is already a valid, verified result. Never remove committed
            // originals or copies while reporting a later item failure.
            throw ImageCommitError(underlying: error, committedInputURLs: committedURLs)
        }
    }

    private func commitByMovingOriginalToTrash(_ stagedFile: StagedFile, fileManager: FileManager) throws {
        if stagedFile.finalURL != stagedFile.originalURL,
           fileManager.fileExists(atPath: stagedFile.finalURL.path) {
            throw ImageCompressionError.output("An output filename became occupied; try again.")
        }

        let recoveryURL = stagedFile.tempURL
            .deletingLastPathComponent()
            .appendingPathComponent("recovery-" + UUID().uuidString)
            .appendingPathExtension(stagedFile.originalURL.pathExtension)
        try backupOriginalForRollback(
            from: stagedFile.originalURL,
            to: recoveryURL,
            fileManager: fileManager
        )
        guard fileSize(of: recoveryURL, fileManager: fileManager) == stagedFile.originalByteCount else {
            try? fileManager.removeItem(at: recoveryURL)
            throw ImageCompressionError.output("The original could not be backed up safely before moving it to Trash.")
        }

        var trashedURL: NSURL?
        do {
            try fileManager.trashItem(at: stagedFile.originalURL, resultingItemURL: &trashedURL)
        } catch {
            try? fileManager.removeItem(at: recoveryURL)
            throw ImageCompressionError.output("The original could not be moved to Trash: \(error.localizedDescription)")
        }

        do {
            try moveItemSafely(from: stagedFile.tempURL, to: stagedFile.finalURL, fileManager: fileManager)
            applyOriginalFileAttributes(from: recoveryURL, to: stagedFile.finalURL, fileManager: fileManager)
            try? fileManager.removeItem(at: recoveryURL)
        } catch {
            do {
                guard !fileManager.fileExists(atPath: stagedFile.originalURL.path) else {
                    throw ImageCompressionError.output("The destination changed while saving; the original remains in Trash.")
                }
                if let trashedURL, let trashedPath = trashedURL.path,
                   fileManager.fileExists(atPath: trashedPath) {
                    try moveItemSafely(from: trashedURL as URL, to: stagedFile.originalURL, fileManager: fileManager)
                } else {
                    try moveItemSafely(from: recoveryURL, to: stagedFile.originalURL, fileManager: fileManager)
                }
            } catch {
                throw ImageCompressionError.output("The compressed file could not be placed, and the original could not be restored: \(error.localizedDescription)")
            }
            try? fileManager.removeItem(at: recoveryURL)
            throw error
        }
    }

    private func backupOriginalForRollback(
        from sourceURL: URL,
        to recoveryURL: URL,
        fileManager: FileManager
    ) throws {
        let cloneResult = sourceURL.path.withCString { sourcePath in
            recoveryURL.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE))
            }
        }
        if cloneResult != 0 {
            try? fileManager.removeItem(at: recoveryURL)
            try fileManager.copyItem(at: sourceURL, to: recoveryURL)
        }
    }

    private func applyOriginalFileAttributes(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path) else { return }
        var preserved: [FileAttributeKey: Any] = [:]
        let keys: [FileAttributeKey] = [.creationDate, .posixPermissions, .ownerAccountID, .groupOwnerAccountID]
        for key in keys {
            if let value = attributes[key] { preserved[key] = value }
        }
        preserved[.modificationDate] = Date()
        try? fileManager.setAttributes(preserved, ofItemAtPath: destinationURL.path)
    }

    private func moveItemSafely(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch let error as NSError {
            // A copy is needed only across volumes. Do not silently turn an ordinary
            // move failure into another full-file write.
            guard isCrossVolumeMoveError(error) else {
                throw error
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try? fileManager.removeItem(at: sourceURL)
        }
    }

    private func isCrossVolumeMoveError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isCrossVolumeMoveError(underlying)
    }

    private func fileSize(of url: URL, fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber else { return nil }
        return value.int64Value
    }

    private func fileSizeOrThrow(of url: URL, fileManager: FileManager) throws -> Int64 {
        guard let fileSize = fileSize(of: url, fileManager: fileManager), fileSize > 0 else {
            throw ImageCompressionError.invalidOutput("The generated image is empty.")
        }
        return fileSize
    }

    private func validateOutput(_ url: URL, fileManager: FileManager) throws {
        _ = try fileSizeOrThrow(of: url, fileManager: fileManager)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else {
            throw ImageCompressionError.invalidOutput("The generated image could not be decoded.")
        }
    }

    private func estimatedWorkingSetBytes(
        for url: URL,
        quality: ImageCompressionQuality
    ) -> UInt64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return MediaMemoryBudget.minimumReservationBytes
        }
        return MediaMemoryBudget.estimatedImageWorkingSetBytes(
            width: width.intValue,
            height: height.intValue,
            maxResolution: Double(quality.maxResolution)
        )
    }

    private func runCompression(
        inputURL: URL,
        outputURL: URL,
        outputTypeIdentifier: String,
        quality: ImageCompressionQuality
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  CGImageSourceGetCount(imageSource) == 1,
                  let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = sourceProperties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = sourceProperties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0 else {
                throw ImageCompressionError.invalidSource("The image could not be decoded.")
            }

            let longestSide = max(CGFloat(width.intValue), CGFloat(height.intValue))
            let targetLongestSide = min(longestSide, quality.maxResolution)
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(2, Int(targetLongestSide.rounded(.down)))
            ]
            guard let resizedImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                throw ImageCompressionError.invalidOutput("The image could not be resized safely.")
            }

            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                outputTypeIdentifier as CFString,
                1,
                nil
            ) else {
                throw ImageCompressionError.output("The image format could not be written.")
            }

            let compressionQuality: CGFloat
            switch quality {
            case .high: compressionQuality = 0.9
            case .balanced: compressionQuality = 0.7
            case .aggressive: compressionQuality = 0.4
            }
            var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
            properties.removeValue(forKey: kCGImagePropertyPixelWidth)
            properties.removeValue(forKey: kCGImagePropertyPixelHeight)
            properties.removeValue(forKey: kCGImagePropertyOrientation)
            properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality

            CGImageDestinationAddImage(destination, resizedImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ImageCompressionError.output("The image encoder did not finish successfully.")
            }
        }.value
    }

    private func completionMessage(for results: [CompressionItemResult]) -> String {
        let compressed = results.filter { $0.outcome == .compressed }
        let replaced = compressed.filter(\.didReplaceOriginal).count
        let copies = compressed.count - replaced
        let trashed = compressed.filter(\.didMoveOriginalToTrash).count
        let unchanged = results.filter { $0.outcome == .unchanged }.count
        let failed = results.filter { $0.outcome == .failed }.count

        if compressed.isEmpty {
            if unchanged > 0 && failed == 0 {
                return "No smaller image copies were needed. Kept \(pluralized(unchanged, singular: "original"))."
            }
            if unchanged == 0 && failed > 0 {
                return "No image copies were saved. \(pluralized(failed, singular: "item")) failed; originals were kept."
            }
        }

        let savedBytes = compressed.compactMap(\.savedByteCount).reduce(0, +)
        let savedText = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
        var actions: [String] = []
        if replaced > 0 {
            actions.append("Replaced \(pluralized(replaced, singular: "original"))")
        }
        if copies > 0 {
            actions.append("Saved \(pluralized(copies, singular: "verified image copy", plural: "verified image copies"))")
        }
        var message = actions.joined(separator: " · ") + " · \(savedText) smaller"
        if unchanged > 0 {
            message += " · Kept \(pluralized(unchanged, singular: "original"))"
        }
        if failed > 0 { message += " · \(pluralized(failed, singular: "item")) failed; originals were kept" }
        if trashed > 0 { message += " · \(pluralized(trashed, singular: "original")) moved to Trash" }
        return message + "."
    }

    private func noSavingsMessage(for results: [CompressionItemResult]) -> String {
        let failed = results.filter { $0.outcome == .failed }.count
        if failed > 0 {
            return "No image copies were saved. \(pluralized(failed, singular: "item")) could not be verified; originals were kept."
        }
        return "No smaller image copies were created. Originals were kept."
    }

    private func unchangedMessage(for inputURL: URL, outputFormat: ImageOutputFormat) -> String {
        if outputFormat.fileExtension.lowercased() == "heic" {
            return "The HEIC result was not smaller, so the original was kept."
        }
        switch inputURL.pathExtension.lowercased() {
        case "png", "tif", "tiff":
            return "The high-quality \(outputFormat.fileExtension.uppercased()) result was not smaller, so the original was kept."
        default:
            return "The compressed result was the same size or larger, so the original was kept."
        }
    }

    private func pluralized(_ count: Int, singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }
}

private struct ImageCommitError: LocalizedError {
    let underlying: Error
    let committedInputURLs: Set<URL>

    var errorDescription: String? { underlying.localizedDescription }
}

private enum ImageCompressionError: LocalizedError {
    case invalidSource(String)
    case invalidOutput(String)
    case output(String)
    case staging(String)
    case sourceChanged(String)
    case unsupported(String)
    case resource(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let message), .invalidOutput(let message), .output(let message),
             .staging(let message), .sourceChanged(let message), .unsupported(let message), .resource(let message):
            return message
        }
    }
}
