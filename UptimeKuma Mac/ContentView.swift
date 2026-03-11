import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: UptimeKumaStatusStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @State private var dismissedDownMonitorIDs: Set<Int> = []
    @State private var selectedMonitorID: Int?
    @State private var isShowingAddMonitorAssistant = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if selectedMonitorID == nil, let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isShowingAddMonitorAssistant {
                AddMonitorAssistantView(
                    store: store,
                    onOpenURL: { url in openURL(url) },
                    onBack: { isShowingAddMonitorAssistant = false }
                )
            } else if let selectedMonitorID,
               let monitor = store.monitors.first(where: { $0.id == selectedMonitorID }) {
                MonitorDetailView(
                    monitor: monitor,
                    pingHistory: store.pingHistoryByMonitorID[monitor.id] ?? [],
                    lastUpdated: store.lastUpdated,
                    onBack: { self.selectedMonitorID = nil }
                )
            } else if store.monitors.isEmpty {
                Text(store.emptyStateMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                QuickLookInfoBar(
                    monitors: orderedMonitors,
                    dismissedDownCount: dismissedDownMonitorIDs.count,
                    onResetDismissed: { dismissedDownMonitorIDs.removeAll() }
                )
                contentForStyle
            }

            if !isShowingAddMonitorAssistant, selectedMonitorID == nil, let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated, format: .dateTime.hour().minute().second())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            footer
        }
        .padding()
        .frame(width: 360)
        .onChange(of: store.monitors.map(\.id)) { _, _ in
            let activeDownIDs = Set(store.monitors.filter { $0.state == .down }.map(\.id))
            dismissedDownMonitorIDs = dismissedDownMonitorIDs.intersection(activeDownIDs)
            if let selectedMonitorID, !store.monitors.contains(where: { $0.id == selectedMonitorID }) {
                self.selectedMonitorID = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Uptime Kuma")
                .font(.headline)
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                selectedMonitorID = nil
                isShowingAddMonitorAssistant = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("Add Monitor")
            .disabled(store.addMonitorURL == nil)
            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }

    @ViewBuilder
    private var contentForStyle: some View {
        switch store.dashboardStyle {
        case .compactList:
            CompactListView(
                monitors: orderedMonitors,
                dismissedDownMonitorIDs: dismissedDownMonitorIDs,
                onDismissDown: dismissDownMonitor,
                onSelectMonitor: showMonitorDetails
            )
        case .statusCards:
            StatusCardsView(
                monitors: orderedMonitors,
                pingHistoryByMonitorID: store.pingHistoryByMonitorID,
                dismissedDownMonitorIDs: dismissedDownMonitorIDs,
                onDismissDown: dismissDownMonitor,
                onSelectMonitor: showMonitorDetails
            )
        case .analytics:
            AnalyticsView(
                monitors: orderedMonitors,
                downCountHistory: store.downCountHistory,
                pingHistoryByMonitorID: store.pingHistoryByMonitorID,
                dismissedDownMonitorIDs: dismissedDownMonitorIDs,
                onDismissDown: dismissDownMonitor,
                onSelectMonitor: showMonitorDetails
            )
        }
    }

    private var orderedMonitors: [MonitorStatus] {
        let urgent = store.monitors.filter { $0.state == .down && !dismissedDownMonitorIDs.contains($0.id) }
        let remaining = store.monitors.filter { !($0.state == .down && !dismissedDownMonitorIDs.contains($0.id)) }
        return urgent + remaining
    }

    private func dismissDownMonitor(_ monitorID: Int) {
        guard store.monitors.contains(where: { $0.id == monitorID && $0.state == .down }) else { return }
        dismissedDownMonitorIDs.insert(monitorID)
    }

    private func showMonitorDetails(_ monitor: MonitorStatus) {
        selectedMonitorID = monitor.id
    }

    private var footer: some View {
        HStack {
            Button("Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct AddMonitorAssistantView: View {
    @ObservedObject var store: UptimeKumaStatusStore
    let onOpenURL: (URL) -> Void
    let onBack: () -> Void
    @State private var draftName = ""
    @State private var draftTarget = ""
    @State private var intervalSeconds = 60
    @State private var isSubmitting = false
    @State private var inlineMessage: String?

    private let intervalOptions = [20, 30, 60, 120, 300, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer()

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Create") {
                    createMonitor()
                }
                .disabled(isSubmitting || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Add Monitor")
                        .font(.title2.weight(.semibold))

                    Text("Create a monitor in-app via Uptime Kuma internal API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        HStack {
                            Text("Name")
                            Spacer()
                            TextField("e.g. API", text: $draftName)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 220)
                        }
                        HStack {
                            Text("Target URL")
                            Spacer()
                            TextField("https://example.com/health", text: $draftTarget)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 220)
                        }
                        HStack {
                            Text("Interval")
                            Spacer()
                            Picker("Interval", selection: $intervalSeconds) {
                                ForEach(intervalOptions, id: \.self) { option in
                                    Text("\(option)s").tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 220, alignment: .trailing)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if let inlineMessage {
                        Text(inlineMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func createMonitor() {
        inlineMessage = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = draftTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        Task {
            do {
                let monitorID = try await store.addHTTPMonitor(
                    name: name,
                    targetURL: target,
                    intervalSeconds: intervalSeconds
                )
                await MainActor.run {
                    inlineMessage = monitorID > 0
                        ? "Monitor created (ID \(monitorID))."
                        : "Monitor created successfully."
                    isSubmitting = false
                    onBack()
                }
            } catch {
                await MainActor.run {
                    inlineMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}

private struct QuickLookInfoBar: View {
    let monitors: [MonitorStatus]
    let dismissedDownCount: Int
    let onResetDismissed: () -> Void

    private var total: Int { monitors.count }
    private var up: Int { monitors.filter { $0.state == .up }.count }
    private var down: Int { monitors.filter { $0.state == .down }.count }
    private var attention: Int { monitors.filter { $0.state == .pending || $0.state == .maintenance || $0.state == .unknown }.count }
    private var averagePing: Int? {
        let pings = monitors.compactMap(\.ping)
        guard !pings.isEmpty else { return nil }
        return Int((pings.reduce(0, +) / Double(pings.count)).rounded())
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                QuickLookPill(label: "Total", value: "\(total)", tint: .secondary)
                QuickLookPill(label: "Up", value: "\(up)", tint: .green)
                QuickLookPill(label: "Down", value: "\(down)", tint: .red)
                QuickLookPill(label: "Attention", value: "\(attention)", tint: .orange)
                if let averagePing {
                    QuickLookPill(label: "Avg Ping", value: "\(averagePing) ms", tint: .blue)
                }
                if dismissedDownCount > 0 {
                    Button("Show \(dismissedDownCount) Dismissed") {
                        onResetDismissed()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

private struct QuickLookPill: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

private struct CompactListView: View {
    let monitors: [MonitorStatus]
    let dismissedDownMonitorIDs: Set<Int>
    let onDismissDown: (Int) -> Void
    let onSelectMonitor: (MonitorStatus) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(monitors) { monitor in
                    HStack(spacing: 8) {
                        Image(systemName: monitor.state.symbolName)
                            .foregroundStyle(monitor.state.color)
                        Text(monitor.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let pingText = monitor.pingText {
                            Text(pingText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(monitor.state.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if monitor.state == .down && !dismissedDownMonitorIDs.contains(monitor.id) {
                            Button {
                                onDismissDown(monitor.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss from top priority")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectMonitor(monitor)
                    }
                }
            }
        }
        .frame(maxHeight: 230)
    }
}

private struct StatusCardsView: View {
    let monitors: [MonitorStatus]
    let pingHistoryByMonitorID: [Int: [Double]]
    let dismissedDownMonitorIDs: Set<Int>
    let onDismissDown: (Int) -> Void
    let onSelectMonitor: (MonitorStatus) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(monitors) { monitor in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(monitor.name, systemImage: monitor.state.symbolName)
                                .lineLimit(1)
                                .foregroundStyle(monitor.state.color)
                            Spacer()
                            Text(monitor.state.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if monitor.state == .down && !dismissedDownMonitorIDs.contains(monitor.id) {
                                Button {
                                    onDismissDown(monitor.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Dismiss from top priority")
                            }
                        }
                        HStack(spacing: 10) {
                            Text(monitor.pingText ?? "n/a")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Sparkline(values: pingHistoryByMonitorID[monitor.id] ?? [], stroke: .blue)
                                .frame(height: 24)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectMonitor(monitor)
                    }
                }
            }
        }
        .frame(maxHeight: 240)
    }
}

private struct AnalyticsView: View {
    let monitors: [MonitorStatus]
    let downCountHistory: [Int]
    let pingHistoryByMonitorID: [Int: [Double]]
    let dismissedDownMonitorIDs: Set<Int>
    let onDismissDown: (Int) -> Void
    let onSelectMonitor: (MonitorStatus) -> Void

    var upCount: Int { monitors.filter { $0.state == .up }.count }
    var downCount: Int { monitors.filter { $0.state == .down }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatChip(label: "Up", value: "\(upCount)", color: .green)
                StatChip(label: "Down", value: "\(downCount)", color: .red)
                StatChip(label: "Total", value: "\(monitors.count)", color: .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Down Trend")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Sparkline(
                    values: downCountHistory.map(Double.init),
                    stroke: downCount > 0 ? .red : .green,
                    fill: (downCount > 0 ? Color.red : Color.green).opacity(0.15)
                )
                .frame(height: 48)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(monitors.prefix(6)) { monitor in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(monitor.state.color)
                                .frame(width: 8, height: 8)
                            Text(monitor.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            if monitor.state == .down && !dismissedDownMonitorIDs.contains(monitor.id) {
                                Button {
                                    onDismissDown(monitor.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Dismiss from top priority")
                            }
                            Sparkline(values: pingHistoryByMonitorID[monitor.id] ?? [], stroke: .blue)
                                .frame(width: 80, height: 18)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectMonitor(monitor)
                        }
                    }
                }
            }
            .frame(maxHeight: 110)
        }
    }
}

private struct MonitorDetailView: View {
    let monitor: MonitorStatus
    let pingHistory: [Double]
    let lastUpdated: Date?
    let onBack: () -> Void

    private var avgPing: Int? {
        guard !pingHistory.isEmpty else { return nil }
        return Int((pingHistory.reduce(0, +) / Double(pingHistory.count)).rounded())
    }

    private var minPing: Int? {
        pingHistory.min().map { Int($0.rounded()) }
    }

    private var maxPing: Int? {
        pingHistory.max().map { Int($0.rounded()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                Label(monitor.name, systemImage: monitor.state.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(monitor.state.color)
                Spacer()
                Text(monitor.state.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                DetailPill(label: "ID", value: "\(monitor.id)")
                DetailPill(label: "Ping", value: monitor.pingText ?? "n/a")
                if let avgPing {
                    DetailPill(label: "Avg", value: "\(avgPing) ms")
                }
                if let minPing, let maxPing {
                    DetailPill(label: "Min/Max", value: "\(minPing)/\(maxPing) ms")
                }
            }

            if let target = monitor.target, !target.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(target)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        if let url = normalizedURL(from: target) {
                            Link("Open URL", destination: url)
                                .font(.caption)
                        }
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(target, forType: .string)
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !pingHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ping Trend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Sparkline(values: pingHistory, stroke: .blue, fill: .blue.opacity(0.14))
                        .frame(height: 78)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let lastUpdated {
                Text("Last updated \(lastUpdated, format: .dateTime.hour().minute().second())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func normalizedURL(from raw: String) -> URL? {
        if let direct = URL(string: raw), direct.scheme != nil {
            return direct
        }
        return URL(string: "https://\(raw)")
    }
}

private struct DetailPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatChip: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.55), in: Capsule())
    }
}

private struct Sparkline: View {
    let values: [Double]
    var stroke: Color = .blue
    var fill: Color = .clear

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            ZStack {
                if fill != .clear, points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        for point in points {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: points.last?.x ?? proxy.size.width, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(fill)
                }

                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(stroke, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else {
                    Capsule()
                        .fill(stroke.opacity(0.35))
                        .frame(height: 2)
                }
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        let usable = values.suffix(30)
        guard usable.count > 1 else { return [] }

        let minValue = usable.min() ?? 0
        let maxValue = usable.max() ?? 1
        let span = max(maxValue - minValue, 1)

        return usable.enumerated().map { index, value in
            let x = CGFloat(index) / CGFloat(max(usable.count - 1, 1)) * size.width
            let normalized = (value - minValue) / span
            let y = size.height - CGFloat(normalized) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}
