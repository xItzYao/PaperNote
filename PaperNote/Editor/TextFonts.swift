import SwiftUI
import UIKit

/// 文字框可以選的字體。
/// 內建的三套中文字體是 SIL Open Font License（可以隨 App 散布，授權檔在 Resources/Fonts）；
/// 其他是 iOS 內建字體，App 沒有散布字型檔，只是請系統畫出來
enum TextFonts {
    struct Choice: Identifiable, Hashable {
        /// PostScript 名稱；nil＝系統預設
        var name: String?
        var title: String
        var id: String { name ?? "" }
    }

    /// 隨 App 內建的字型檔（OFL）
    static let bundled = ["LXGWWenKaiTC-Regular", "Iansui-Regular", "NotoSerifTC-Regular"]

    private static let all: [(String, [Choice])] = [
        (L("中文"), [
            Choice(name: nil, title: L("系統預設")),
            Choice(name: "PingFangTC-Regular", title: L("蘋方（黑體）")),
            Choice(name: "NotoSerifTC-Regular", title: L("思源宋體（明體）")),
            Choice(name: "LXGWWenKaiTC-Regular", title: L("霞鶩文楷（楷體）")),
            Choice(name: "Iansui-Regular", title: L("芫荽（手寫感）")),
        ]),
        (L("英文、數字"), [
            Choice(name: "HelveticaNeue", title: "Helvetica Neue"),
            Choice(name: "AvenirNext-Regular", title: "Avenir Next"),
            Choice(name: "Georgia", title: "Georgia"),
            Choice(name: "TimesNewRomanPSMT", title: "Times New Roman"),
            Choice(name: "Palatino-Roman", title: "Palatino"),
            Choice(name: "Baskerville", title: "Baskerville"),
            Choice(name: "CourierNewPSMT", title: "Courier New"),
            Choice(name: "Menlo-Regular", title: L("Menlo（等寬）")),
            Choice(name: "AmericanTypewriter", title: "American Typewriter"),
            Choice(name: "ChalkboardSE-Regular", title: "Chalkboard"),
            Choice(name: "Noteworthy-Light", title: "Noteworthy"),
            Choice(name: "MarkerFelt-Thin", title: "Marker Felt"),
            Choice(name: "SnellRoundhand", title: "Snell Roundhand"),
        ]),
    ]

    /// 這台裝置上真的有的字體
    static var sections: [(String, [Choice])] {
        all.map { ($0.0, $0.1.filter { c in c.name.map { UIFont(name: $0, size: 12) != nil } ?? true }) }
    }

    /// 找不到字體（例如備份還原到別的系統版本）就用系統字體，不會變成空白
    static func font(_ name: String?, size: CGFloat) -> UIFont {
        name.flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    private static let lastKey = "textFonts.last"

    /// 新的文字框沿用上次選的字體
    static var lastUsed: String? {
        get { UserDefaults.standard.string(forKey: lastKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }
}

/// 選字體：每一列用那個字體顯示，看得出差別
struct TextFontPicker: View {
    @State var selected: String?
    let onPick: (String?) -> Void
    let onDone: () -> Void

    private let sample = "永字八法 Aa 123"

    var body: some View {
        NavigationStack {
            List {
                ForEach(TextFonts.sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { choice in
                            Button {
                                selected = choice.name
                                onPick(choice.name)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sample).font(Font(TextFonts.font(choice.name, size: 20)))
                                        Text(choice.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected == choice.name {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(L("字體"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { onDone() } }
            }
        }
    }
}

extension NotebookViewController {
    func presentFontPicker(_ ref: ElementRef) {
        guard case let (pi, ei)? = locate(ref), case let .text(t) = pages[pi].elements[ei].content else { return }
        let picker = UIHostingController(rootView: TextFontPicker(selected: t.fontName, onPick: { [weak self] name in
            self?.setTextBoxFont(ref, name: name)
        }, onDone: { [weak self] in
            self?.dismiss(animated: true)
        }))
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }
}
