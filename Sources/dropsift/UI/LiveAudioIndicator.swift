import SwiftUI

struct LiveAudioIndicator: View {
    let label: String
    let systemImage: String
    let samples: [Float]
    let tint: Color

    private var isDetected: Bool {
        samples.suffix(4).contains { $0 > 0.12 }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))

            HStack(alignment: .center, spacing: 1.5) {
                ForEach(samples.indices, id: \.self) { index in
                    let sample = min(max(samples[index], 0), 1)
                    Capsule()
                        .fill(
                            sample > 0.04
                                ? tint.opacity(0.82)
                                : Color.secondary.opacity(0.22)
                        )
                        .frame(
                            width: 2,
                            height: max(2, 3 + CGFloat(sample) * 13)
                        )
                }
            }
            .frame(width: 48, height: 16)

            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(isDetected ? tint : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            isDetected ? tint.opacity(0.07) : Color.primary.opacity(0.035),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    isDetected ? tint.opacity(0.2) : Color.primary.opacity(0.06)
                )
        }
        .animation(.linear(duration: 0.09), value: samples)
        .help("\(label): \(isDetected ? "audio detected" : "quiet")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isDetected ? "Audio detected" : "Quiet")
    }
}
