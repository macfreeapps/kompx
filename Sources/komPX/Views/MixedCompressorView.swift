import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

struct MixedCompressorView: View {
    @StateObject private var videoCompressor = VideoCompressor()
    @StateObject private var imageCompressor = ImageCompressor()
    @StateObject private var displaySleepManager = DisplaySleepManager()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let requestEmptyTrash: () -> Void
    private let diskSpaceTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var selectedURLs: [URL] = []
    @State private var itemStatuses: [String: CompressionItemStatus] = [:]
    @State private var itemResults: [String: CompressionItemResult] = [:]
    @AppStorage("compressionQuality") private var selectedQualityValue = CompressionQuality.balanced.rawValue
    @AppStorage("imageOutputFormat") private var imageOutputFormatValue = ImageOutputFormatChoice.heic.rawValue
    @AppStorage("outputLocation") private var outputLocationValue = OutputLocation.sameAsSource.rawValue
    @AppStorage("customOutputDirectoryPath") private var customOutputDirectoryPath = ""
    @AppStorage("useCompressedSuffix") private var addCompressedSuffix = false
    @State private var isTargeted = false
    @State private var isBatchRunning = false
    @State private var activeBatchURLs: [URL] = []
    @State private var batchCompletedCount = 0
    @State private var activeVideoWorkCount = 0
    @State private var activeImageWorkCount = 0
    @State private var initialVideoCount = 0
    @State private var initialImageCount = 0
    @State private var finalStatusMessage = ""
    @State private var fileByteCounts: [String: Int64] = [:]
    @State private var showCompletionFeedback = false
    @State private var batchStartedAt: Date?
    @State private var activeQuality: CompressionQuality = .balanced
    @State private var activeImageOutputFormat: ImageOutputFormatChoice = .heic
    @State private var activeOutputDirectory: URL?
    @State private var activeAddCompressedSuffix = false
    @State private var activeKeepScreenAwake = false
    @State private var isUserPaused = false
    @State private var isDiskSpacePaused = false
    @State private var isShowingDiskSpaceWarning = false
    @State private var diskSpaceWarningMessage = ""
    @State private var recoveryURLs: [URL] = []
    @State private var isShowingRestorePrompt = false
    @State private var hasPreparedRecoveryPrompt = false

    @AppStorage("autoCompressOnDrop") private var autoCompressOnDrop = false
    @AppStorage("keepScreenAwakeWhileProcessing") private var keepScreenAwakeWhileProcessing = false

    private let accent = Color(red: 0.31, green: 0.28, blue: 0.72)
    private let queuePreviewLimit = 250

    init(requestEmptyTrash: @escaping () -> Void = {}) {
        self.requestEmptyTrash = requestEmptyTrash
    }

    private var isCompressing: Bool {
        isBatchRunning || videoCompressor.isCompressing || imageCompressor.isCompressing
    }

    private var processingIsPaused: Bool {
        isUserPaused || isDiskSpacePaused || videoCompressor.isPaused || imageCompressor.isPaused
    }

    private var combinedProgress: Double {
        let total = initialVideoCount + initialImageCount
        guard total > 0 else { return 0 }
        let activeVideoProgress = videoCompressor.progress * Double(activeVideoWorkCount)
        let activeImageProgress = imageCompressor.progress * Double(activeImageWorkCount)
        return min(1, (Double(batchCompletedCount) + activeVideoProgress + activeImageProgress) / Double(total))
    }

    private var activeStatusMessage: String {
        if videoCompressor.isCompressing { return videoCompressor.statusMessage }
        if imageCompressor.isCompressing { return imageCompressor.statusMessage }
        return finalStatusMessage
    }

    private var queuePreviewURLs: [URL] {
        Array(selectedURLs.prefix(queuePreviewLimit))
    }

    private var queueHasHiddenItems: Bool {
        selectedURLs.count > queuePreviewLimit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader
                if isCompressing {
                    progressCard
                }
                sourceCard
                if !isCompressing && !selectedURLs.isEmpty {
                    actionCard
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
        .onAppear(perform: prepareRecoveryPrompt)
        .onReceive(diskSpaceTimer) { _ in monitorActiveDiskSpace() }
        .onDisappear { displaySleepManager.stop() }
        .alert("Restore Last Work?", isPresented: $isShowingRestorePrompt) {
            Button("Don’t Restore", role: .cancel) {
                RecoveryStore.clear()
                recoveryURLs = []
            }
            Button("Restore") { restoreLastWork() }
        } message: {
            Text("komPX found \(recoveryURLs.count) unfinished item\(recoveryURLs.count == 1 ? "" : "s") from the previous run. Restore them to the queue?")
        }
        .alert("Low Disk Space", isPresented: $isShowingDiskSpaceWarning) {
            Button("Empty Trash…") { requestEmptyTrash() }
            Button("Resume", action: resumeBatch)
            Button("OK", role: .cancel) {}
        } message: {
            Text(diskSpaceWarningMessage)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.gradient)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Compress media")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Images and videos share one verified queue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Label("Verified output", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(accent.opacity(0.1), in: Capsule())
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Queue").font(.headline)
                    Text(selectionSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedURLs.isEmpty {
                    if !isCompressing && allItemsFinished && hasFinishedItems {
                        Button("Clear done", systemImage: "checkmark.circle") { clearFinishedItems() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("Clear queue", systemImage: "xmark.circle") { clearQueue() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCompressing)
                        .help(isCompressing ? "Pause or cancel processing before clearing the queue." : "Remove all items from the queue.")
                    Button("Add more", systemImage: "plus") { openFileBrowser() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCompressing)
                }
            }

            if selectedURLs.isEmpty {
                Button(action: openFileBrowser) {
                    VStack(spacing: 10) {
                        Image(systemName: isTargeted ? "arrow.down.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(isTargeted ? accent : .secondary)
                            .accessibilityHidden(true)
                        Text(isTargeted ? "Release to add media" : "Drop media here")
                            .font(.headline)
                        Text("or click to choose from Finder")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Single-frame images: JPG, PNG, HEIC, TIFF · Videos: MP4, MOV, M4V")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 172)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(isTargeted ? accent.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isTargeted ? accent : Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [7, 6]))
                }
            } else {
                if isCompressing {
                    Label("Drop more media to append to this queue.", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if queueHasHiddenItems {
                    Label(
                        "Showing the first \(queuePreviewLimit) items of \(selectedURLs.count).",
                        systemImage: "rectangle.stack"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("The full queue is kept in memory and processed; only a preview is rendered for large queues.")
                }
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        ForEach(queuePreviewURLs, id: \.path) { url in
                            mediaRow(for: url)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollIndicators(.automatic)
            }
        }
        .komPXCardSurface()
        .dropDestination(for: URL.self) { urls, _ in
            addDroppedMedia(from: urls)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private func mediaRow(for url: URL) -> some View {
        HStack(spacing: 11) {
            Image(systemName: isVideo(url) ? "play.rectangle.fill" : "photo.fill")
                .foregroundStyle(isVideo(url) ? .blue : .pink)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(itemResult(for: url)?.outputURL?.path ?? url.path)
                Text(resultDetail(for: url) ?? fileDetail(for: url))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            CompressionStatusBadge(status: status(for: url))
            Button("Remove \(isVideo(url) ? "video" : "image")", systemImage: "xmark.circle.fill") {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    selectedURLs.removeAll { $0 == url }
                    let key = queueKey(for: url)
                    itemStatuses.removeValue(forKey: key)
                    itemResults.removeValue(forKey: key)
                    fileByteCounts.removeValue(forKey: key)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(url.lastPathComponent)")
            .help("Remove \(url.lastPathComponent)")
            .disabled(isCompressing)

            if status(for: url) == .failed {
                Button("Retry \(url.lastPathComponent)", systemImage: "arrow.clockwise") {
                    retry(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCompressing)
                .help("Retry compression for \(url.lastPathComponent)")

                Button("Open \(url.lastPathComponent) in Finder", systemImage: "folder") {
                    openInFinder(for: url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show \(url.lastPathComponent) in Finder")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(progressTitle, systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(Int(combinedProgress * 100))%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(accent)
            }
            FancyProgressBar(progress: combinedProgress, gradientColors: [accent, .mint])
            Text(progressStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Label(wholeQueueTimeRemaining(at: context.date), systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
            }
            HStack(spacing: 8) {
                Button(
                    processingIsPaused ? "Resume" : "Pause",
                    systemImage: processingIsPaused ? "play.fill" : "pause.fill",
                    action: processingIsPaused ? resumeBatch : pauseBatch
                )
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.small)

                Button("Cancel safely", systemImage: "xmark") { cancelBatch() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(videoCompressor.statusMessage == "Stopping safely…" || imageCompressor.statusMessage == "Stopping safely…")
            }
        }
        .komPXCardSurface()
    }

    private var actionCard: some View {
        VStack(spacing: 12) {
            if showCompletionFeedback {
                completionFeedback
            }

            if pendingURLs.isEmpty {
                Label("All selected media has been checked.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: handleCompression) {
                    Label(actionTitle, systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
            }

            if !activeStatusMessage.isEmpty {
                Label(activeStatusMessage, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .orange : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .komPXCardSurface()
    }

    private var completionFeedback: some View {
        let hasFailures = selectedURLs.contains { status(for: $0) == .failed }
        let feedbackColor: Color = hasFailures ? .orange : .green

        return HStack(spacing: 10) {
            Image(systemName: hasFailures ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(feedbackColor)
                .accessibilityHidden(true)
            Text(hasFailures ? "Queue finished — review failed items" : "All queued media finished")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(feedbackColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private var selectionSummary: String {
        guard !selectedURLs.isEmpty else { return "Drop files here or choose from Finder" }
        return queueSummary(for: selectedURLs)
    }

    private var actionTitle: String {
        guard !pendingURLs.isEmpty else { return "All media checked" }
        return "Compress \(pendingURLs.count) item" + (pendingURLs.count == 1 ? "" : "s")
    }

    private var pendingURLs: [URL] {
        selectedURLs.filter {
            let status = status(for: $0)
            return status == .waiting || status == .failed
        }
    }

    private var selectedQuality: CompressionQuality {
        get { CompressionQuality(rawValue: selectedQualityValue) ?? .balanced }
        set { selectedQualityValue = newValue.rawValue }
    }

    private var outputLocation: OutputLocation {
        get { OutputLocation(rawValue: outputLocationValue) ?? .sameAsSource }
        set { outputLocationValue = newValue.rawValue }
    }

    private var customOutputDirectory: URL? {
        get {
            guard !customOutputDirectoryPath.isEmpty else { return nil }
            return URL(fileURLWithPath: customOutputDirectoryPath, isDirectory: true)
        }
        set { customOutputDirectoryPath = newValue?.path ?? "" }
    }

    private var hasFinishedItems: Bool {
        selectedURLs.contains { url in
            status(for: url) == .compressed || status(for: url) == .unchanged
        }
    }

    private var allItemsFinished: Bool {
        !selectedURLs.isEmpty && selectedURLs.allSatisfy { url in
            switch status(for: url) {
            case .compressed, .unchanged, .failed:
                return true
            case .waiting, .compressing:
                return false
            }
        }
    }

    private var progressTitle: String {
        "Processing \(batchCompletedCount) of \(initialVideoCount + initialImageCount)"
    }

    private var progressStatusMessage: String {
        if isDiskSpacePaused {
            return "Paused — " + diskSpaceWarningMessage
        }
        if processingIsPaused {
            return "Paused safely… Originals are not being changed."
        }
        return activeStatusMessage.isEmpty ? "Preparing verified copies…" : activeStatusMessage
    }

    private func wholeQueueTimeRemaining(at date: Date) -> String {
        guard let batchStartedAt, combinedProgress > 0.01 else {
            return "Estimating time remaining..."
        }

        let elapsed = max(0, date.timeIntervalSince(batchStartedAt))
        let estimatedTotal = elapsed / combinedProgress
        let remaining = max(0, estimatedTotal - elapsed)

        if remaining < 1 {
            return "Less than 1s left for this queue"
        }

        return formattedDuration(remaining) + " left for this queue"
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(1, Int(duration.rounded(.up)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(hours) + "h " + String(minutes) + "m"
        }
        if minutes > 0 {
            return String(minutes) + "m " + String(seconds) + "s"
        }
        return String(seconds) + "s"
    }

    private var statusIsError: Bool {
        let message = activeStatusMessage.lowercased()
        return message.contains("error") || message.contains("failed") || message.contains("could not") || message.contains("cancel") || message.contains("choose an output folder")
    }

    private func handleCompression() {
        guard !pendingURLs.isEmpty, !isCompressing else { return }
        guard outputLocation != .custom || customOutputDirectory != nil else {
            finalStatusMessage = "Choose an output folder before compressing."
            return
        }
        executeCompression()
    }

    private func executeCompression() {
        let queuedURLs = pendingURLs
        let videos = queuedURLs.filter(isVideo)
        let images = queuedURLs.filter { !isVideo($0) }
        initialVideoCount = videos.count
        initialImageCount = images.count
        activeBatchURLs = queuedURLs
        batchCompletedCount = 0
        finalStatusMessage = ""
        showCompletionFeedback = false
        batchStartedAt = Date()
        activeQuality = selectedQuality
        activeImageOutputFormat = imageOutputFormat
        activeOutputDirectory = selectedOutputDirectory
        activeAddCompressedSuffix = addCompressedSuffix
        activeKeepScreenAwake = keepScreenAwakeWhileProcessing
        isUserPaused = false
        isDiskSpacePaused = false
        isBatchRunning = true
        var nextStatuses = itemStatuses
        var nextResults = itemResults
        for url in queuedURLs {
            let key = queueKey(for: url)
            nextStatuses[key] = .waiting
            nextResults.removeValue(forKey: key)
        }
        itemStatuses = nextStatuses
        itemResults = nextResults
        persistRecoveryState()
        if activeKeepScreenAwake { displaySleepManager.start() }
        startQueuedWork()
    }

    private func retry(_ url: URL) {
        guard !isCompressing else { return }
        guard outputLocation != .custom || customOutputDirectory != nil else {
            finalStatusMessage = "Choose an output folder before retrying."
            return
        }

        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            let key = queueKey(for: url)
            itemStatuses[key] = .waiting
            itemResults.removeValue(forKey: key)
        }
        finalStatusMessage = ""
        initialVideoCount = isVideo(url) ? 1 : 0
        initialImageCount = isVideo(url) ? 0 : 1
        activeBatchURLs = [url]
        batchCompletedCount = 0
        showCompletionFeedback = false
        batchStartedAt = Date()
        activeQuality = selectedQuality
        activeImageOutputFormat = imageOutputFormat
        activeOutputDirectory = selectedOutputDirectory
        activeAddCompressedSuffix = addCompressedSuffix
        activeKeepScreenAwake = keepScreenAwakeWhileProcessing
        isUserPaused = false
        isDiskSpacePaused = false
        isBatchRunning = true

        persistRecoveryState()
        if activeKeepScreenAwake { displaySleepManager.start() }
        startQueuedWork()
    }

    private func startQueuedWork() {
        guard isBatchRunning else { return }
        guard !isUserPaused, !isDiskSpacePaused else { return }

        let waitingURLs = activeBatchURLs.filter { status(for: $0) == .waiting }
        let waitingVideos = waitingURLs.filter(isVideo)
        let waitingImages = waitingURLs.filter { !isVideo($0) }
        let hasRunningWork = activeVideoWorkCount > 0 || activeImageWorkCount > 0
            || videoCompressor.isCompressing || imageCompressor.isCompressing

        if waitingURLs.isEmpty {
            if !hasRunningWork { finishBatch() }
            return
        }

        if activeVideoWorkCount == 0, !videoCompressor.isCompressing, !waitingVideos.isEmpty {
            guard checkDiskSpaceBeforeProcessing(waitingVideos) else { return }
            startVideoItems(waitingVideos)
        }
        if activeImageWorkCount == 0, !imageCompressor.isCompressing, !waitingImages.isEmpty {
            guard checkDiskSpaceBeforeProcessing(waitingImages) else { return }
            startImageItems(waitingImages)
        }
    }

    private func startVideoItems(_ urls: [URL]) {
        let workURLs = urls
        activeVideoWorkCount = workURLs.count
        var nextStatuses = itemStatuses
        for url in workURLs {
            nextStatuses[queueKey(for: url)] = .compressing
        }
        itemStatuses = nextStatuses
        videoCompressor.compressVideos(
            inputURLs: workURLs,
            quality: activeQuality,
            outputDirectory: activeOutputDirectory,
            addCompressedSuffix: activeAddCompressedSuffix,
            completion: { results in
                Task { @MainActor in
                    let compressorMessage = videoCompressor.statusMessage
                    activeVideoWorkCount = 0
                    apply(results, to: workURLs, compressorMessage: compressorMessage)
                    if isCancellationMessage(compressorMessage) {
                        if !videoCompressor.isCompressing && !imageCompressor.isCompressing {
                            finishBatch()
                        }
                    } else {
                        batchCompletedCount += workURLs.count
                        startQueuedWork()
                    }
                }
            }
        )
    }

    private func startImageItems(_ urls: [URL]) {
        let workURLs = urls
        activeImageWorkCount = workURLs.count
        var nextStatuses = itemStatuses
        for url in workURLs {
            nextStatuses[queueKey(for: url)] = .compressing
        }
        itemStatuses = nextStatuses
        imageCompressor.compressImages(
            inputURLs: workURLs,
            quality: imageQuality,
            outputDirectory: activeOutputDirectory,
            addCompressedSuffix: activeAddCompressedSuffix,
            outputFormatPreference: activeImageOutputFormat,
            completion: { results in
                Task { @MainActor in
                    let compressorMessage = imageCompressor.statusMessage
                    activeImageWorkCount = 0
                    apply(results, to: workURLs, compressorMessage: compressorMessage)
                    if isCancellationMessage(compressorMessage) {
                        if !videoCompressor.isCompressing && !imageCompressor.isCompressing {
                            finishBatch()
                        }
                    } else {
                        batchCompletedCount += workURLs.count
                        startQueuedWork()
                    }
                }
            }
        )
    }

    private var selectedOutputDirectory: URL? {
        outputLocation == .custom ? customOutputDirectory : nil
    }

    private var imageQuality: ImageCompressionQuality {
        switch activeQuality {
        case .high: return .high
        case .balanced: return .balanced
        case .aggressive: return .aggressive
        }
    }

    private var imageOutputFormat: ImageOutputFormatChoice {
        ImageOutputFormatChoice(rawValue: imageOutputFormatValue) ?? .heic
    }

    private func apply(_ results: [CompressionItemResult], to urls: [URL], compressorMessage: String) {
        let resultByPath = Dictionary(uniqueKeysWithValues: results.map { ($0.id.path, $0) })
        var nextStatuses = itemStatuses
        var nextResults = itemResults
        for url in urls {
            let key = queueKey(for: url)
            if let result = resultByPath[key] {
                nextResults[key] = result
                switch result.outcome {
                case .compressed: nextStatuses[key] = .compressed
                case .unchanged: nextStatuses[key] = .unchanged
                case .failed: nextStatuses[key] = .failed
                }
            } else if isCancellationMessage(compressorMessage) {
                nextStatuses[key] = .waiting
            } else {
                nextStatuses[key] = .failed
                nextResults[key] = CompressionItemResult(
                    inputURL: url,
                    originalByteCount: fileSize(of: url),
                    outcome: .failed,
                    message: compressorMessage.isEmpty ? "No result was returned; try again." : compressorMessage
                )
            }
        }
        itemStatuses = nextStatuses
        itemResults = nextResults
        persistRecoveryState()
    }

    private func finishBatch() {
        let results = activeBatchURLs.compactMap { itemResult(for: $0) }
        let compressed = results.filter { $0.outcome == .compressed }.count
        let replaced = results.filter { $0.outcome == .compressed && $0.didReplaceOriginal }.count
        let copies = compressed - replaced
        let trashed = results.filter { $0.outcome == .compressed && $0.didMoveOriginalToTrash }.count
        let unchanged = results.filter { $0.outcome == .unchanged }.count
        let failed = results.filter { $0.outcome == .failed }.count
        let savedBytes = results.compactMap(\.savedByteCount).reduce(0, +)
        let didFinishAllItems = !activeBatchURLs.isEmpty && activeBatchURLs.allSatisfy { url in
            switch status(for: url) {
            case .compressed, .unchanged, .failed:
                return true
            case .waiting, .compressing:
                return false
            }
        }
        isBatchRunning = false
        if activeBatchURLs.contains(where: { status(for: $0) == .waiting }) &&
            (isCancellationMessage(videoCompressor.statusMessage) || isCancellationMessage(imageCompressor.statusMessage)) {
            finalStatusMessage = "Cancelled safely. Completed \(pluralized(compressed, singular: "item")); unfinished originals are waiting."
        } else {
            if compressed == 0 && failed == 0 && unchanged > 0 {
                finalStatusMessage = "No smaller copies were needed. Kept \(pluralized(unchanged, singular: "original"))."
            } else if compressed == 0 && unchanged == 0 && failed > 0 {
                finalStatusMessage = "No copies were saved. \(pluralized(failed, singular: "item")) failed; originals were kept."
            } else {
                let savedText = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
                var actions: [String] = []
                if replaced > 0 {
                    actions.append("Replaced \(pluralized(replaced, singular: "original"))")
                }
                if copies > 0 {
                    actions.append("Saved \(pluralized(copies, singular: "verified copy", plural: "verified copies"))")
                }
                var message = actions.joined(separator: " · ") + " · \(savedText) smaller"
                if unchanged > 0 { message += " · Kept \(pluralized(unchanged, singular: "original"))" }
                if failed > 0 { message += " · \(pluralized(failed, singular: "item")) failed; originals were kept" }
                if trashed > 0 { message += " · \(pluralized(trashed, singular: "original")) moved to Trash" }
                finalStatusMessage = message + "."
            }
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8)) {
            showCompletionFeedback = didFinishAllItems
        }
        displaySleepManager.stop()
        activeVideoWorkCount = 0
        activeImageWorkCount = 0
        isUserPaused = false
        isDiskSpacePaused = false
        if didFinishAllItems {
            CompletionNotificationManager.shared.notifyFinished(summary: finalStatusMessage)
            RecoveryStore.clear()
        } else {
            persistRecoveryState()
        }
        batchStartedAt = nil
    }

    private func cancelBatch() {
        guard isBatchRunning else { return }
        if activeVideoWorkCount > 0 || videoCompressor.isCompressing { videoCompressor.cancelCompression() }
        if activeImageWorkCount > 0 || imageCompressor.isCompressing { imageCompressor.cancelCompression() }
    }

    private func pauseBatch() {
        guard isBatchRunning else { return }
        isUserPaused = true
        videoCompressor.pauseCompression()
        imageCompressor.pauseCompression()
        persistRecoveryState()
    }

    private func resumeBatch() {
        guard isBatchRunning else { return }
        let activeURLs = activeBatchURLs.filter {
            let status = status(for: $0)
            return status == .waiting || status == .compressing
        }
        let issues = diskSpaceIssues(for: activeURLs)
        guard issues.isEmpty else {
            pauseForDiskSpace(issues)
            return
        }

        isUserPaused = false
        isDiskSpacePaused = false
        videoCompressor.resumeCompression()
        imageCompressor.resumeCompression()
        if activeVideoWorkCount == 0 && activeImageWorkCount == 0
            && !videoCompressor.isCompressing && !imageCompressor.isCompressing {
            startQueuedWork()
        }
    }

    private func checkDiskSpaceBeforeProcessing(_ urls: [URL]) -> Bool {
        let issues = diskSpaceIssues(for: urls)
        guard issues.isEmpty else {
            pauseForDiskSpace(issues)
            return false
        }
        return true
    }

    private func monitorActiveDiskSpace() {
        guard isBatchRunning else { return }
        let activeURLs = activeBatchURLs.filter {
            let status = status(for: $0)
            return status == .waiting || status == .compressing
        }
        let issues = diskSpaceIssues(for: activeURLs)
        guard !issues.isEmpty else { return }
        pauseForDiskSpace(issues)
    }

    private func diskSpaceIssues(for url: URL) -> [DiskSpaceIssue] {
        let outputDirectory = activeOutputDirectory ?? url.deletingLastPathComponent()
        return DiskSpaceMonitor.writeSpaceIssues(for: outputDirectory)
    }

    private func diskSpaceIssues(for urls: [URL]) -> [DiskSpaceIssue] {
        var seenDirectories = Set<String>()
        let directories = urls.compactMap { url -> URL? in
            let directory = activeOutputDirectory ?? url.deletingLastPathComponent()
            return seenDirectories.insert(directory.path).inserted ? directory : nil
        }

        var seenIDs = Set<String>()
        return directories
            .flatMap { DiskSpaceMonitor.writeSpaceIssues(for: $0) }
            .filter { seenIDs.insert($0.id).inserted }
    }

    private func pauseForDiskSpace(_ issues: [DiskSpaceIssue]) {
        isDiskSpacePaused = true
        diskSpaceWarningMessage = issues.map(\.message).joined(separator: " ")
            + " Free at least 1 GB before resuming."
        videoCompressor.pauseCompression()
        imageCompressor.pauseCompression()
        if !isShowingDiskSpaceWarning {
            isShowingDiskSpaceWarning = true
        }
    }

    private func prepareRecoveryPrompt() {
        guard !hasPreparedRecoveryPrompt else { return }
        hasPreparedRecoveryPrompt = true
        let urls = RecoveryStore.loadPendingURLs()
        guard !urls.isEmpty else { return }
        recoveryURLs = urls
        isShowingRestorePrompt = true
    }

    private func restoreLastWork() {
        let fileManager = FileManager.default
        let availableURLs = recoveryURLs.filter {
            fileManager.fileExists(atPath: $0.path)
                && SupportedMediaFiles.mixedExtensions.contains($0.pathExtension.lowercased())
        }
        let missingCount = recoveryURLs.count - availableURLs.count
        recoveryURLs = []

        if availableURLs.isEmpty {
            RecoveryStore.clear()
            finalStatusMessage = "The previous queue could not be restored because its files are no longer available."
            return
        }

        acceptMedia(availableURLs, replacingQueue: true)
        RecoveryStore.savePending(availableURLs)
        if missingCount > 0 {
            finalStatusMessage = String(missingCount) + " previous item" + (missingCount == 1 ? " was" : "s were") + " unavailable; the remaining queue was restored."
        }
    }

    private func persistRecoveryState() {
        let unfinishedURLs = activeBatchURLs.filter { url in
            switch status(for: url) {
            case .compressed, .unchanged:
                return false
            case .waiting, .compressing, .failed:
                return true
            }
        }
        RecoveryStore.savePending(unfinishedURLs)
    }

    private func addDroppedMedia(from droppedURLs: [URL]) -> Bool {
        guard !droppedURLs.isEmpty else { return false }
        let dropStartedDuringBatch = isBatchRunning
        Task { @MainActor in
            let urls = await DroppedFileLoader.matchingURLsAsync(
                from: droppedURLs,
                allowedExtensions: SupportedMediaFiles.mixedExtensions
            )
            acceptMedia(
                urls,
                replacingQueue: !dropStartedDuringBatch,
                startImmediately: autoCompressOnDrop,
                preserveExistingQueue: dropStartedDuringBatch
            )
        }
        return true
    }

    @MainActor
    private func acceptMedia(
        _ urls: [URL],
        replacingQueue: Bool = false,
        startImmediately: Bool = false,
        preserveExistingQueue: Bool = false
    ) {
        guard !urls.isEmpty else { return }
        guard !isCompressing || isBatchRunning else {
            finalStatusMessage = "Finish or cancel the current queue before replacing it with dropped files."
            return
        }

        var seenPaths = Set<String>()
        let uniqueURLs = urls.filter { seenPaths.insert($0.path).inserted }
        let existingPaths = Set(selectedURLs.map { $0.path })
        let newURLs = uniqueURLs.filter { !existingPaths.contains($0.path) }
        guard !newURLs.isEmpty else { return }

        finalStatusMessage = ""
        let appendToActiveBatch = isBatchRunning
        let keepExistingQueue = appendToActiveBatch || preserveExistingQueue
        showCompletionFeedback = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            var nextStatuses = itemStatuses
            var nextResults = itemResults
            var nextFileByteCounts = fileByteCounts
            if replacingQueue && !keepExistingQueue {
                selectedURLs = newURLs
                nextStatuses.removeAll()
                nextResults.removeAll()
                nextFileByteCounts.removeAll()
            } else {
                selectedURLs.append(contentsOf: newURLs)
            }
            for url in newURLs {
                nextStatuses[queueKey(for: url)] = .waiting
            }
            itemStatuses = nextStatuses
            itemResults = nextResults
            fileByteCounts = nextFileByteCounts
        }
        if appendToActiveBatch {
            activeBatchURLs.append(contentsOf: newURLs)
            initialVideoCount += newURLs.filter(isVideo).count
            initialImageCount += newURLs.filter { !isVideo($0) }.count
            persistRecoveryState()
            if !isUserPaused && !isDiskSpacePaused {
                startQueuedWork()
            }
        }
        cacheFileSizes(for: newURLs)
        if (startImmediately || autoCompressOnDrop) && !isBatchRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !isBatchRunning && !pendingURLs.isEmpty { handleCompression() }
            }
        }
    }

    private func openFileBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = SupportedMediaFiles.mixedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        Task { @MainActor in
            let urls = await DroppedFileLoader.matchingURLsAsync(
                from: panel.urls,
                allowedExtensions: SupportedMediaFiles.mixedExtensions
            )
            acceptMedia(urls)
        }
    }

    private func isVideo(_ url: URL) -> Bool {
        SupportedMediaFiles.videoExtensions.contains(url.pathExtension.lowercased())
    }

    private func queueKey(for url: URL) -> String {
        // Queue URLs are normalized on intake. Keep hot UI lookups string-only;
        // standardizedFileURL can perform filesystem work on macOS.
        url.path
    }

    private func status(for url: URL) -> CompressionItemStatus {
        itemStatuses[queueKey(for: url)] ?? .waiting
    }

    private func itemResult(for url: URL) -> CompressionItemResult? {
        itemResults[queueKey(for: url)]
    }

    private func openInFinder(for url: URL) {
        let preferredURL = itemResult(for: url)?.outputURL ?? url
        let targetURL = FileManager.default.fileExists(atPath: preferredURL.path)
            ? preferredURL
            : preferredURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }

    private func fileSize(of url: URL) -> Int64 {
        if let cachedSize = fileByteCounts[queueKey(for: url)] { return cachedSize }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber else { return 0 }
        return value.int64Value
    }

    private func fileDetail(for url: URL) -> String {
        guard let size = fileByteCounts[queueKey(for: url)] else { return "Reading file size…" }
        guard size > 0 else { return "File is unavailable" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func cacheFileSizes(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            let sizes = await DroppedFileLoader.fileSizesAsync(for: urls)
            let selectedPaths = Set(selectedURLs.map { queueKey(for: $0) })
            var nextFileByteCounts = fileByteCounts
            for (path, size) in sizes where selectedPaths.contains(path) {
                nextFileByteCounts[path] = size
            }
            fileByteCounts = nextFileByteCounts
        }
    }

    private func resultDetail(for url: URL) -> String? {
        guard let result = itemResult(for: url) else { return nil }
        switch result.outcome {
        case .compressed:
            guard let outputByteCount = result.outputByteCount,
                  let reduction = result.reductionPercentage else { return "Verified copy saved" }
            let original = ByteCountFormatter.string(fromByteCount: result.originalByteCount, countStyle: .file)
            let output = ByteCountFormatter.string(fromByteCount: outputByteCount, countStyle: .file)
            let destination: String
            if result.didReplaceOriginal {
                let outputPath = result.outputURL?.path ?? url.path
                destination = result.didMoveOriginalToTrash
                    ? "replaced at " + outputPath + " · original moved to Trash"
                    : "replaced at " + outputPath
            } else if let outputURL = result.outputURL {
                destination = result.didMoveOriginalToTrash
                    ? "saved to \(outputURL.path) · original moved to Trash"
                    : "saved to \(outputURL.path)"
            } else {
                destination = "copy saved"
            }
            return "\(original) → \(output) · \(reduction)% smaller · \(destination)"
        case .unchanged:
            return result.message ?? "No smaller copy created · original kept"
        case .failed:
            return result.message.map { "Original kept · \($0)" } ?? "Original kept · compression failed"
        }
    }

    private func clearFinishedItems() {
        let finishedURLs = selectedURLs.filter { status(for: $0) == .compressed || status(for: $0) == .unchanged }
        let finishedPaths = Set(finishedURLs.map { queueKey(for: $0) })
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            selectedURLs.removeAll { finishedPaths.contains(queueKey(for: $0)) }
            activeBatchURLs.removeAll { finishedPaths.contains(queueKey(for: $0)) }
            itemStatuses = itemStatuses.filter { !finishedPaths.contains($0.key) }
            itemResults = itemResults.filter { !finishedPaths.contains($0.key) }
            fileByteCounts = fileByteCounts.filter { !finishedPaths.contains($0.key) }
        }
        persistRecoveryState()
    }

    private func clearQueue() {
        guard !isCompressing else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            selectedURLs.removeAll()
            itemStatuses.removeAll()
            itemResults.removeAll()
            fileByteCounts.removeAll()
        }
        activeBatchURLs.removeAll()
        batchCompletedCount = 0
        initialVideoCount = 0
        initialImageCount = 0
        activeVideoWorkCount = 0
        activeImageWorkCount = 0
        finalStatusMessage = ""
        showCompletionFeedback = false
        batchStartedAt = nil
        recoveryURLs = []
        isUserPaused = false
        isDiskSpacePaused = false
        RecoveryStore.clear()
    }

    private func isCancellationMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("cancel") || lowercased.contains("stopping safely")
    }

    private func queueSummary(for urls: [URL]) -> String {
        var videos = 0
        var waiting = 0
        var compressing = 0
        var compressed = 0
        var unchanged = 0
        var failed = 0
        for url in urls {
            if isVideo(url) { videos += 1 }
            switch status(for: url) {
            case .waiting: waiting += 1
            case .compressing: compressing += 1
            case .compressed: compressed += 1
            case .unchanged: unchanged += 1
            case .failed: failed += 1
            }
        }
        let images = urls.count - videos
        var parts: [String] = [pluralized(urls.count, singular: "item")]
        if images > 0 { parts.append(pluralized(images, singular: "image")) }
        if videos > 0 { parts.append(pluralized(videos, singular: "video")) }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if compressing > 0 { parts.append("\(compressing) processing") }
        if compressed > 0 { parts.append("\(compressed) compressed") }
        if unchanged > 0 { parts.append("\(unchanged) kept") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    private func pluralized(_ count: Int, singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }
}

struct MixedCompressorView_Previews: PreviewProvider {
    static var previews: some View { MixedCompressorView().frame(width: 760, height: 760) }
}
