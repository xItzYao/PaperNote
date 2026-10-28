import SwiftUI

/// 關於我＋GitHub
struct AboutView: View {
    static let githubURL = URL(string: "https://github.com/xItzYao/PaperNote")!
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.accentColor)
                        Text("PaperNote").font(.title2.weight(.bold))
                        Text("一個大學生做的 iPad 筆記軟體，原始碼公開在 GitHub。")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                Section {
                    Link(destination: Self.githubURL) {
                        Label("GitHub 原始碼", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Section {
                    LabeledContent("版本", value: version)
                }
            }
            .navigationTitle("關於我")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
