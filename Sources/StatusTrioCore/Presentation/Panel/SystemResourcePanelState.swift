import Foundation

/// Presentation-ready snapshot of the status panel's CPU and memory section.
///
/// Values are already localized and formatted; the row only lays them out.
struct SystemResourcePanelState: Equatable, Sendable {
    let title: String
    let subtitle: String
    let accessibilityValue: String
    /// CPU usage fraction in `0...1`, `nil` before the first delta exists.
    let cpuFraction: Double?
    /// Used-memory fraction in `0...1`, `nil` before the first read.
    let memoryFraction: Double?

    @MainActor
    static func empty(localization: Localization) -> SystemResourcePanelState {
        SystemResourcePanelMapper.map(nil, localization: localization)
    }
}
