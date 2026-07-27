import AppKit
import KCDeepLCore
import SwiftUI

struct FontSizeControl: View {
    @Binding var readingFontSizeRaw: String

    private var readingFontSize: ReadingFontSize {
        ReadingFontSize.resolved(readingFontSizeRaw)
    }

    var body: some View {
        HStack(spacing: 0) {
            adjustmentButton(
                resourceName: "FontSizeDecrease",
                fallbackSystemName: "textformat.size.smaller",
                label: "글자 크기 줄이기",
                isEnabled: readingFontSize.canDecrease
            ) {
                readingFontSizeRaw = readingFontSize.decreased.rawValue
            }

            Divider()
                .frame(height: 16)

            adjustmentButton(
                resourceName: "FontSizeIncrease",
                fallbackSystemName: "textformat.size.larger",
                label: "글자 크기 늘리기",
                isEnabled: readingFontSize.canIncrease
            ) {
                readingFontSizeRaw = readingFontSize.increased.rawValue
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppTheme.panelBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("글자 크기 조절")
    }

    private func adjustmentButton(
        resourceName: String,
        fallbackSystemName: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            FontSizePNGIcon(
                resourceName: resourceName,
                fallbackSystemName: fallbackSystemName
            )
            .frame(width: 18, height: 18)
            .frame(width: 30, height: 28)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 0.9 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("\(label) · 현재 \(readingFontSize.points)pt")
        .accessibilityLabel(label)
        .accessibilityValue("현재 \(readingFontSize.points)포인트")
    }
}

private struct FontSizePNGIcon: View {
    let resourceName: String
    let fallbackSystemName: String

    var body: some View {
        Group {
            if let image = FontSizeIconResource.image(named: resourceName) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(.primary)
    }
}

enum FontSizeIconResource {
    static func image(named name: String) -> NSImage? {
        let candidates: [(Bundle, String?)] = [
            (.main, nil),
            (.module, nil),
            (.module, "Resources")
        ]

        for (bundle, subdirectory) in candidates {
            guard let url = bundle.url(
                forResource: name,
                withExtension: "png",
                subdirectory: subdirectory
            ),
            let image = NSImage(contentsOf: url)
            else {
                continue
            }

            image.isTemplate = true
            return image
        }

        return nil
    }
}
