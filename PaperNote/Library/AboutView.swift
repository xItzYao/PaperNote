import SwiftUI

/// 關於我＋贊助連結＋GitHub
struct AboutView: View {
    static let supportURL = URL(string: "https://buymeacoffee.com/happytw")!
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
                        Text("大學生，喜歡或是想支持我可以透過這個連結贊助窮苦大學生 :P")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                Section {
                    Link(destination: Self.supportURL) {
                        Label("請我喝杯咖啡（Buy Me a Coffee）", systemImage: "cup.and.saucer.fill")
                    }
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
