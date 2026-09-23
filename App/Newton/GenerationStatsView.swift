import SwiftUI
import NewtonCore

/// Per-generation performance for the selected conversation. Bars plot the starting context
/// size (left scale, indigo); the overlaid line plots the average streamed token rate (right
/// scale, orange). The series have unrelated units, so each y axis is independently normalized
/// to its own maximum to share the plot area; both maxima are labeled in the series' color.
struct GenerationStatsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?
    @State private var plotSize: CGSize = .zero
    private struct Insets { let leading, trailing, top, bottom: CGFloat }
    private let insets = Insets(leading: 52, trailing: 52, top: 16, bottom: 30)
    private let plotHeightPoints: CGFloat = 250

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if records.isEmpty {
                        emptyState
                    } else {
                        legend
                        axisHeads
                        chart
                            .frame(height: plotHeightPoints)
                            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in plotSize = size }
                            .accessibilityLabel("Bar chart of starting context size with an overlaid average token-rate line for \(records.count) generations")
                        caption
                        detail
                    }
                }
                .padding(20)
            }
            .navigationTitle("Generation performance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // Data: the 40 most recent generations; all remain persisted, the note below says so.
    private var records: [GenerationRecord] { Array(model.selectedChat?.generations ?? []).suffix(40) }
    private var totalRecorded: Int { model.selectedChat?.generations?.count ?? 0 }
    private var maxContext: Int { max(1, records.map(\.contextSize).max() ?? 1) }
    private var maxRate: Double { max(0.1, records.map(\.averageTokensPerSecond).max() ?? 0) }

    private var plotRect: CGRect? {
        guard plotSize.width > insets.leading + insets.trailing + 1,
              plotSize.height > insets.top + insets.bottom + 1, !records.isEmpty else { return nil }
        return CGRect(x: insets.leading, y: insets.top,
                      width: plotSize.width - insets.leading - insets.trailing,
                      height: plotSize.height - insets.top - insets.bottom)
    }
    private var columnStep: CGFloat { guard let plot = plotRect else { return 0 }; return plot.width / CGFloat(max(1, records.count)) }
    private func columnCenter(_ index: Int) -> CGFloat { plotRect.map { $0.minX + columnStep * (CGFloat(index) + 0.5) } ?? 0 }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "chart.bar.doc").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No generations recorded yet.").font(.headline)
            Text("Each completed assistant reply stores its starting context size and average token rate. Send a message to populate this chart.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 24)
    }
    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Rectangle().fill(Color.indigo.opacity(0.45)).frame(width: 12, height: 12)
                Text("Starting context (tokens)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Capsule().fill(.orange).frame(width: 16, height: 4)
                Text("Avg token rate (tokens/sec)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
    private var axisHeads: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%d", maxContext)).font(.footnote.weight(.semibold)).foregroundStyle(Color.indigo)
                Text("tokens at start").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%.1f", maxRate)).font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                Text("avg tokens/sec").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var caption: some View {
        Group {
            if totalRecorded > records.count {
                Text("Showing the \(records.count) most recent of \(totalRecorded) generations.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        ZStack(alignment: .bottomLeading) {
            Canvas { ctx, _ in
                guard let plot = plotRect else { return }
                // Three spines: bottom axis shared by both series; left pairs with the bars,
                // right with the line, each to its own scale.
                let axes = Path { line in
                    line.move(to: CGPoint(x: plot.minX, y: plot.minY)); line.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                    line.move(to: CGPoint(x: plot.maxX, y: plot.minY)); line.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    line.move(to: CGPoint(x: plot.minX, y: plot.maxY)); line.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                }
                ctx.stroke(axes, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
                // Gridlines at 1/3 and 2/3 of the (common, normalized) height.
                for fraction in [1/3, 2/3] {
                    let y = plot.maxY - plot.height * CGFloat(fraction)
                    let grid = Path { line in
                        line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    ctx.stroke(grid, with: .color(Color.gray.opacity(0.18)), lineWidth: 1)
                }
                // Bars: starting context size, normalized to the left axis maximum.
                for (index, record) in records.enumerated() {
                    let center = columnCenter(index)
                    let height = plot.height * min(CGFloat(record.contextSize) / CGFloat(maxContext), 1)
                    var bar = Path()
                    bar.addRect(CGRect(x: center - columnStep * 0.31, y: plot.maxY - height, width: columnStep * 0.62, height: height))
                    ctx.fill(bar, with: .color(Color.indigo.opacity(selected == index ? 0.85 : 0.45)))
                }
                // Line: average token rate over time (generation), normalized to the right axis maximum.
                let points = records.enumerated().map { entry -> CGPoint in
                    let ratio = min(CGFloat(entry.element.averageTokensPerSecond / maxRate), 1)
                    return CGPoint(x: columnCenter(entry.offset), y: plot.minY + plot.height * (1 - ratio))
                }
                if points.count > 1 {
                    var polyline = Path()
                    polyline.addLines(points)
                    ctx.stroke(polyline, with: .color(.orange), lineWidth: 2.5)
                }
                for (index, point) in points.enumerated() {
                    let radius = selected == index ? 6.0 : 3.5
                    let disk = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: disk), with: .color(.orange))
                    if selected == index {
                        ctx.stroke(Path(ellipseIn: disk.insetBy(dx: -2.5, dy: -2.5)), with: .color(.white), lineWidth: 2)
                    }
                }
            }
            // One invisible button per generation column; tapping it selects that generation.
            ForEach(Array(records.indices), id: \.self) { index in
                Button { selected = index } label: {
                    Rectangle().fill(Color.white.opacity(0.001)).frame(width: columnStep, height: plotRect?.height ?? 0)
                }
                .offset(x: insets.leading + columnStep * CGFloat(index), y: -insets.bottom)
            }
            // Bottom ticks: a generation number every few columns (labelled every, axes labelled).
            ForEach(tickMarks, id: \.self) { index in
                Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                    .offset(x: columnCenter(index) - 10, y: -insets.bottom / 2)
            }
        }
    }
    private var tickMarks: [Int] {
        let strideSize = max(1, records.count / 6)
        return Array(stride(from: 0, to: max(0, records.count), by: strideSize))
    }

    private var detail: some View {
        Group {
        if let index = selected, records.indices.contains(index) {
            let record = records[index]
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generation \(index + 1)").font(.subheadline.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(Color.indigo.opacity(0.6)).frame(width: 8, height: 8)
                        Text(String(format: "%d tokens at start", record.contextSize)).font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                        Text(String(format: "%.1f tokens/sec average", record.averageTokensPerSecond)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(record.startedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { selected = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(index == 0)
                        Button { selected = min(records.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(index >= records.count - 1)
                    }
                    Button("Clear selection") { selected = nil }
                }
            }
            .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        } else {
            Text("Tap a column to inspect a generation.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
    }
}
