import SwiftUI

/// 關於我
struct AboutView: View {
    static let blurb = "大學生的一個用愛發電小project，希望大家用的開心！\n想支持的話也可以贊助這個app的運作:P"
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
