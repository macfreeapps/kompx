import SwiftUI

struct FancyProgressBar: View {
    var progress: Double // 0.0 to 1.0
    var gradientColors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 14)

                // Progress fill with glow
                Capsule()
                    .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geometry.size.width * CGFloat(progress)), height: 14)
                    .shadow(color: gradientColors.last?.opacity(0.6) ?? .clear, radius: 8, x: 0, y: 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: progress)
            }
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Compression progress")
        .accessibilityValue("\(Int(max(0, min(1, progress)) * 100)) percent")
    }
}
