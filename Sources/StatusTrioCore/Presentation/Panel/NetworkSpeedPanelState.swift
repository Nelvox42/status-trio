import Foundation

/// Presentation-ready snapshot of the status panel's network speed row.
struct NetworkSpeedPanelState: Equatable, Sendable {
    let title: String
    let subtitle: String
    let accessibilityValue: String

    @MainActor
    static func empty(localization: Localization) -> NetworkSpeedPanelState {
        NetworkSpeedPanelMapper.map(nil, localization: localization)
    }
}
