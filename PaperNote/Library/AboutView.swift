import SwiftUI

/// 關於我
struct AboutView: View {
    static let blurb = L("大學生的一個用愛發電小project，希望大家用的開心！\n想支持的話也可以贊助這個app的運作:P")
    /// App Store 審查指南 5.1.1(i)：App 裡也要有隱私權政策的連結（和 App Store Connect 填的是同一個網址）
    static let privacyPolicyURL = URL(string: "https://github.com/xItzYao/PaperNote/blob/main/PRIVACY.md")!
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
                        Image("AboutPhoto")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.gray.opacity(0.25)))
                        Text("PaperNote").font(.title2.weight(.bold))
                        Text(Self.blurb)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                Section {
                    LabeledContent(L("版本"), value: version)
                    Link(L("隱私權政策"), destination: Self.privacyPolicyURL)
                }
            }
            .navigationTitle(L("關於我"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
        }
    }
}
