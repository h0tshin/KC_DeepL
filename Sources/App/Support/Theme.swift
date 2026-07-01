import SwiftUI

enum AppTheme {
    static let panelBackground = Color(nsColor: NSColor(calibratedWhite: 0.145, alpha: 1))
    static let elevatedBackground = Color(nsColor: NSColor(calibratedWhite: 0.19, alpha: 1))
    static let controlBackground = Color(nsColor: NSColor(calibratedWhite: 0.24, alpha: 1))
    static let separator = Color.white.opacity(0.09)
    static let panelBorder = elevatedBackground
    static let accent = Color(nsColor: NSColor.systemBlue)
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
