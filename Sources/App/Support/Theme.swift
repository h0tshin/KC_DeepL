import SwiftUI

enum AppTheme {
    static let panelBackground = Color(nsColor: NSColor(calibratedWhite: 0.125, alpha: 1))
    static let elevatedBackground = Color(nsColor: NSColor(calibratedWhite: 0.19, alpha: 1))
    static let toolbarBackground = panelBackground
    static let controlBackground = Color(nsColor: NSColor(calibratedWhite: 0.205, alpha: 1))
    static let separator = Color.white.opacity(0.09)
    static let panelBorder = Color.white.opacity(0.10)
    static let accent = Color(nsColor: NSColor.systemBlue)
    static let selectedTitlebarBackground = Color(nsColor: NSColor(calibratedRed: 0.82, green: 0.9, blue: 1, alpha: 1))
    static let selectedTitlebarForeground = Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.28, blue: 0.56, alpha: 1))
    static let success = Color(nsColor: NSColor.systemGreen)
}

extension View {
    func compactIconButton() -> some View {
        buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(AppTheme.controlBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}
