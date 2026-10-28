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
    /// 可以選的大小（新增頁面時，旁邊那頁不是 A4／B5／Letter 的話，最前面多一個「同第 N 頁」）
    var sizes: [PaperSize] = PaperSize.presets
    @State var sizeIndex = 0
    let onConfirm: (_ name: String, _ style: PaperStyle, _ landscape: Bool, _ size: PaperSize) -> Void
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

    /// 現在選的大小和方向
    private var previewSize: CGSize {
        PaperSize.oriented(sizes[min(sizeIndex, sizes.count - 1)].size, landscape: landscape)
    }

    /// 縮圖的框：長邊 92pt，照紙張比例
    private var previewFrame: CGSize {
        let s = previewSize
        let k = 92 / max(s.width, s.height)
        return CGSize(width: s.width * k, height: s.height * k)
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
                            Image(uiImage: PageRenderer.paperPreview(s, size: previewSize))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: previewFrame.width, height: previewFrame.height)
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
            .animation(.easeInOut(duration: 0.15), value: sizeIndex)
            Picker("大小", selection: $sizeIndex) {
                ForEach(sizes.indices, id: \.self) { i in Text(sizes[i].title).tag(i) }
            }
            .pickerStyle(.segmented)
            Picker("方向", selection: $landscape) {
                Label("直式", systemImage: "rectangle.portrait").tag(false)
                Label("橫式", systemImage: "rectangle").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button(confirmTitle) {
                    onConfirm(name.trimmingCharacters(in: .whitespacesAndNewlines), style, landscape, sizes[min(sizeIndex, sizes.count - 1)])
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
    /// 紙張的縮圖（和真的頁面用同一套畫法）；size 是頁面大小（點）
    static func paperPreview(_ style: PaperStyle, size page: CGSize) -> UIImage {
        // 整數大小，邊緣才不會有半透明的像素
        let size = CGSize(width: (page.width / 4).rounded(), height: (page.height / 4).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { rc in
            let ctx = rc.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: size.width / page.width, y: size.height / page.height)
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
        let sizes = paperSizeOptions(like: ref)
        let picker = PaperPickerOverlay(title: title, confirmTitle: "新增", askName: false, style: style,
                                        landscape: size.width > size.height, sizes: sizes.options, sizeIndex: sizes.selected,
                                        onConfirm: { [weak self] _, s, l, paper in
                                            self?.dismiss(animated: true)
                                            self?.insertPage(at: index, style: s, landscape: l, size: paper)
                                        },
                                        onCancel: { [weak self] in self?.dismiss(animated: true) })
        let h = UIHostingController(rootView: picker)
        h.modalPresentationStyle = .overFullScreen
        h.modalTransitionStyle = .crossDissolve
        h.view.backgroundColor = .clear
        present(h, animated: false)
    }

    /// 新增頁面可以選的大小：A4／B5／Letter；旁邊那頁（例如匯入的 PDF）不是這三種的話，最前面多一個「同第 N 頁」並預設選它
    func paperSizeOptions(like ref: Page) -> (options: [PaperSize], selected: Int) {
        let size = PaperSize.oriented(session.baseSize(of: ref), landscape: false)
        if let i = PaperSize.presets.firstIndex(where: { abs($0.size.width - size.width) < 2 && abs($0.size.height - size.height) < 2 }) {
            return (PaperSize.presets, i)
        }
        let n = (pageIndex(of: ref.id) ?? 0) + 1
        return ([PaperSize(title: "同第 \(n) 頁", size: size)] + PaperSize.presets, 0)
    }

    /// 在 index 插入一頁：大小照選的（沒指定就和參考頁一樣），方向照選的（直式＝窄邊在上）
    func insertPage(at index: Int, style: PaperStyle, landscape: Bool, size paper: PaperSize? = nil) {
        guard !pages.isEmpty else { return }
        let ref = pages[min(max(0, index - 1), pages.count - 1)]
        let s = PaperSize.oriented(paper?.size ?? session.baseSize(of: ref), landscape: landscape)
        let newPage = Page(background: .paper(width: s.width, height: s.height, style: style))
        let at = min(max(0, index), pages.count)
        performLayoutChange {
            session.document.pages.insert(newPage, at: at)
        }
        scrollToPage(at, animated: true)
    }
}
