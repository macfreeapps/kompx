import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var diskSpaceMonitor = DiskSpaceMonitor()
    @State private var isShowingEmptyTrashConfirmation = false
    @State private var isShowingTrashError = false
    @State private var isTrashPermissionError = false
    @State private var trashErrorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .accessibilityHidden(true)
                    Text("komPX")
                }
                .font(.headline.weight(.bold))
                Spacer()
                Text("Media compressor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 10)

            DiskSpaceBar(
                availableBytes: diskSpaceMonitor.availableBytes,
                totalBytes: diskSpaceMonitor.totalBytes,
                emptyTrash: { isShowingEmptyTrashConfirmation = true }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            MixedCompressorView(requestEmptyTrash: { isShowingEmptyTrashConfirmation = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 680, idealHeight: 780)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Empty Trash?", isPresented: $isShowingEmptyTrashConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) { emptyTrash() }
        } message: {
            Text("Items currently in the Trash will be permanently removed.")
        }
        .alert("Couldn’t Empty Trash", isPresented: $isShowingTrashError) {
            if isTrashPermissionError {
                Button("Open System Settings") { TrashManager.openAutomationSettings() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(trashErrorMessage)
        }
    }

    private func emptyTrash() {
        do {
            try TrashManager.emptyTrash()
            diskSpaceMonitor.refresh()
        } catch {
            isTrashPermissionError = TrashManager.isAutomationPermissionError(error)
            trashErrorMessage = error.localizedDescription
            isShowingTrashError = true
        }
    }
}

struct DiskSpaceBar: View {
    let availableBytes: Int64?
    let totalBytes: Int64?
    let emptyTrash: () -> Void

    private var availableRatio: Double {
        guard let availableBytes, let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(availableBytes) / Double(totalBytes)))
    }

    private var isLowDiskSpace: Bool {
        availableRatio > 0 && availableRatio <= 0.15
    }

    private var isCriticalDiskSpace: Bool {
        availableRatio > 0 && availableRatio <= 0.08
    }

    private var diskColor: Color {
        if isCriticalDiskSpace { return .red }
        if isLowDiskSpace { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("Disk space", systemImage: "internaldrive.fill")
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 8)

                if let availableBytes, let totalBytes {
                    Label(
                        isLowDiskSpace ? "Low disk space" : "Healthy",
                        systemImage: isLowDiskSpace ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(diskColor)
                    .accessibilityLabel(isLowDiskSpace ? "Low disk space" : "Disk space healthy")
                    Text("\(storageString(availableBytes)) free of \(storageString(totalBytes))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Checking available space…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Empty Trash", systemImage: "trash", action: emptyTrash)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Permanently remove items from the Trash")
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(diskColor.gradient)
                        .frame(width: availableRatio > 0 ? max(6, geometry.size.width * availableRatio) : 0)
                }
            }
            .frame(height: 7)
            .accessibilityElement()
            .accessibilityLabel("Available disk space")
            .accessibilityValue(diskAccessibilityValue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var diskAccessibilityValue: String {
        guard let availableBytes, let totalBytes else { return "Checking" }
        return "\(storageString(availableBytes)) free of \(storageString(totalBytes))"
    }

    private func storageString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
