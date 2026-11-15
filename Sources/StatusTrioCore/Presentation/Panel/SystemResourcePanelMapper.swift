import Foundation

/// Pure mapping from the sampler's reading to the panel's presentation.
@MainActor
enum SystemResourcePanelMapper {
    /// Shown for a half the machine has not reported yet; a fabricated `0` would
    /// read as a real measurement.
    static let placeholder = "—"

    static func map(
        _ status: SystemResourceStatus?,
        localization: Localization
    ) -> SystemResourcePanelState {
        let locale = localization.resolvedLanguage.locale
        let hasReading = status?.hasReading ?? false
        let cpuText = status?.cpuUsage.map {
            $0.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        }
        let usedText = hasReading ? status.map { formatBytes($0.usedMemoryBytes, locale: locale) } : nil
        let totalText = hasReading ? status.map { formatBytes($0.totalMemoryBytes, locale: locale) } : nil

        let cpuPart = "\(localization.string(.systemResourceCpu)) \(cpuText ?? placeholder)"
        let memoryPart: String
        if let usedText, let totalText {
            memoryPart = "\(localization.string(.systemResourceMemory)) \(usedText) / \(totalText)"
        } else {
            memoryPart = "\(localization.string(.systemResourceMemory)) \(placeholder)"
        }
        let subtitle = "\(cpuPart) · \(memoryPart)"

        let accessibilityValue: String
        if let cpuText, let usedText, let totalText {
            accessibilityValue = String(
                format: localization.string(.systemResourceAccessibility),
                locale: locale,
                arguments: [cpuText, usedText, totalText]
            )
        } else {
            accessibilityValue = subtitle
        }

        let memoryFraction: Double?
        if hasReading, let status, status.totalMemoryBytes > 0 {
            memoryFraction = Double(status.usedMemoryBytes) / Double(status.totalMemoryBytes)
        } else {
            memoryFraction = nil
        }

        return SystemResourcePanelState(
            title: localization.string(.systemResourceTitle),
            subtitle: subtitle,
            accessibilityValue: accessibilityValue,
            cpuFraction: status?.cpuUsage,
            memoryFraction: memoryFraction
        )
    }

    /// Decimal units so a 16 GB Mac reports "16 GB"; Activity Monitor's memory
    /// figures use the same convention, which is what the reader compares against.
    private static func formatBytes(_ bytes: UInt64, locale: Locale) -> String {
        bytes.formatted(.byteCount(style: .decimal).locale(locale))
    }
}
