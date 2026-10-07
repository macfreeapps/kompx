import Foundation
import Combine
@preconcurrency import AVFoundation
import VideoToolbox
import Darwin

enum CompressionQuality: String, CaseIterable, Identifiable {
    case high = "High"
    case balanced = "Balanced"
    case aggressive = "Smallest"

    var id: String { rawValue }

    var targetBitrate: Int {
        switch self {
        case .high: return 6_000_000
        case .balanced: return 2_500_000
        case .aggressive: return 800_000
        }
    }

    var maxResolution: CGFloat {
        switch self {
        case .high: return 3840
        case .balanced: return 1920
        case .aggressive: return 1280
        }
    }

    var detail: String {
        switch self {
        case .high: return "Up to 4K · best detail"
        case .balanced: return "Up to 1080p · recommended"
        case .aggressive: return "Up to 720p · smallest file"
        }
    }
}

final class VideoCompressor: ObservableObject, @unchecked Sendable {
    @Published var isCompressing = false
    @Published var isPaused = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var queueTotal = 0
    @Published var queueCompleted = 0

    private let cancellationLock = NSLock()
    private var cancelled = false
    private let pauseController = CompressionPauseController()
    private var batchStartTime: Date?
    private var compressionTask: Task<Void, Never>?
    private var activeProgressDict: [URL: Double] = [:]

    private var reservedURLs: Set<URL> = []
    private let reservedURLsLock = NSLock()

    private struct InputManifestEntry: Sendable {
        let originalURL: URL
        let filename: String
        let originalDuration: Double
        let hasAudio: Bool
        let estimatedWorkingSetBytes: UInt64
    }

    private struct StagedFile: Sendable {
        let originalURL: URL
        let filename: String
        let tempURL: URL
        let finalURL: URL
        let moveOriginalToTrash: Bool
        let originalDuration: Double
        let expectedDisplaySize: CGSize
        let hasAudio: Bool
        let originalByteCount: Int64
        let outputByteCount: Int64
        let sourceModificationDate: Date?
    }

    private struct CompressionResult: Sendable {
        let inputURL: URL
        let manifestEntry: InputManifestEntry?
        let stagedFile: StagedFile?
        let result: CompressionItemResult
    }

    // AVFoundation delivers these callbacks on the dedicated serial queues below. This
    // wrapper makes that queue ownership explicit at the Swift concurrency boundary.
    private final class PipelineResources: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let videoOutput: AVAssetReaderVideoCompositionOutput
        let audioInput: AVAssetWriterInput?
        let audioOutput: AVAssetReaderTrackOutput?

        init(
            reader: AVAssetReader,
            writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            videoOutput: AVAssetReaderVideoCompositionOutput,
            audioInput: AVAssetWriterInput?,
            audioOutput: AVAssetReaderTrackOutput?
        ) {
            self.reader = reader
            self.writer = writer
            self.videoInput = videoInput
            self.videoOutput = videoOutput
            self.audioInput = audioInput
            self.audioOutput = audioOutput
        }
    }

    private final class PipelineState: @unchecked Sendable {
        private let lock = NSLock()
        private var videoFinished = false
        private var audioFinished = false
        private var failure: Error?

        func finishVideo() -> Bool {
            lock.withLock {
                guard !videoFinished else { return false }
                videoFinished = true
                return true
            }
        }

        func finishAudio() -> Bool {
            lock.withLock {
                guard !audioFinished else { return false }
                audioFinished = true
                return true
            }
        }

        func setFailure(_ error: Error) {
            lock.withLock {
                if failure == nil { failure = error }
            }
        }

        var hasFailure: Bool {
            lock.withLock { failure != nil }
        }

        var firstFailure: Error? {
            lock.withLock { failure }
        }
    }

    private final class ProgressThrottler: @unchecked Sendable {
        private let lock = NSLock()
        private var lastEmissionTime: TimeInterval = 0

        func shouldPublish(_ progress: Double) -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            return lock.withLock {
                guard lastEmissionTime == 0 || now - lastEmissionTime >= 0.2 else {
                    return false
                }
                lastEmissionTime = now
                return true
            }
        }
    }

    func compressVideos(
        inputURLs: [URL],
        quality: CompressionQuality,
        outputDirectory: URL? = nil,
        addCompressedSuffix: Bool = false,
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
            self.statusMessage = "Preparing your videos…"
            self.queueTotal = inputURLs.count
            self.queueCompleted = 0
            self.activeProgressDict.removeAll()
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
            var manifest: [InputManifestEntry] = []

            do {
                try fileManager.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            } catch {
                await self.finishWithError("Could not prepare the temporary folder: " + error.localizedDescription, completion: completion)
                return
            }

            var stagedFiles: [StagedFile] = []
            var results: [CompressionItemResult] = []
            var lastQueueProgressPublication = 0.0
            var completedSinceLastPublication: [URL] = []
            let progressThrottler = ProgressThrottler()

            await withTaskGroup(of: CompressionResult.self) { group in
                var iterator = inputURLs.enumerated().makeIterator()
                let maxConcurrentTasks = MediaMemoryBudget.videoWorkerLimit

                func enqueueNext() {
                    guard !self.isCancellationRequested(), let (index, inputURL) = iterator.next() else { return }

                    DispatchQueue.main.async {
                        itemStarted?(inputURL)
                    }

                    group.addTask {
                        let originalByteCount = self.fileSize(of: inputURL, fileManager: fileManager) ?? 0
                        var tempURL: URL?
                        var manifestEntry: InputManifestEntry?

                        do {
                            guard originalByteCount > 0 else {
                                throw VideoCompressionError.invalidSource("The video size could not be read")
                            }

                            let directory = outputDirectory ?? inputURL.deletingLastPathComponent()
                            try self.validateOutputDirectory(directory, fileManager: fileManager)
                            let entry = try await self.makeManifestEntry(for: inputURL, quality: quality)
                            manifestEntry = entry

                            let moveOriginalToTrash = outputDirectory == nil && !addCompressedSuffix
                            let finalURL = self.reserveOutputURL(
                                for: inputURL,
                                in: directory,
                                fileManager: fileManager,
                                addCompressedSuffix: addCompressedSuffix,
                                moveOriginalToTrash: moveOriginalToTrash
                            )
                            let extensionName = finalURL.pathExtension.isEmpty ? "mp4" : finalURL.pathExtension
                            let stagedTempURL = batchDirectory.appendingPathComponent(
                                "file-" + String(index) + "-" + UUID().uuidString + "." + extensionName
                            )
                            tempURL = stagedTempURL
                            let sourceAttributes = try fileManager.attributesOfItem(atPath: inputURL.path)
                            let sourceModificationDate = sourceAttributes[.modificationDate] as? Date

                            guard await MediaMemoryGate.shared.acquire(
                                estimatedBytes: entry.estimatedWorkingSetBytes,
                                cancellationCheck: { self.isCancellationRequested() },
                                onWait: {
                                    DispatchQueue.main.async {
                                        self.statusMessage = "Waiting for safe memory before \(entry.filename)…"
                                    }
                                }
                            ) else {
                                if self.isCancellationRequested() || Task.isCancelled {
                                    throw CancellationError()
                                }
                                throw VideoCompressionError.resource(
                                    "Not enough available memory to process this video safely. Free memory and retry."
                                )
                            }
                            defer { MediaMemoryGate.shared.release(estimatedBytes: entry.estimatedWorkingSetBytes) }

                            let renderedSize = try await self.runCompression(
                                inputURL: inputURL,
                                outputURL: stagedTempURL,
                                quality: quality,
                                progressUpdate: { progress in
                                    guard progressThrottler.shouldPublish(progress) else { return }
                                    DispatchQueue.main.async {
                                        self.activeProgressDict[inputURL] = progress
                                        self.updateOverallProgress()
                                    }
                                }
                            )
                            try await self.validateOutput(
                                outputURL: stagedTempURL,
                                expectedDuration: entry.originalDuration,
                                expectedDisplaySize: renderedSize,
                                expectedHasAudio: entry.hasAudio
                            )

                            let outputByteCount = try self.fileSizeOrThrow(of: stagedTempURL, fileManager: fileManager)
                            guard outputByteCount < originalByteCount else {
                                try? fileManager.removeItem(at: stagedTempURL)
                                return CompressionResult(
                                    inputURL: inputURL,
                                    manifestEntry: entry,
                                    stagedFile: nil,
                                    result: CompressionItemResult(
                                        inputURL: inputURL,
                                        originalByteCount: originalByteCount,
                                        outputByteCount: outputByteCount,
                                        outcome: .unchanged,
                                        message: "The compressed result was the same size or larger, so the original was kept."
                                    )
                                )
                            }

                            return CompressionResult(
                                inputURL: inputURL,
                                manifestEntry: entry,
                                stagedFile: StagedFile(
                                    originalURL: inputURL,
                                    filename: entry.filename,
                                    tempURL: stagedTempURL,
                                    finalURL: finalURL,
                                    moveOriginalToTrash: moveOriginalToTrash,
                                    originalDuration: entry.originalDuration,
                                    expectedDisplaySize: renderedSize,
                                    hasAudio: entry.hasAudio,
                                    originalByteCount: originalByteCount,
                                    outputByteCount: outputByteCount,
                                    sourceModificationDate: sourceModificationDate
                                ),
                                result: CompressionItemResult(
                                    inputURL: inputURL,
                                    outputURL: finalURL,
                                    originalByteCount: originalByteCount,
                                    outputByteCount: outputByteCount,
                                    outcome: .compressed,
                                    didReplaceOriginal: moveOriginalToTrash,
                                    didMoveOriginalToTrash: moveOriginalToTrash
                                )
                            )
                        } catch {
                            if let tempURL { try? fileManager.removeItem(at: tempURL) }
                            return CompressionResult(
                                inputURL: inputURL,
                                manifestEntry: manifestEntry,
                                stagedFile: nil,
                                result: CompressionItemResult(
                                    inputURL: inputURL,
                                    originalByteCount: originalByteCount,
                                    outcome: .failed,
                                    message: error.localizedDescription
                                )
                            )
                        }
                    }
                }

                for _ in 0..<min(maxConcurrentTasks, inputURLs.count) { enqueueNext() }

                for await result in group {
                    if let manifestEntry = result.manifestEntry {
                        manifest.append(manifestEntry)
                    }
                    if let stagedFile = result.stagedFile {
                        stagedFiles.append(stagedFile)
                    }
                    results.append(result.result)

                    completedSinceLastPublication.append(result.inputURL)
                    let completedCount = results.count
                    let now = ProcessInfo.processInfo.systemUptime
                    let shouldPublish = completedCount == inputURLs.count
                        || lastQueueProgressPublication == 0
                        || now - lastQueueProgressPublication >= 0.2
                    if shouldPublish {
                        lastQueueProgressPublication = now
                        let completedURLs = completedSinceLastPublication
                        completedSinceLastPublication.removeAll(keepingCapacity: true)
                        DispatchQueue.main.async {
                            for url in completedURLs {
                                self.activeProgressDict.removeValue(forKey: url)
                            }
                            self.queueCompleted = completedCount
                            self.updateOverallProgress()
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
                try await verifyStagingDirectory(
                    batchDirectory: batchDirectory,
                    manifest: manifest,
                    stagedFiles: stagedFiles,
                    fileManager: fileManager
                )
                if !stagedFiles.isEmpty {
                    guard !self.isCancellationRequested() else {
                        try? fileManager.removeItem(at: batchDirectory)
                        await self.finishCancellation(completion: completion)
                        return
                    }
                    DispatchQueue.main.async { self.statusMessage = "Saving verified video results…" }
                    try commitBatch(stagedFiles, fileManager: fileManager)
                }
                try? fileManager.removeItem(at: batchDirectory)

                DispatchQueue.main.async {
                    self.isCompressing = false
                    self.isPaused = false
                    self.queueCompleted = self.queueTotal
                    self.progress = 1
                    self.statusMessage = self.completionMessage(for: results)
                    completion?(results.sorted { $0.id.path < $1.id.path })
                }
            } catch {
                try? fileManager.removeItem(at: batchDirectory)
                let committedInputURLs = (error as? VideoCommitError)?.committedInputURLs ?? []
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
                    ? "Could not save the verified video copies: " + error.localizedDescription + " Originals were kept."
                    : "Some verified video results were saved before the remaining items failed: " + error.localizedDescription
                DispatchQueue.main.async {
                    self.isCompressing = false
                    self.isPaused = false
                    self.queueCompleted = self.queueTotal
                    self.statusMessage = status
                    completion?(failedResults.sorted { $0.id.path < $1.id.path })
                }
            }
        }
    }

    private func finishWithError(_ message: String, completion: (([CompressionItemResult]) -> Void)?) async {
        DispatchQueue.main.async {
            self.isCompressing = false
            self.isPaused = false
            self.queueCompleted = self.queueTotal
            self.statusMessage = "Error: " + message + " Originals were kept."
            completion?([])
        }
    }

    private func finishCancellation(completion: (([CompressionItemResult]) -> Void)?) async {
        DispatchQueue.main.async {
            self.isCompressing = false
            self.isPaused = false
            self.activeProgressDict.removeAll()
            self.progress = 0
            self.statusMessage = "Cancelled safely. Original videos were kept."
            completion?([])
        }
    }

    private func makeManifestEntry(
        for url: URL,
        quality: CompressionQuality
    ) async throws -> InputManifestEntry {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw VideoCompressionError.invalidSource(url.lastPathComponent + " is missing or is a folder")
        }
        _ = try outputFileType(for: url.pathExtension)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard tracks.allSatisfy({ $0.mediaType == .video || $0.mediaType == .audio }) else {
            throw VideoCompressionError.invalidSource(url.lastPathComponent + " contains a subtitle or data track that cannot be preserved safely")
        }
        guard tracks.filter({ $0.mediaType == .video }).count == 1,
              tracks.filter({ $0.mediaType == .audio }).count <= 1 else {
            throw VideoCompressionError.invalidSource(url.lastPathComponent + " contains multiple video or audio tracks that cannot all be preserved safely")
        }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw VideoCompressionError.invalidSource(url.lastPathComponent + " has no video track")
        }
        let hasAudio = tracks.contains(where: { $0.mediaType == .audio })
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw VideoCompressionError.invalidSource(url.lastPathComponent + " has no readable duration")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displayWidth = abs(transformedBounds.width)
        let displayHeight = abs(transformedBounds.height)
        guard displayWidth > 1, displayHeight > 1 else {
            throw VideoCompressionError.invalidSource(url.lastPathComponent + " has invalid dimensions")
        }
        return InputManifestEntry(
            originalURL: url,
            filename: url.lastPathComponent,
            originalDuration: duration,
            hasAudio: hasAudio,
            estimatedWorkingSetBytes: MediaMemoryBudget.estimatedVideoWorkingSetBytes(
                width: displayWidth,
                height: displayHeight,
                maxResolution: Double(quality.maxResolution)
            )
        )
    }

    private func reserveOutputURL(
        for inputURL: URL,
        in directory: URL,
        fileManager: FileManager,
        addCompressedSuffix: Bool,
        moveOriginalToTrash: Bool
    ) -> URL {
        if moveOriginalToTrash { return inputURL }

        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let rootName = addCompressedSuffix ? baseName + "_compressed" : baseName
        let extensionName = inputURL.pathExtension
        return reservedURLsLock.withLock {
            var index = 0
            while true {
                let suffix = index == 0 ? "" : "_" + String(index)
                let candidate = directory.appendingPathComponent(rootName + suffix + "." + extensionName)
                if !reservedURLs.contains(candidate) && !fileManager.fileExists(atPath: candidate.path) {
                    reservedURLs.insert(candidate)
                    return candidate
                }
                index += 1
            }
        }
    }

    private func updateOverallProgress() {
        guard queueTotal > 0 else { return }
        let totalProgress = (Double(queueCompleted) + activeProgressDict.values.reduce(0, +)) / Double(queueTotal)
        progress = min(1, totalProgress)

        var eta = ""
        if let start = batchStartTime, progress > 0 {
            let elapsed = Date().timeIntervalSince(start)
            let remaining = max(0, elapsed / progress - elapsed)
            if remaining > 60 { eta = " · " + String(Int(remaining) / 60) + "m left" }
            else if remaining > 0 { eta = " · " + String(Int(remaining)) + "s left" }
        }
        statusMessage = "Compressing · " + String(Int(progress * 100)) + "%" + eta
    }

    func cancelCompression() {
        cancellationLock.withLock { cancelled = true }
        pauseController.resume()
        compressionTask?.cancel()
        DispatchQueue.main.async { self.statusMessage = "Stopping safely…" }
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

    private func runCompression(
        inputURL: URL,
        outputURL: URL,
        quality: CompressionQuality,
        progressUpdate: @escaping (Double) -> Void
    ) async throws -> CGSize {
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCompressionError.invalidSource("No video track found")
        }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw VideoCompressionError.invalidSource("The video has no readable duration")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(transformedBounds.width), height: abs(transformedBounds.height))
        guard displaySize.width > 1, displaySize.height > 1 else {
            throw VideoCompressionError.invalidSource("The video has invalid dimensions")
        }

        let scale = min(1, quality.maxResolution / max(displaySize.width, displaySize.height))
        let renderSize = CGSize(width: evenDimension(displaySize.width * scale), height: evenDimension(displaySize.height * scale))

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        let timescale = CMTimeScale(max(1, min(600, Int32(round(frameRate > 0 ? frameRate : 30)))))
        composition.frameDuration = CMTime(value: 1, timescale: timescale)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let translation = CGAffineTransform(translationX: -transformedBounds.minX, y: -transformedBounds.minY)
        let outputTransform = preferredTransform.concatenating(translation).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        layerInstruction.setTransform(outputTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        let fileType = try outputFileType(for: outputURL.pathExtension)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(url: outputURL, fileType: fileType)
        writer.metadata = try await asset.load(.metadata)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.targetBitrate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate > 0 ? frameRate : 30
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = .identity
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = composition
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw VideoCompressionError.pipeline("Unable to configure the video pipeline")
        }
        reader.add(videoOutput)
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
            let streamDescription = audioFormatDescriptions.first.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)
            }
            let sourceSampleRate = streamDescription?.pointee.mSampleRate ?? 48_000
            let sampleRate = sourceSampleRate.isFinite && (8_000...192_000).contains(sourceSampleRate)
                ? sourceSampleRate
                : 48_000
            let sourceChannelCount = Int(streamDescription?.pointee.mChannelsPerFrame ?? 2)
            let channelCount = max(1, min(2, sourceChannelCount))

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: NSNumber(value: sampleRate),
                AVNumberOfChannelsKey: NSNumber(value: channelCount),
                AVEncoderBitRateKey: NSNumber(value: channelCount == 1 ? 96_000 : 128_000)
            ]
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw VideoCompressionError.pipeline("The source audio format cannot be converted safely")
            }
            let audioInputCandidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInputCandidate.expectsMediaDataInRealTime = false
            let audioOutputCandidate = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: NSNumber(value: sampleRate),
                AVNumberOfChannelsKey: NSNumber(value: channelCount),
                AVLinearPCMBitDepthKey: NSNumber(value: 16),
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            guard reader.canAdd(audioOutputCandidate), writer.canAdd(audioInputCandidate) else {
                throw VideoCompressionError.pipeline("Unable to configure the audio pipeline")
            }
            reader.add(audioOutputCandidate)
            writer.add(audioInputCandidate)
            audioInput = audioInputCandidate
            audioOutput = audioOutputCandidate
        }

        guard writer.startWriting() else {
            throw VideoCompressionError.pipeline(writer.error?.localizedDescription ?? "The writer could not start")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw VideoCompressionError.pipeline(reader.error?.localizedDescription ?? "The reader could not start")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let pipeline = PipelineState()
        let appendLock = NSLock()
        let videoQueue = DispatchQueue(label: "com.kompx.video-encode")
        let audioQueue = DispatchQueue(label: "com.kompx.audio-encode")
        let resources = PipelineResources(
            reader: reader,
            writer: writer,
            videoInput: videoInput,
            videoOutput: videoOutput,
            audioInput: audioInput,
            audioOutput: audioOutput
        )

        group.enter()
            resources.videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while resources.videoInput.isReadyForMoreMediaData {
                    guard self.pauseController.waitIfPaused(cancellationCheck: { self.isCancellationRequested() }) else {
                        resources.videoInput.markAsFinished()
                        if pipeline.finishVideo() { group.leave() }
                        return
                    }
                    if self.isCancellationRequested() || pipeline.hasFailure {
                    resources.videoInput.markAsFinished()
                    if pipeline.finishVideo() { group.leave() }
                    return
                }
                guard let sampleBuffer = resources.videoOutput.copyNextSampleBuffer() else {
                    resources.videoInput.markAsFinished()
                    if pipeline.finishVideo() { group.leave() }
                    return
                }
                appendLock.lock()
                let didAppend = resources.videoInput.append(sampleBuffer)
                appendLock.unlock()
                guard didAppend else {
                    pipeline.setFailure(resources.writer.error ?? VideoCompressionError.pipeline("A video frame could not be encoded"))
                    resources.videoInput.markAsFinished()
                    if pipeline.finishVideo() { group.leave() }
                    return
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                progressUpdate(max(0, min(1, timestamp / duration)))
            }
        }

        if resources.audioInput != nil, resources.audioOutput != nil {
            group.enter()
            resources.audioInput?.requestMediaDataWhenReady(on: audioQueue) {
                guard let audioInput = resources.audioInput,
                      let audioOutput = resources.audioOutput else {
                    if pipeline.finishAudio() { group.leave() }
                    return
                }
                while audioInput.isReadyForMoreMediaData {
                    guard self.pauseController.waitIfPaused(cancellationCheck: { self.isCancellationRequested() }) else {
                        audioInput.markAsFinished()
                        if pipeline.finishAudio() { group.leave() }
                        return
                    }
                    if self.isCancellationRequested() || pipeline.hasFailure {
                        audioInput.markAsFinished()
                        if pipeline.finishAudio() { group.leave() }
                        return
                    }
                    guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        if pipeline.finishAudio() { group.leave() }
                        return
                    }
                    appendLock.lock()
                    let didAppend = audioInput.append(sampleBuffer)
                    appendLock.unlock()
                    guard didAppend else {
                        pipeline.setFailure(resources.writer.error ?? VideoCompressionError.pipeline("An audio sample could not be encoded"))
                        audioInput.markAsFinished()
                        if pipeline.finishAudio() { group.leave() }
                        return
                    }
                }
            }
        }

        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }

        if self.isCancellationRequested() {
            reader.cancelReading()
            writer.cancelWriting()
            throw VideoCompressionError.cancelled
        }
        if let failure = pipeline.firstFailure {
            reader.cancelReading()
            writer.cancelWriting()
            throw failure
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw VideoCompressionError.pipeline(reader.error?.localizedDescription ?? "The reader did not finish successfully")
        }
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw VideoCompressionError.pipeline(writer.error?.localizedDescription ?? "The writer did not finish successfully")
        }
        return renderSize
    }

    private func outputFileType(for extensionName: String) throws -> AVFileType {
        switch extensionName.lowercased() {
        case "mp4": return .mp4
        case "mov": return .mov
        case "m4v": return .m4v
        default:
            throw VideoCompressionError.unsupportedContainer(
                "Only MP4, MOV, and M4V can be compressed while preserving the original container."
            )
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

    private func validateOutput(
        outputURL: URL,
        expectedDuration: Double,
        expectedDisplaySize: CGSize,
        expectedHasAudio: Bool
    ) async throws {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: outputURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            throw VideoCompressionError.invalidOutput("The encoded file is empty")
        }

        let outputAsset = AVURLAsset(url: outputURL)
        let outputDuration = try await outputAsset.load(.duration).seconds
        guard outputDuration.isFinite, abs(expectedDuration - outputDuration) <= 0.5 else {
            throw VideoCompressionError.invalidOutput("The encoded duration does not match the source")
        }
        guard let outputVideoTrack = try await outputAsset.loadTracks(withMediaType: .video).first else {
            throw VideoCompressionError.invalidOutput("The encoded file has no video track")
        }
        if expectedHasAudio {
            guard try await outputAsset.loadTracks(withMediaType: .audio).first != nil else {
                throw VideoCompressionError.invalidOutput("The encoded file lost its audio track")
            }
        }
        let outputNaturalSize = try await outputVideoTrack.load(.naturalSize)
        let outputTransform = try await outputVideoTrack.load(.preferredTransform)
        let outputBounds = CGRect(origin: .zero, size: outputNaturalSize).applying(outputTransform)
        let outputDisplaySize = CGSize(width: abs(outputBounds.width), height: abs(outputBounds.height))
        guard abs(outputDisplaySize.width - expectedDisplaySize.width) <= 2,
              abs(outputDisplaySize.height - expectedDisplaySize.height) <= 2 else {
            throw VideoCompressionError.invalidOutput("The encoded dimensions do not match the source orientation")
        }
    }

    private func verifyStagingDirectory(
        batchDirectory: URL,
        manifest: [InputManifestEntry],
        stagedFiles: [StagedFile],
        fileManager: FileManager
    ) async throws {
        let stagedDirectoryFiles = try fileManager.contentsOfDirectory(at: batchDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard stagedDirectoryFiles.count == stagedFiles.count else {
            throw VideoCompressionError.staging(
                "Temporary file count mismatch; no output was saved."
            )
        }

        let manifestURLs = Set(manifest.map { $0.originalURL })
        guard Set(stagedFiles.map { $0.originalURL }).isSubset(of: manifestURLs) else {
            throw VideoCompressionError.staging("A staged video does not belong to this batch")
        }
        for stagedFile in stagedFiles {
            guard fileManager.fileExists(atPath: stagedFile.tempURL.path) else {
                throw VideoCompressionError.staging(stagedFile.filename + " is missing from the temporary batch")
            }
            try await validateOutput(
                outputURL: stagedFile.tempURL,
                expectedDuration: stagedFile.originalDuration,
                expectedDisplaySize: stagedFile.expectedDisplaySize,
                expectedHasAudio: stagedFile.hasAudio
            )
            let currentSize = try fileSizeOrThrow(of: stagedFile.tempURL, fileManager: fileManager)
            guard currentSize == stagedFile.outputByteCount, currentSize < stagedFile.originalByteCount else {
                throw VideoCompressionError.staging("A verified video copy changed before saving")
            }
        }
    }

    private func commitBatch(_ stagedFiles: [StagedFile], fileManager: FileManager) throws {
        var committedInputURLs: Set<URL> = []
        do {
            for stagedFile in stagedFiles {
                guard fileManager.fileExists(atPath: stagedFile.originalURL.path) else {
                    throw VideoCompressionError.sourceChanged("The source disappeared before its copy could be saved")
                }
                let currentAttributes = try fileManager.attributesOfItem(atPath: stagedFile.originalURL.path)
                let currentSize = (currentAttributes[.size] as? NSNumber)?.int64Value
                let currentModificationDate = currentAttributes[.modificationDate] as? Date
                guard currentSize == stagedFile.originalByteCount,
                      currentModificationDate == stagedFile.sourceModificationDate else {
                    throw VideoCompressionError.sourceChanged("The source changed while it was being compressed")
                }

                if stagedFile.moveOriginalToTrash {
                    try commitByMovingOriginalToTrash(stagedFile, fileManager: fileManager)
                    committedInputURLs.insert(stagedFile.originalURL)
                } else {
                    guard !fileManager.fileExists(atPath: stagedFile.finalURL.path) else {
                        throw VideoCompressionError.output("An output filename became occupied; try again")
                    }
                    try moveItemSafely(from: stagedFile.tempURL, to: stagedFile.finalURL, fileManager: fileManager)
                    committedInputURLs.insert(stagedFile.originalURL)
                }
            }
        } catch {
            // A replacement is already a valid, verified result. Never remove committed
            // originals or copies while reporting a later item failure.
            throw VideoCommitError(underlying: error, committedInputURLs: committedInputURLs)
        }
    }

    private func commitByMovingOriginalToTrash(_ stagedFile: StagedFile, fileManager: FileManager) throws {
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
            throw VideoCompressionError.output("The original could not be backed up safely before moving it to Trash")
        }

        var trashedURL: NSURL?
        do {
            try fileManager.trashItem(at: stagedFile.originalURL, resultingItemURL: &trashedURL)
        } catch {
            try? fileManager.removeItem(at: recoveryURL)
            throw VideoCompressionError.output("The original could not be moved to Trash: \(error.localizedDescription)")
        }

        do {
            try moveItemSafely(from: stagedFile.tempURL, to: stagedFile.finalURL, fileManager: fileManager)
            applyOriginalFileAttributes(from: recoveryURL, to: stagedFile.finalURL, fileManager: fileManager)
            try? fileManager.removeItem(at: recoveryURL)
        } catch {
            do {
                guard !fileManager.fileExists(atPath: stagedFile.originalURL.path) else {
                    throw VideoCompressionError.output("The destination changed while saving; the original remains in Trash")
                }
                if let trashedURL, let trashedPath = trashedURL.path,
                   fileManager.fileExists(atPath: trashedPath) {
                    try moveItemSafely(from: trashedURL as URL, to: stagedFile.originalURL, fileManager: fileManager)
                } else {
                    try moveItemSafely(from: recoveryURL, to: stagedFile.originalURL, fileManager: fileManager)
                }
            } catch {
                throw VideoCompressionError.output("The compressed file could not be placed, and the original could not be restored: \(error.localizedDescription)")
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

    private func validateOutputDirectory(_ directory: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VideoCompressionError.output("The output folder is no longer available")
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw VideoCompressionError.output("The output folder is not writable")
        }
    }

    private func fileSize(of url: URL, fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber else { return nil }
        return value.int64Value
    }

    private func fileSizeOrThrow(of url: URL, fileManager: FileManager) throws -> Int64 {
        guard let fileSize = fileSize(of: url, fileManager: fileManager), fileSize > 0 else {
            throw VideoCompressionError.invalidOutput("The encoded file is empty")
        }
        return fileSize
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
                return "No smaller video copies were needed. Kept \(pluralized(unchanged, singular: "original"))."
            }
            if unchanged == 0 && failed > 0 {
                return "No video copies were saved. \(pluralized(failed, singular: "item")) failed; originals were kept."
            }
        }

        let savedBytes = compressed.compactMap(\.savedByteCount).reduce(0, +)
        let savedText = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
        var actions: [String] = []
        if replaced > 0 {
            actions.append("Replaced \(pluralized(replaced, singular: "original"))")
        }
        if copies > 0 {
            actions.append("Saved \(pluralized(copies, singular: "verified video copy", plural: "verified video copies"))")
        }
        var message = actions.joined(separator: " · ") + " · \(savedText) smaller"
        if unchanged > 0 { message += " · Kept \(pluralized(unchanged, singular: "original"))" }
        if failed > 0 { message += " · \(pluralized(failed, singular: "item")) failed; originals were kept" }
        if trashed > 0 { message += " · \(pluralized(trashed, singular: "original")) moved to Trash" }
        return message + "."
    }

    private func pluralized(_ count: Int, singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
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

    private func evenDimension(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, Int(value.rounded(.down)))
        return CGFloat(rounded % 2 == 0 ? rounded : rounded - 1)
    }
}

private struct VideoCommitError: LocalizedError {
    let underlying: Error
    let committedInputURLs: Set<URL>

    var errorDescription: String? { underlying.localizedDescription }
}

private enum VideoCompressionError: LocalizedError {
    case cancelled
    case invalidSource(String)
    case invalidOutput(String)
    case output(String)
    case sourceChanged(String)
    case pipeline(String)
    case staging(String)
    case unsupportedContainer(String)
    case resource(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Compression was cancelled"
        case .invalidSource(let message), .invalidOutput(let message), .output(let message), .sourceChanged(let message),
             .pipeline(let message), .staging(let message), .unsupportedContainer(let message), .resource(let message): return message
        }
    }
}
