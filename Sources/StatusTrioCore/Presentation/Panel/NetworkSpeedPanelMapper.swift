import Foundation

/// Pure mapping from the sampler's reading to the network speed row.
@MainActor
enum NetworkSpeedPanelMapper {
    /// Shown for a direction the sampler has not measured yet.
    static let placeholder = "—"

    static func map(
        _ reading: NetworkThroughputReading?,
        localization: Localization
    ) -> NetworkSpeedPanelState {
        let locale = localization.resolvedLanguage.locale
        let up = rateText(reading?.sentBytesPerSecond, locale: locale) ?? placeholder
        let down = rateText(reading?.receivedBytesPerSecond, locale: locale) ?? placeholder

        return NetworkSpeedPanelState(
            title: localization.string(.networkSpeedTitle),
            subtitle: "↑ \(up) · ↓ \(down)",
            accessibilityValue: localization.format(.networkSpeedAccessibility, up, down)
        )
    }

    /// Decimal units, because network rates are conventionally powers of 1000,
    /// with a plain `/s` suffix. A non-finite or negative rate has no display.
    private static func rateText(_ rate: Double?, locale: Locale) -> String? {
        guard let rate, rate.isFinite, rate >= 0 else { return nil }
        let style = ByteCountFormatStyle(
            style: .decimal,
            allowedUnits: .all,
            spellsOutZero: false
        )
        // A finite rate can still exceed `Int64` for an absurd injected clock; clamp
        // it to a display ceiling rather than trapping.
        let bytes = min(rate.rounded(), 1e15)
        return Int64(bytes).formatted(style.locale(locale)) + "/s"
    }
}
