import SwiftUI
import UIKit

/// 選紙張：畫面中間的小視窗，可以預覽每種紙、選直式或橫式；點旁邊取消。
/// 新增筆記本、新增頁面（拉過最後一頁、在此頁前／後新增）都用這個
struct PaperPickerOverlay: View {
    let title: String
    let confirmTitle: String
    /// 要不要輸入名稱（新增筆記本）
    let askName: Bool
    @State var style: PaperStyle
    @State var landscape: Bool
    let onConfirm: (_ name: String, _ style: PaperStyle, _ landscape: Bool) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.3 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityIdentifier("paperPickerBackdrop")
            card
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.18)) { appeared = true } }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Text(title).font(.headline)
            if askName {
                TextField("筆記本名稱", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(PaperStyle.allCases) { s in
                    Button { style = s } label: {
                        VStack(spacing: 6) {
                            Image(uiImage: PageRenderer.paperPreview(s, landscape: landscape))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: landscape ? 92 : 66, height: landscape ? 66 : 92)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(style == s ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: style == s ? 3 : 1))
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            Text(s.title)
                                .font(.caption)
                                .foregroundStyle(style == s ? Color.accentColor : Color.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("紙張 \(s.title)")
                    .accessibilityAddTraits(style == s ? .isSelected : [])
                }
            }
            .animation(.easeInOut(duration: 0.15), value: landscape)
            Picker("方向", selection: $landscape) {
                Label("直式", systemImage: "rectangle.portrait").tag(false)
                Label("橫式", systemImage: "rectangle").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button(confirmTitle) {
                    onConfirm(name.trimmingCharacters(in: .whitespacesAndNewlines), style, landscape)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    }
}

extension PageRenderer {
    /// 紙張的縮圖（A4 比例，和真的頁面用同一套畫法）
    static func paperPreview(_ style: PaperStyle, landscape: Bool) -> UIImage {
        let page = landscape ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842)
        let scale: CGFloat = 0.25
        let size = CGSize(width: page.width * scale, height: page.height * scale)
        return UIGraphicsImageRenderer(size: size).image { rc in
            let ctx = rc.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            let full = CGRect(origin: .zero, size: page)
            drawPaper(style, in: full, visible: full, ctx: ctx)
        }
    }
}

extension NotebookViewController {
    /// 打開選紙張的小視窗，選好後在 index 插入新頁面。預設是參考頁（前一頁）的紙張與方向
    func presentPaperPicker(title: String, insertAt index: Int) {
        guard !pages.isEmpty else { return }
        let ref = pages[min(max(0, index - 1), pages.count - 1)]
        var style: PaperStyle = .blank
        if case let .paper(_, _, s) = ref.background { style = s }
        let size = session.baseSize(of: ref)
        weak var host: UIHostingController<PaperPickerOverlay>?
        let picker = PaperPickerOverlay(title: title, confirmTitle: "新增", askName: false, style: style,
                                        landscape: size.width > size.height,
                                        onConfirm: { [weak self] _, s, l in
                                            host?.dismiss(animated: true)
                                            self?.insertPage(at: index, style: s, landscape: l)
                                        },
                                        onCancel: { host?.dismiss(animated: true) })
        let h = UIHostingController(rootView: picker)
        h.modalPresentationStyle = .overFullScreen
        h.modalTransitionStyle = .crossDissolve
        h.view.backgroundColor = .clear
        host = h
        present(h, animated: false)
    }

    /// 在 index 插入一頁：大小和參考頁一樣，方向照選的（直式＝窄邊在上）
    func insertPage(at index: Int, style: PaperStyle, landscape: Bool) {
        guard !pages.isEmpty else { return }
        let ref = pages[min(max(0, index - 1), pages.count - 1)]
        let size = session.baseSize(of: ref)
        let short = min(size.width, size.height), long = max(size.width, size.height)
        let w = landscape ? long : short, h = landscape ? short : long
        let newPage = Page(background: .paper(width: w, height: h, style: style))
        let at = min(max(0, index), pages.count)
        performLayoutChange {
            session.document.pages.insert(newPage, at: at)
        }
        scrollToPage(at, animated: true)
    }
}
