import SwiftUI

/// Shared quota and remaining-time presentation for the popover.
struct MetricBar: View {
    let label: String
    let value: Double?
    let tint: Color
    let symbol: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label(label, systemImage: symbol)
                Spacer()
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .monospacedDigit()
            }
            .font(.caption)

            ProgressView(value: value ?? 0, total: 100)
                .tint(tint)
                // AppKit reuses this native control across appearance changes
                // and can reset its tint. Recreate it so SwiftUI reapplies tint.
                .id(colorScheme)
                .opacity(value == nil ? 0.25 : 1)
        }
        .accessibilityElement(children: .combine)
    }
}
