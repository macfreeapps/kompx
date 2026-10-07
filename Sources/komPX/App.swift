import SwiftUI
import AppKit

@main
struct komPXApp: App {
    init() {
        CompletionNotificationManager.shared.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 680)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage("autoCompressOnDrop") private var autoCompressOnDrop = false
    @AppStorage("compressionQuality") private var selectedQualityValue = CompressionQuality.balanced.rawValue
    @AppStorage("imageOutputFormat") private var imageOutputFormatValue = ImageOutputFormatChoice.heic.rawValue
    @AppStorage("outputLocation") private var outputLocationValue = OutputLocation.sameAsSource.rawValue
    @AppStorage("customOutputDirectoryPath") private var customOutputDirectoryPath = ""
    @AppStorage("useCompressedSuffix") private var addCompressedSuffix = false
    @AppStorage("keepScreenAwakeWhileProcessing") private var keepScreenAwakeWhileProcessing = false

    private let accent = Color(red: 0.31, green: 0.28, blue: 0.72)

    var body: some View {
        Form {
            Section {
                Picker("Compression quality", selection: $selectedQualityValue) {
                    ForEach(CompressionQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if let selectedQuality = CompressionQuality(rawValue: selectedQualityValue) {
                    Text(selectedQuality.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }

                Picker("Image output", selection: $imageOutputFormatValue) {
                    ForEach(ImageOutputFormatChoice.allCases) { format in
                        Text(format.rawValue).tag(format.rawValue)
                    }
                }

                if let selectedFormat = ImageOutputFormatChoice(rawValue: imageOutputFormatValue) {
                    Text(selectedFormat.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }

                Picker("Save location", selection: $outputLocationValue) {
                    Text("Same folder as each original").tag(OutputLocation.sameAsSource.rawValue)
                    Text("Custom folder…").tag(OutputLocation.custom.rawValue)
                }

                if selectedOutputLocation == .custom {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                        Text(customOutputDirectoryPath.isEmpty ? "Choose an output folder" : customOutputDirectoryPath)
                            .font(.caption)
                            .foregroundStyle(customOutputDirectoryPath.isEmpty ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(customOutputDirectoryPath)
                        Spacer(minLength: 8)
                        Button("Choose…", action: selectCustomFolder)
                    }
                }

                Toggle(isOn: $addCompressedSuffix) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add _compressed suffix")
                        Text(addCompressedSuffix
                             ? "Keep originals and save a new verified copy."
                             : "Save a verified result in place when using the same folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .help("Turn this on to keep the original and save a new file with _compressed in its name.")
            } header: {
                Label("Export settings", systemImage: "slider.horizontal.3")
            } footer: {
                Text("The same settings apply to every image and video in a queue. HEIC is recommended for smaller, high-quality image files.")
            }

            Section {
                Toggle("Auto-compress when dropping files", isOn: $autoCompressOnDrop)
                    .help("Automatically start compression after dragging and dropping files into the app.")
            } header: {
                Label("Workflow", systemImage: "arrow.triangle.2.circlepath")
            }

            Section {
                Toggle("Wake the screen while processing", isOn: $keepScreenAwakeWhileProcessing)
                    .help("Prevent the display from sleeping while komPX is processing media.")
                Text("The display will return to its normal sleep behavior as soon as the queue finishes or is cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Power", systemImage: "sun.max.fill")
            }

            Section {
                Label("Verified overwrite or copy", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.secondary)
                Text("Same-folder mode saves a readable, smaller result before moving the original to Trash. Files are processed top-to-bottom with a 75% live-available-RAM target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Safety", systemImage: "lock.shield.fill")
            }

            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent.gradient)
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .accessibilityHidden(true)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("komPX")
                            .font(.headline)
                        Text("Media compressor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildVersion)
                Text("Made by @tarudesu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("About", systemImage: "info.circle.fill")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 540, height: 560)
    }

    private var selectedOutputLocation: OutputLocation {
        OutputLocation(rawValue: outputLocationValue) ?? .sameAsSource
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Output Folder"

        guard panel.runModal() == .OK, let url = panel.url else {
            if customOutputDirectoryPath.isEmpty {
                outputLocationValue = OutputLocation.sameAsSource.rawValue
            }
            return
        }
        customOutputDirectoryPath = url.path
    }
}
