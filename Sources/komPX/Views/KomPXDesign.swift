import SwiftUI

enum CompressionItemStatus: Equatable {
    case waiting
    case compressing
    case compressed
    case unchanged
    case failed

    var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .compressing: return "Compressing"
        case .compressed: return "Compressed"
        case .unchanged: return "Original kept"
        case .failed: return "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .waiting: return "clock"
        case .compressing: return "arrow.triangle.2.circlepath"
        case .compressed: return "checkmark.circle.fill"
        case .unchanged: return "equal.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

struct CompressionStatusBadge: View {
    let status: CompressionItemStatus

    private var color: Color {
        switch status {
        case .waiting: return .secondary
        case .compressing: return .blue
        case .compressed: return .green
        case .unchanged: return .secondary
        case .failed: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .compressing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: status.systemImage)
            }
            Text(status.title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.11), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.title)")
    }
}

extension View {
    func komPXCardSurface() -> some View {
        self
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}
