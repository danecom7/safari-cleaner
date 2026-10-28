import SwiftUI

struct Report: Sendable {
    var title: String
    var testMode = true
    var facts: [String] = []
    var items: [ScanItem] = []
    var notes: [String] = []

    var freedBytes: Int64 { items.filter(\.countsAsFreed).reduce(0) { $0 + $1.bytes } }
    var freedFiles: Int { items.filter(\.countsAsFreed).reduce(0) { $0 + $1.files } }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ReportView: View {
    let report: Report
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title).font(.title2.bold())
            if report.testMode {
                Label("Тестовый режим: ничего не удалено. Ниже показано, что будет удалено в обычном режиме.",
                      systemImage: "eye")
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("\(report.testMode ? "Освободится" : "Освобождено"): \(Report.format(report.freedBytes)) · файлов: \(report.freedFiles)")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(report.facts, id: \.self) { Text($0) }
                    if !report.items.isEmpty {
                        Text("Что именно").font(.headline)
                        ForEach(report.items) { ItemRow(item: $0) }
                    }
                    if !report.notes.isEmpty {
                        Text("Важно знать").font(.headline)
                        ForEach(report.notes, id: \.self) { Text("• " + $0).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Закрыть", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }
}

private struct ItemRow: View {
    let item: ScanItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.label)
                Spacer()
                Text(status).foregroundStyle(item.status == .found ? .primary : Color.orange)
            }
            Text(item.url.path + (item.contentsOnly ? "/  (сама папка остаётся)" : ""))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch item.status {
        case .found: item.files > 0 ? "\(Report.format(item.bytes)) · файлов: \(item.files)" : Report.format(item.bytes)
        case .missing: "нет на этом Mac"
        case .noAccess: "нет доступа"
        case .refused: "пропущено защитой"
        }
    }
}
