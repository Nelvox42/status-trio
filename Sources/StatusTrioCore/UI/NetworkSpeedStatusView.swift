import SwiftUI

/// The status panel's network speed row.
///
/// Read-only, like the CPU and memory row: no chevron and no control.
struct NetworkSpeedStatusView: View {
    let state: NetworkSpeedPanelState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PanelSymbolView(
                source: .symbol(name: "arrow.up.arrow.down", variableValue: nil, fallback: nil)
            )
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.title)
        .accessibilityValue(state.accessibilityValue)
    }
}
