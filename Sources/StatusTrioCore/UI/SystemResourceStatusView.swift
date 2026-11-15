import SwiftUI

/// The status panel's CPU and memory row.
///
/// Read-only by design: it has no chevron and no control, so the panel keeps its
/// grammar of "rows that open something" versus "rows that report something".
struct SystemResourceStatusView: View {
    let state: SystemResourcePanelState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PanelSymbolView(source: .symbol(name: "cpu", variableValue: nil, fallback: nil))
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
