import SwiftUI

struct TranslationProgressView: View {
    var current: Int = 0
    var total: Int = 0
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if total > 0 {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                Text(String(localized: "正在翻译… \(current)/\(total)"))
                    .font(.body)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                Text(String(localized: "正在翻译…"))
                    .font(.body)
            }

            Button(String(localized: "取消")) {
                onCancel?()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(24)
        .frame(width: 360)
    }
}
