import SwiftUI

/// Statistics: GitHub-style lookup heatmap + per-dictionary efficiency.
///
/// Hit rate = of your logged lookups, how often the dictionary had the word.
/// Uses = explicit tab clicks (searches hit every dictionary automatically,
/// so only a click counts as actually consulting it).
struct StatsView: View {
    let vocab: VocabStore
    let store: DictionaryStore
    var onOrderChanged: () -> Void

    @State private var daily: [String: Int] = [:]
    @State private var totalLookups = 0
    @State private var rows: [Row] = []
    @State private var reordered = false

    struct Row: Identifiable {
        let id: String
        let title: String
        let hits: Int
        let uses: Int
        let hitRate: Double   // 0...1 of all logged lookups
        let verdict: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("查词热力图").font(.headline)
                HeatmapView(daily: daily)
                summaryLine

                Divider()

                HStack {
                    Text("词典效率").font(.headline)
                    Spacer()
                    Button(reordered ? "已按使用频率重排" : "按使用频率重排词典顺序") {
                        applyUsageOrder()
                    }
                    .disabled(reordered || rows.allSatisfy { $0.uses == 0 })
                    .help("使用次数多者靠前（并列时看命中率），排序会同步到 tab 与「全部」视图")
                }
                Text("命中率 = 你查过的词里该词典收录的比例；使用 = 你主动点它 tab 的次数（自动聚合查询不算）。命中高但从不点开的词典，说明它排太靠前也没被看——可以降级或移除；命中低又不用的，是清理空间的首选。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                dictTable
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
    }

    private var summaryLine: some View {
        let today = Self.dayString(Date())
        let last7 = (0..<7).reduce(0) { sum, offset in
            sum + (daily[Self.dayString(Date().addingTimeInterval(-Double(offset) * 86400))] ?? 0)
        }
        return Text("今天 \(daily[today] ?? 0) 次 · 近 7 天 \(last7) 次 · 历史累计 \(totalLookups) 次")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    private var dictTable: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(width: 200, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.06))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.55))
                                .frame(width: max(2, geo.size.width * row.hitRate))
                        }
                    }
                    .frame(height: 10)
                    Text(String(format: "%.0f%%", row.hitRate * 100))
                        .font(.system(size: 11)).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                    Text("\(row.uses) 次使用")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 66, alignment: .trailing)
                    Text(row.verdict)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Self.verdictColor(row.verdict).opacity(0.15), in: Capsule())
                        .foregroundColor(Self.verdictColor(row.verdict))
                        .frame(width: 110, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
            if rows.isEmpty {
                Text("还没有统计数据——查几个词、点几个词典 tab 之后再来看。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            }
        }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedDaily = vocab.dailyLookupCounts(days: 200)
            let loadedTotal = vocab.historyCount()
            let loadedStats = Dictionary(uniqueKeysWithValues: vocab.dictStats().map { ($0.dictID, $0) })
            DispatchQueue.main.async {
                daily = loadedDaily
                totalLookups = loadedTotal
                let denominator = max(1, loadedTotal)
                rows = store.dictionaries.map { dict in
                    let stat = loadedStats[dict.id]
                    let hits = stat?.hits ?? 0
                    let uses = stat?.uses ?? 0
                    let rate = Double(hits) / Double(denominator)
                    return Row(
                        id: dict.id, title: dict.displayTitle, hits: hits, uses: uses,
                        hitRate: min(1, rate), verdict: Self.verdict(hitRate: rate, uses: uses, total: loadedTotal)
                    )
                }
                .sorted { ($0.uses, $0.hits) > ($1.uses, $1.hits) }
                reordered = false
            }
        }
    }

    private func applyUsageOrder() {
        store.applyOrder(ids: rows.map(\.id)) // rows are already usage-sorted
        onOrderChanged()
        reordered = true
    }

    private static func verdict(hitRate: Double, uses: Int, total: Int) -> String {
        guard total >= 20 else { return "数据不足" }
        switch (hitRate, uses) {
        case (0.4..., 5...): return "主力词典"
        case (0.4..., 0): return "查得到但没在看"
        case (..<0.1, 0): return "可考虑移除"
        case (_, 0): return "少被使用"
        default: return "偶尔使用"
        }
    }

    private static func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "主力词典": return .green
        case "可考虑移除": return .red
        case "查得到但没在看": return .orange
        default: return .secondary
        }
    }

    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// GitHub-contributions-style grid: 26 weeks × 7 days, newest at right.
struct HeatmapView: View {
    let daily: [String: Int]

    private struct Cell: Identifiable {
        let id: Int
        let date: Date
        let count: Int
    }

    private var weeks: [[Cell?]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekdayOffset = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let totalCells = 25 * 7 + weekdayOffset + 1
        var cells: [Cell] = []
        for i in 0..<totalCells {
            let date = calendar.date(byAdding: .day, value: -(totalCells - 1 - i), to: today)!
            cells.append(Cell(id: i, date: date, count: daily[StatsView.dayString(date)] ?? 0))
        }
        var columns: [[Cell?]] = []
        var index = 0
        while index < cells.count {
            var week: [Cell?] = Array(cells[index..<min(index + 7, cells.count)])
            while week.count < 7 { week.append(nil) } // pad the current week
            columns.append(week)
            index += 7
        }
        return columns
    }

    var body: some View {
        let columns = weeks
        VStack(alignment: .leading, spacing: 3) {
            // month labels above the columns where a month starts
            HStack(spacing: 3) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                    Text(monthLabel(for: week, at: index, in: columns))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 13, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(color(for: cell?.count))
                                .frame(width: 13, height: 13)
                                .help(cell.map { "\(StatsView.dayString($0.date))：\($0.count) 次" } ?? "")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("少").font(.system(size: 9)).foregroundColor(.secondary)
                ForEach([0, 1, 3, 6, 10], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(color(for: level)).frame(width: 10, height: 10)
                }
                Text("多").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    private func monthLabel(for week: [Cell?], at index: Int, in columns: [[Cell?]]) -> String {
        guard let first = week.compactMap({ $0 }).first else { return "" }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: first.date)
        if index == 0 { return "\(month)月" }
        if let prev = columns[index - 1].compactMap({ $0 }).first,
           calendar.component(.month, from: prev.date) != month {
            return "\(month)月"
        }
        return ""
    }

    private func color(for count: Int?) -> Color {
        guard let count, count > 0 else { return Color.primary.opacity(0.07) }
        switch count {
        case 1...2: return Color.green.opacity(0.3)
        case 3...5: return Color.green.opacity(0.5)
        case 6...9: return Color.green.opacity(0.72)
        default: return Color.green.opacity(0.95)
        }
    }
}
