import SwiftUI

enum AppTheme {
    static let titlebarNSColor = sRGBColor(red: 31, green: 31, blue: 31)
    static let panelNSColor = sRGBColor(red: 45, green: 45, blue: 45)
    static let statusBarNSColor = sRGBColor(red: 64, green: 64, blue: 64)

    static let titlebarBackground = Color(nsColor: titlebarNSColor)
    static let panelBackground = Color(nsColor: panelNSColor)
    static let elevatedBackground = Color(nsColor: statusBarNSColor)
    static let toolbarBackground = panelBackground
    static let controlBackground = Color(nsColor: NSColor(calibratedWhite: 0.205, alpha: 1))
    static let separator = Color.white.opacity(0.09)
    static let panelBorder = Color.white.opacity(0.10)
    static let accent = Color(nsColor: NSColor.systemBlue)
    static let selectedTitlebarBackground = Color(nsColor: NSColor(calibratedRed: 0.82, green: 0.9, blue: 1, alpha: 1))
    static let selectedTitlebarForeground = Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.28, blue: 0.56, alpha: 1))
    static let success = Color(nsColor: NSColor.systemGreen)

    private static func sRGBColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSColor {
        NSColor(
            srgbRed: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: 1
        )
    }
}

extension View {
    func compactIconButton() -> some View {
        buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(AppTheme.controlBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}
