import SwiftUI

/// 表格「重複」：把選取的那幾列（欄）往上／下／左／右複製成好幾組，接成一個大表格；之後可以再改組數
struct TableRepeatPanel: View {
    /// 0 往上、1 往下、2 往左、3 往右
    @State var direction: Int
    @State var count: Int
    /// 正在改已經重複過的那一組
    let editing: Bool
    /// 方向 → 會重複哪幾列（欄），例如「第 3–4 列」
    let blockLabel: (Int) -> String
    let onApply: (_ direction: Int, _ count: Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing ? "修改重複的組數" : "重複選取的範圍").font(.headline)
            Text("把\(blockLabel(direction))複製成好幾組，接成一個大表格。之後可以再改組數，也可以拖曳選取範圍右下角的藍點。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("方向", selection: $direction) {
                Label("往上", systemImage: "arrow.up").tag(0)
                Label("往下", systemImage: "arrow.down").tag(1)
                Label("往左", systemImage: "arrow.left").tag(2)
                Label("往右", systemImage: "arrow.right").tag(3)
            }
            .pickerStyle(.segmented)
            Stepper(value: $count, in: 0...200) {
                HStack(spacing: 6) {
                    Text("複製")
                    TextField("組數", value: $count, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("組")
                }
            }
            HStack {
                if editing {
                    Button("移除複製的組", role: .destructive) { onApply(direction, 0) }
                }
                Spacer()
                Button("套用") { onApply(direction, min(max(count, 0), 200)) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }
}
