import Charts
import TinybarCore
import SwiftUI

// MARK: Surfaces
//
// The popover itself is the Liquid Glass layer on macOS 26. Everything inside is a tinted fill
// on that glass, never a second glass layer: glass on glass loses its legibility.

extension View {
    /// The quiet surface content sits on: a faint fill, so it never competes with the glass.
    func platter(cornerRadius: CGFloat = 14) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}

enum Motion {
    /// Critically damped: pages and selection move without overshoot.
    static let page = Animation.spring(response: 0.35, dampingFraction: 1)
    static let reduced = Animation.easeOut(duration: 0.15)
}

// MARK: Rings

/// Concentric rings, one per Limit Window, longest outside. Each ring is full when the window is
/// untouched and empties as it is used. Ink on a faint track, the same for every subscription.
struct LimitRings: View {
    let windows: [LimitWindow]
    var lineWidth: CGFloat = 4.5
    var gap: CGFloat = 2
    var dimmed = false

    var body: some View {
        ZStack {
            if windows.isEmpty {
                Circle().stroke(.primary.opacity(0.1), lineWidth: lineWidth).padding(lineWidth / 2)
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { i, window in
                Ring(fraction: window.remainingPercent / 100, lineWidth: lineWidth)
                    .padding(CGFloat(i) * (lineWidth + gap) + lineWidth / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityElement()
        .accessibilityLabel(windows.map { "\($0.title) \(Format.percent($0.remainingPercent)) left" }.joined(separator: ", "))
    }

    private struct Ring: View {
        let fraction: Double
        let lineWidth: CGFloat

        var body: some View {
            let f = min(max(fraction, 0), 1)
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .animation(.smooth(duration: 0.5), value: f)
        }
    }
}

extension ProviderSnapshot {
    /// The logins this snapshot covers, most weekly limit left first, then the soonest weekly
    /// reset; empty for a Provider with one.
    var accounts: [String] {
        var seen = Set<String>()
        let labels = windows.compactMap(\.account).filter { seen.insert($0).inserted }
        func weekly(_ account: String) -> LimitWindow? {
            windows.first { $0.account == account && $0.kind == .weekly && !$0.isModelSpecific }
        }
        return labels.sorted { a, b in
            let wa = weekly(a), wb = weekly(b)
            let left = (wa?.remainingPercent ?? -1, wb?.remainingPercent ?? -1)
            if left.0 != left.1 { return left.0 > left.1 }
            return (wa?.resetsAt ?? .distantFuture) < (wb?.resetsAt ?? .distantFuture)
        }
    }

    /// One login's part of a multi-login snapshot, with its windows' titles unprefixed.
    func scoped(to account: String) -> ProviderSnapshot {
        var s = self
        s.plan = accountPlans?[account]
        s.windows = windows.filter { $0.account == account }.map { w in
            var w = w
            if w.title.hasPrefix("\(account) · ") { w.title.removeFirst(account.count + 3) }
            return w
        }
        s.bankedResets = nil
        s.extraUsage = nil
        s.accountErrors = nil
        return s
    }

    private var generalWindows: [LimitWindow] {
        windows.filter { !$0.isModelSpecific }
    }

    /// What the rings show: the account-wide windows, longest (outermost) first. With several
    /// logins, those of the login closest to running out.
    var ringWindows: [LimitWindow] {
        let account = bindingWindow?.account
        return Array(generalWindows.filter { $0.account == account }
            .sorted { ($0.durationSeconds ?? .max) > ($1.durationSeconds ?? .max) }.prefix(2))
    }

    /// The account-wide window closest to running out; ties go to the one that resets first.
    var bindingWindow: LimitWindow? {
        generalWindows.min {
            ($0.remainingPercent, $0.resetsAt ?? .distantFuture) < ($1.remainingPercent, $1.resetsAt ?? .distantFuture)
        }
    }
}

// MARK: Numbers

/// What is left of a Limit Window: the whole number with its percent sign at the same weight and
/// size, digits monospaced so a column of them lines up on the right.
struct PercentText: View {
    let percent: Double
    var size: CGFloat = 15
    /// Says "left" after the number, in the secondary colour.
    var suffix = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(Format.percent(percent))
                .font(.system(size: size, weight: percent < 20 ? .bold : .semibold).monospacedDigit())
            if suffix {
                Text("left")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("\(Format.percent(percent)) left")
    }
}

/// Fills with what is left: full at the start of a window, empty when the limit is reached.
struct RemainingBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let f = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(.primary)
                    .frame(width: f > 0 ? max(4, geo.size.width * f) : 0)
            }
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.5), value: fraction)
    }
}

enum ResetText {
    /// "Resets in 4h 7m" for the compact overview.
    static func short(_ window: LimitWindow, now: Date = Date()) -> String {
        guard let resetsAt = window.resetsAt else { return window.title }
        return "\(window.title) resets in \(Format.countdown(to: resetsAt, now: now))"
    }

    /// "Resets at 18:39, in 4h 7m" or "Resets Fri 09:00, in 3d 18h".
    static func long(_ resetsAt: Date, now: Date = Date()) -> String {
        let sameDay = Calendar.current.isDate(resetsAt, inSameDayAs: now)
        let when = sameDay
            ? "at \(resetsAt.formatted(date: .omitted, time: .shortened))"
            : resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Resets \(when), in \(Format.countdown(to: resetsAt, now: now))"
    }
}

// MARK: Charts

/// Daily tokens, stacked by Provider in shades of grey.
struct UsageBars: View {
    let days: [UsageSummary.DayBar]
    let range: UsageRange
    var showAxis = true

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        Chart(days) { bar in
            BarMark(
                x: .value("Day", DayKeyDate.date(bar.day), unit: .day),
                y: .value("Tokens", bar.tokens),
                width: .ratio(range == .month ? 0.7 : 0.55))
                .foregroundStyle(by: .value("Provider", bar.provider.displayName))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(
            domain: ProviderID.allCases.map(\.displayName), range: ProviderID.allCases.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: start...end)
        .chartXAxis {
            if showAxis {
                AxisMarks(values: .stride(by: .day, count: range == .month ? 7 : 1)) { _ in
                    AxisValueLabel(format: range == .month ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.narrow), centered: true)
                }
            }
        }
        .chartYAxis {
            if showAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                    AxisValueLabel { Text(Format.tokens(value.as(Int64.self) ?? 0)) }
                }
            }
        }
        .accessibilityLabel("Tokens per day")
    }
}

/// Top models or projects. Each row is backed by a faint bar showing its share of all tokens,
/// split by subscription in their shades.
struct Breakdown: View {
    let title: String
    let lines: [UsageSummary.Line]
    let total: Int64

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                ForEach(lines.prefix(5)) { line in
                    HStack(spacing: 8) {
                        Text(line.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Format.tokens(line.tokens)).foregroundStyle(.secondary)
                        Text(Format.cost(line.cost)).frame(width: 58, alignment: .trailing)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(alignment: .leading) { ShareBar(line: line, total: total) }
                }
            }
        }
    }

    private struct ShareBar: View {
        let line: UsageSummary.Line
        let total: Int64

        var body: some View {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(line.byProvider.keys.sorted(), id: \.self) { id in
                        Rectangle()
                            .fill(id.color.opacity(0.14))
                            .frame(width: geo.size.width * share(line.byProvider[id] ?? 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .animation(.smooth(duration: 0.4), value: line.tokens)
        }

        private func share(_ tokens: Int64) -> CGFloat {
            guard total > 0 else { return 0 }
            return CGFloat(min(max(Double(tokens) / Double(total), 0), 1))
        }
    }
}

/// A subscription's shade as a small dot.
struct ProviderDot: View {
    let id: ProviderID
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(id.color)
            .frame(width: size, height: size)
    }
}

// MARK: Buttons

/// A full-width row: highlights on hover and the instant it is pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))
                        .padding(3)
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: Provider presentation

extension ProviderID {
    var webDomain: String {
        switch self {
        case .claude: "claude.ai"
        case .codex: "chatgpt.com"
        case .gemini: "antigravity.google"
        case .cursor: "cursor.com"
        }
    }

    /// One shade of grey per subscription for dots and charts, so stacked bars stay apart without
    /// colour.
    var color: Color {
        switch self {
        case .claude: .primary.opacity(0.5)
        case .codex: .primary
        case .gemini: .primary.opacity(0.75)
        case .cursor: .primary.opacity(0.3)
        }
    }
}

extension ExtraUsageSpend {
    var formatted: String {
        let used = used.formatted(.currency(code: currency))
        guard let limit else { return used }
        return "\(used) of \(limit.formatted(.currency(code: currency)))"
    }
}

/// Developer snapshot switches (`--snapshot … --redact-projects` for public screenshots).
enum PopoverSnapshotOptions {
    static let redactProjects = CommandLine.arguments.contains("--redact-projects")

    static func projects(_ lines: [UsageSummary.Line]) -> [UsageSummary.Line] {
        guard redactProjects else { return lines }
        let names = ["acme-web", "billing-service", "No project", "docs-site", "ml-pipeline"]
        return lines.enumerated().map { i, l in
            UsageSummary.Line(name: names[i % names.count], tokens: l.tokens, cost: l.cost, byProvider: l.byProvider)
        }
    }
}
