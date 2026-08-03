import SwiftUI

struct TranslationEngineSwitch: View {
    let selectedEngine: TranslationResultEngine
    let onSelect: (TranslationResultEngine) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TranslationResultEngine.allCases) { engine in
                Button {
                    onSelect(engine)
                } label: {
                    Text(engine.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            selectedEngine == engine ? .primary : .secondary
                        )
                        .frame(width: 38, height: 28)
                        .background(
                            selectedEngine == engine
                                ? Color.white.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .help("\(engine.displayName) 번역 결과 보기")
                .accessibilityLabel("\(engine.displayName) 번역 결과")
                .accessibilityAddTraits(
                    selectedEngine == engine ? .isSelected : []
                )
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppTheme.panelBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("번역 엔진 선택")
    }
}
