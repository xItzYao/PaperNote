import UIKit
import PDFKit
import Vision

/// 文字辨識出的一行字，rect 為頁面內容座標
struct OCRLine {
    let text: String
    let rect: CGRect
}

// MARK: - 掃描檔 PDF 的文字選取（用 Vision 文字辨識）

extension NotebookViewController {
    func pageHasPDFText(_ i: Int) -> Bool {
        let page = pages[i]
        if let cached = pageHasTextCache[page.id] { return cached }
        let has = !(session.pdfPage(for: page)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        pageHasTextCache[page.id] = has
        return has
    }

    /// 選取 docRect 範圍內辨識出的文字行；還沒辨識過就先辨識
    func selectRecognizedText(pageIndex i: Int, docRect: CGRect) {
        guard pages.indices.contains(i) else { return }
        let pageID = pages[i].id
        if let lines = ocrCache[pageID] {
            applyOCRSelection(lines, pageIndex: i, docRect: docRect)
            return
        }
        showToast("這頁沒有文字層，正在辨識文字…")
        guard !ocrInFlight.contains(pageID) else { return }
        ocrInFlight.insert(pageID)
        recognizePage(i) { [weak self] lines in
            guard let self else { return }
            self.ocrInFlight.remove(pageID)
            self.ocrCache[pageID] = lines
            guard let idx = self.pageIndex(of: pageID) else { return }
            if lines.isEmpty {
                self.overlay.showTextRects([])
                self.showToast("這頁辨識不到文字")
            } else {
                self.applyOCRSelection(lines, pageIndex: idx, docRect: docRect)
            }
        }
    }

    private func applyOCRSelection(_ lines: [OCRLine], pageIndex i: Int, docRect: CGRect) {
        let o = contentOrigin(i)
        let target = docRect.insetBy(dx: -4, dy: -4)
        let hit = lines.filter { $0.rect.offsetBy(dx: o.x, dy: o.y).intersects(target) }
            .sorted { abs($0.rect.minY - $1.rect.minY) > 4 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        guard !hit.isEmpty else {
            clearTextSelection()
            let n = session.pdfPage(for: pages[i])?.numberOfCharacters ?? 0
            showToast("這裡沒有辨識到文字（此頁 PDF 文字 \(n) 字、辨識 \(lines.count) 行）")
            return
        }
        let rects = hit.map { $0.rect.offsetBy(dx: o.x, dy: o.y) }
        let ts = TextSelectionState(pageIndex: i, text: hit.map(\.text).joined(separator: "\n"), docRects: rects)
        textSelection = ts
        overlay.showTextRects(rects)
        presentTextMenu(ts)
    }

    /// 把頁面（不含筆跡）畫成圖片後辨識
    private func recognizePage(_ i: Int, completion: @escaping ([OCRLine]) -> Void) {
        let page = pages[i]
        let full = session.fullSize(of: page)
        let scale = min(3, 3000 / max(full.width, full.height, 1))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: full, format: fmt).image { rc in
            PageRenderer.drawPageWithoutInk(page, session: session, in: rc.cgContext)
        }
        guard let cg = img.cgImage else { completion([]); return }
        let insets = page.insets
        let request = VNRecognizeTextRequest { req, _ in
            let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
            let lines: [OCRLine] = obs.compactMap { o in
                guard let text = o.topCandidates(1).first?.string else { return nil }
                let b = o.boundingBox   // 正規化座標，原點在左下
                let r = CGRect(x: b.minX * full.width - insets.left,
                               y: (1 - b.maxY) * full.height - insets.top,
                               width: b.width * full.width, height: b.height * full.height)
                return OCRLine(text: text, rect: r)
            }
            DispatchQueue.main.async { completion(lines) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let wanted = ["zh-Hant", "zh-Hans", "en-US", "ja-JP"]
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = wanted.filter { supported.contains($0) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
            } catch {
                DispatchQueue.main.async { completion([]) }
            }
        }
    }

    // MARK: - PDF 選字的備用方法

    func robustWordSelection(_ pdf: PDFPage, pageID: UUID, at p: CGPoint) -> PDFSelection? {
        if let s = pdf.selectionForWord(at: p), let str = s.string,
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        guard let i = nearestCharIndex(pdf, pageID: pageID, p) else { return nil }
        let r = pdf.characterBounds(at: i)
        if let s = pdf.selectionForWord(at: CGPoint(x: r.midX, y: r.midY)), let str = s.string,
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        return pdf.selection(for: NSRange(location: i, length: 1))
    }

    /// 離 p（PDF 頁面座標）最近的字元，太遠（> 40pt）就算沒有
    func nearestCharIndex(_ pdf: PDFPage, pageID: UUID, _ p: CGPoint) -> Int? {
        let direct = pdf.characterIndex(at: p)
        if direct >= 0 && direct != NSNotFound && direct < pdf.numberOfCharacters { return direct }
        let rects: [CGRect]
        if let cached = charRectCache[pageID] {
            rects = cached
        } else {
            rects = (0..<pdf.numberOfCharacters).map { pdf.characterBounds(at: $0) }
            charRectCache[pageID] = rects
        }
        var best: Int?
        var bestD = CGFloat.greatestFiniteMagnitude
        for (k, r) in rects.enumerated() where !r.isEmpty {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            let d = hypot(dx, dy)
            if d < bestD {
                bestD = d
                best = k
            }
        }
        return bestD <= 40 ? best : nil
    }

    // MARK: - 提示訊息

    func showToast(_ text: String) {
        view.viewWithTag(9_001)?.removeFromSuperview()
        let label = PaddedLabel()
        label.tag = 9_001
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak label] in
            UIView.animate(withDuration: 0.3, animations: { label?.alpha = 0 }) { _ in label?.removeFromSuperview() }
        }
    }
}

final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height + 16)
    }
}
