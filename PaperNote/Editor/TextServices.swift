import UIKit
import SwiftUI
import Vision
import Translation
import NaturalLanguage

/// 系統翻譯、查詢、文字辨識
enum TextServices {
    /// 用 iPadOS 內建的翻譯面板翻譯文字。rect 是在 vc.view 座標中的錨點。
    static func translate(_ text: String, from vc: UIViewController, anchor rect: CGRect,
                          onInsert: ((String) -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 自己偵測原文語言再翻譯，結果可拷貝或插入成文字框。
        // 翻譯進行中如果視窗被關掉，系統的 TranslationSession 會讓 App 閃退，
        // 所以改用置中視窗，翻譯完成前不能點外面或下滑關閉。
        if vc.presentedViewController != nil { vc.dismiss(animated: false) }
        weak var hostRef: UIViewController?
        var insertHandler: ((String) -> Void)?
        if let onInsert {
            insertHandler = { result in
                hostRef?.dismiss(animated: true) { onInsert(result) }
            }
        }
        let panel = TranslatePanel(text: trimmed, onInsert: insertHandler) {
            hostRef?.dismiss(animated: true)
        }
        let host = UIHostingController(rootView: panel)
        host.modalPresentationStyle = .formSheet
        host.preferredContentSize = CGSize(width: 520, height: 460)
        host.isModalInPresentation = true
        hostRef = host
        vc.present(host, animated: true)
    }

    static func lookUp(_ text: String, from vc: UIViewController, anchor rect: CGRect) {
        let ref = UIReferenceLibraryViewController(term: text)
        ref.modalPresentationStyle = .popover
        ref.popoverPresentationController?.sourceView = vc.view
        ref.popoverPresentationController?.sourceRect = rect
        vc.present(ref, animated: true)
    }

    /// 用 Vision 辨識圖片中的文字（中、英、日）
    static func recognizeText(in image: UIImage, completion: @escaping (String) -> Void) {
        guard let cg = image.cgImage else { completion(""); return }
        let request = VNRecognizeTextRequest { req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
            DispatchQueue.main.async { completion(lines.joined(separator: "\n")) }
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
                DispatchQueue.main.async { completion("") }
            }
        }
    }
}

// MARK: - 翻譯面板（自動偵測語言）

struct TranslatePanel: View {
    let text: String
    let onInsert: ((String) -> Void)?
    let onClose: () -> Void

    static let languages: [(id: String, name: String)] = [
        ("zh-Hant", "繁體中文"), ("en", "英文"), ("ja", "日文"), ("zh-Hans", "簡體中文"),
        ("ko", "韓文"), ("fr", "法文"), ("de", "德文"), ("es", "西班牙文"),
    ]

    @AppStorage("translate.target") private var targetID = "zh-Hant"
    @State private var sourceID: String
    @State private var config: TranslationSession.Configuration?
    @State private var result: String?
    @State private var errorText: String?
    @State private var configKey = ""
    /// 萬一翻譯卡住，20 秒後還是可以關閉
    @State private var allowCloseAnyway = false

    private var busy: Bool { result == nil && errorText == nil }

    init(text: String, onInsert: ((String) -> Void)?, onClose: @escaping () -> Void) {
        self.text = text
        self.onInsert = onInsert
        self.onClose = onClose
        _sourceID = State(initialValue: Self.detect(text))
    }

    /// 用 NaturalLanguage 判斷原文語言
    static func detect(_ text: String) -> String {
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        guard let lang = rec.dominantLanguage, lang != .undetermined else { return "en" }
        switch lang {
        case .traditionalChinese: return "zh-Hant"
        case .simplifiedChinese: return "zh-Hans"
        default: return lang.rawValue
        }
    }

    private func name(_ id: String) -> String {
        Self.languages.first { $0.id == id }?.name ?? Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// 原文和目標相同時自動換一個目標
    private var effectiveTarget: String {
        if targetID == sourceID || (targetID.hasPrefix("zh") && sourceID.hasPrefix("zh")) {
            return sourceID.hasPrefix("zh") ? "en" : "zh-Hant"
        }
        return targetID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(Self.languages, id: \.id) { l in
                                Button(l.name) { sourceID = l.id }
                            }
                        } label: {
                            Label(name(sourceID), systemImage: "text.magnifyingglass")
                        }
                        .disabled(busy)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Menu {
                            ForEach(Self.languages, id: \.id) { l in
                                Button(l.name) { targetID = l.id }
                            }
                        } label: {
                            Label(name(effectiveTarget), systemImage: "globe")
                        }
                        .disabled(busy)
                    }
                    .font(.subheadline.weight(.semibold))

                    GroupBox {
                        Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    } label: {
                        Text("原文").font(.caption).foregroundStyle(.secondary)
                    }

                    GroupBox {
                        Group {
                            if let result {
                                Text(result).textSelection(.enabled)
                            } else if let errorText {
                                Text(errorText).foregroundStyle(.red)
                            } else {
                                HStack { ProgressView(); Text("翻譯中…").foregroundStyle(.secondary) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("譯文").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("翻譯")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { onClose() }
                        .disabled(busy && !allowCloseAnyway)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let result {
                        Button { UIPasteboard.general.string = result } label: { Label("拷貝譯文", systemImage: "doc.on.doc") }
                        if let onInsert {
                            Button { onInsert(result) } label: { Label("插入文字框", systemImage: "character.textbox") }
                        }
                    }
                }
            }
        }
        .translationTask(config) { session in
            do {
                let response = try await session.translate(text)
                result = response.targetText
            } catch {
                errorText = "無法翻譯：\(error.localizedDescription)\n可以到「設定 → App → 翻譯」下載語言，或換一個原文語言再試。"
            }
        }
        .onAppear {
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { allowCloseAnyway = true }
        }
        .onChange(of: targetID) { _, _ in start() }
        .onChange(of: sourceID) { _, _ in start() }
    }

    private func start() {
        result = nil
        errorText = nil
        let key = "\(sourceID)>\(effectiveTarget)"
        if config != nil && key == configKey {
            config?.invalidate()
        } else {
            configKey = key
            config = TranslationSession.Configuration(source: Locale.Language(identifier: sourceID),
                                                      target: Locale.Language(identifier: effectiveTarget))
        }
    }
}
