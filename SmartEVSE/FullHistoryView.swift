import SwiftUI

struct FullHistoryView: View {
    let history: [HistoryItem]
    let onClear: () -> Void
    let onExport: () -> Void
    let onImport: (_ data: Data?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(history) { item in
            HStack {
                Circle().fill(Color(hex: item.hex)).frame(width: 14, height: 14)
                if item.mode == .off, let kwh = item.chargedKWh {
                    Text("Off · \(String(format: "%.2f", kwh)) kWh")
                } else {
                    Text(item.mode.displayName)
                }
                Spacer()
                Text(item.date, style: .date)
                Text(item.date, style: .time).foregroundColor(.secondary)
            }
        }
        .navigationTitle("All History")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(role: .destructive) { onClear() } label: { Image(systemName: "trash") }
                Button { onExport() } label: { Image(systemName: "square.and.arrow.up") }
                Button { onImport(nil) } label: { Image(systemName: "square.and.arrow.down") }
            }
        }
    }
}
