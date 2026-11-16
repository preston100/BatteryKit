import SwiftUI
import Charts
import AppKit

@main
struct BatteryKitApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            MenuLabel(m: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var m: Model
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: m.menuSymbol)
            Text("\(m.battery?.percent ?? 0)%")
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ZStack {
            // Solid backdrop for Dark / Light so nothing behind the panel shows through.
            switch m.theme {
            case .dark: Color.black
            case .light: Color(white: 0.95)
            default: Color.clear
            }

            VStack(spacing: 10) {
                HeaderView()
                if let b = m.banner {
                    BannerView(text: b.text, color: b.color)
                }
                LimitModule()
                HeatModule()
                if m.showWelcome {
                    WelcomePanel()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if m.showSettings {
                    SettingsPanel()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if let metric = m.selectedMetric {
                    MetricDetail(metric: metric)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    StatsGrid()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                FooterView()
            }
            .padding(14)
        }
        .frame(width: 420)
        .animation(.smooth(duration: 0.3), value: m.selectedMetric)
        .animation(.smooth(duration: 0.3), value: m.showSettings)
        .animation(.smooth(duration: 0.3), value: m.showWelcome)
        .environment(\.colorScheme, m.theme.scheme ?? m.systemScheme)
        // Explicit text colour: black on Light, white on Dark (secondary text follows automatically).
        .foregroundStyle(m.theme == .light ? Color.black : (m.theme == .dark ? Color.white : Color.primary))
        .onAppear {
            m.applyAppearance()
            m.setVisible(true)
        }
        .onDisappear { m.setVisible(false) }
    }
}

// MARK: - Building blocks

/// A Liquid Glass panel, like a Control Center module.
struct Module<Content: View>: View {
    var padding: CGFloat = 14
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(.rect(cornerRadius: 22), tint: tint)
    }
}

/// Liquid Glass with a light wash of colour, so panels read as coloured glass rather than grey haze.
func glass(_ tint: Color?, strength: Double = 0.16) -> Glass {
    guard let tint else { return .regular }
    return .regular.tint(tint.opacity(strength))
}

/// Every panel goes through this so the Appearance setting restyles the whole app.
struct PanelStyle<S: Shape>: ViewModifier {
    @EnvironmentObject var m: Model
    let shape: S
    let tint: Color?
    let strength: Double
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch m.theme {
        case .color:
            let g = glass(tint, strength: strength)
            content.glassEffect(interactive ? g.interactive() : g, in: shape)
        case .glass:
            content.glassEffect(interactive ? Glass.clear.interactive() : Glass.clear, in: shape)
        case .dark:
            // Solid black panels, white text. Not see-through.
            content
                .background(Color(white: 0.1), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        case .light:
            // Solid white panels, black text. Not see-through.
            content
                .background(Color.white, in: shape)
                .overlay(shape.stroke(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
        }
    }
}

extension View {
    func panel<S: Shape>(_ shape: S, tint: Color? = nil, strength: Double = 0.16,
                         interactive: Bool = false) -> some View {
        modifier(PanelStyle(shape: shape, tint: tint, strength: strength, interactive: interactive))
    }
}

/// Coloured round icon used in module headers and tiles.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)],
                                             startPoint: .top, endPoint: .bottom))
            )
    }
}

struct ModuleHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, tint: tint)
            Text(title).font(.system(.headline, design: .rounded))
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct Pill: View {
    let symbol: String
    let text: String
    var tint: Color = .clear

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .panel(.capsule, tint: tint, strength: 0.25)
    }
}

struct BannerView: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(color)
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .panel(.rect(cornerRadius: 18), tint: color, strength: 0.25)
    }
}

// MARK: - Header

struct BatteryRing: View {
    let percent: Int
    let limit: Int?
    let color: Color
    let symbol: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 11)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.55), color],
                                    center: .center,
                                    startAngle: .degrees(0),
                                    endAngle: .degrees(max(1, 3.6 * Double(percent)))),
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 6)
            if let limit, limit < 100 {
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 3, height: 17)
                    .offset(y: -45.5)
                    .rotationEffect(.degrees(Double(limit) * 3.6))
            }
            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                Text("\(percent)%")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 102, height: 102)
        .animation(.smooth(duration: 0.5), value: percent)
    }
}

struct HeaderView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        let b = m.battery
        HStack(spacing: 16) {
            BatteryRing(percent: b?.percent ?? 0,
                        limit: m.config.enabled ? m.config.limit : nil,
                        color: m.levelColor(b?.percent ?? 0),
                        symbol: m.stateSymbol)

            VStack(alignment: .leading, spacing: 6) {
                Text(m.mode.isEmpty ? "Waiting for service…" : m.mode)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(m.stateColor)
                if let d = m.status?.detail, !d.isEmpty, m.daemonAlive {
                    Text(d)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if let t = b?.timeRemainingMin {
                        Pill(symbol: "clock", text: (b?.isCharging ?? false) ? "\(formatMinutes(t)) to full" : "\(formatMinutes(t)) left")
                    }
                    if let b, b.externalConnected {
                        Pill(symbol: "powerplug.fill",
                             text: b.adapterWatts.map { "\($0) W" } ?? "Charger",
                             tint: .green)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .panel(.rect(cornerRadius: 26), tint: m.levelColor(b?.percent ?? 0), strength: 0.14)
    }
}

// MARK: - Charge limit

struct LimitModule: View {
    @EnvironmentObject var m: Model

    private var shownLimit: Int { Int(m.limitDraft ?? Double(m.config.limit)) }

    var body: some View {
        Module(tint: .green) {
            ModuleHeader(title: "Charge Limit", symbol: "battery.75percent", tint: .green) {
                Toggle("", isOn: Binding(get: { m.config.enabled },
                                         set: { v in m.update { $0.enabled = v } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.green)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("\(shownLimit)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: shownLimit)
                Text("max charge")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .opacity(m.config.enabled ? 1 : 0.4)

            Slider(value: Binding(get: { m.limitDraft ?? Double(m.config.limit) },
                                  set: { m.limitDraft = $0 }),
                   in: 50...100, step: 5,
                   onEditingChanged: { editing in
                       if !editing, let v = m.limitDraft {
                           m.update { $0.limit = Int(v) }
                           m.limitDraft = nil
                       }
                   })
                .tint(.green)
                .disabled(!m.config.enabled)

            HStack(spacing: 6) {
                ForEach([60, 70, 80, 90, 100], id: \.self) { v in
                    presetButton(v)
                }
            }
            .disabled(!m.config.enabled)

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Image(systemName: "bolt.badge.clock")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Charge to 100% once").font(.callout.weight(.medium))
                    Text("Then goes back to \(m.config.limit)%").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if m.config.topUp {
                    Button("Cancel") { m.update { $0.topUp = false } }
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                } else {
                    Button("Start") { m.update { $0.topUp = true } }
                        .buttonStyle(.glass)
                }
            }
            .disabled(!m.config.enabled)

            HStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drain to limit").font(.callout.weight(.medium))
                    Text("Runs on battery while plugged in until it's at the limit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { m.config.dischargeToLimit },
                                         set: { v in m.update { $0.dischargeToLimit = v } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(.purple)
            }
            .disabled(!(m.status?.canCutAdapter ?? false) || !m.config.enabled)
        }
    }

    @ViewBuilder
    private func presetButton(_ v: Int) -> some View {
        let button = Button {
            m.update { $0.limit = v }
        } label: {
            Text("\(v)")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        if m.config.limit == v {
            button.buttonStyle(.glassProminent).tint(.green)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

// MARK: - Heat

struct HeatModule: View {
    @EnvironmentObject var m: Model

    var body: some View {
        Module(tint: .orange) {
            ModuleHeader(title: "Heat Protection", symbol: "thermometer.sun.fill", tint: .orange) {
                Toggle("", isOn: Binding(get: { m.config.heatProtection },
                                         set: { v in m.update { $0.heatProtection = v } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.orange)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pause charging above").font(.callout.weight(.medium))
                    Text("Resumes 2°C below the limit").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(value: Binding(get: { m.config.maxTempC },
                                       set: { v in m.update { $0.maxTempC = v } }),
                        in: 30...45, step: 1) {
                    Text("\(Int(m.config.maxTempC))°C")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
            }
            .disabled(!m.config.heatProtection)

            if let t = m.temperature {
                TemperatureBar(temp: t, limit: m.config.maxTempC)
            }
        }
    }
}

struct TemperatureBar: View {
    let temp: Double
    let limit: Double

    var body: some View {
        let lo = 20.0, hi = 50.0
        let frac = min(1, max(0, (temp - lo) / (hi - lo)))
        let limitFrac = min(1, max(0, (limit - lo) / (hi - lo)))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.teal, .yellow, .orange, .red],
                                             startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) {
                            Capsule().frame(width: max(8, geo.size.width * frac))
                        }
                    Capsule()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 2.5, height: 14)
                        .offset(x: geo.size.width * limitFrac - 1.25)
                }
            }
            .frame(height: 8)
            Text(String(format: "Battery is %.1f°C right now", temp))
                .font(.caption)
                .foregroundStyle(temp >= limit ? Color.orange : Color.secondary)
        }
    }
}

// MARK: - Stats grid (4 x 2, tap a tile for its history)

struct StatTile: View {
    let metric: Metric
    let value: String
    let caption: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                IconBadge(symbol: metric.symbol, tint: tint, size: 24)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .contentTransition(.numericText())
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 18))
            .panel(.rect(cornerRadius: 18), tint: tint, strength: 0.2, interactive: true)
        }
        .buttonStyle(.plain)
        .help("Show \(metric.title.lowercased()) history")
    }
}

struct StatsGrid: View {
    @EnvironmentObject var m: Model
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(Metric.allCases) { metric in
                let t = m.tileText(for: metric)
                StatTile(metric: metric, value: t.value, caption: t.caption,
                         tint: m.tint(for: metric)) {
                    m.selectedMetric = metric
                }
            }
        }
    }
}

// MARK: - Detail panel

struct ChartPoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    var apps: [AppUse] = []
}

struct MetricDetail: View {
    @EnvironmentObject var m: Model
    let metric: Metric

    var body: some View {
        let samples = m.samples(in: m.historyRange)
        let live = m.tileText(for: metric)
        let tint = m.tint(for: metric)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(symbol: metric.symbol, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(metric.title).font(.system(.headline, design: .rounded))
                    Text("Now: \(live.value)\(metric == .apps ? " (\(live.caption))" : "")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Picker("", selection: $m.historyRange) {
                    ForEach(HistoryRange.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 118)
                Button {
                    m.selectedMetric = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .panel(.circle, interactive: true)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            if metric == .apps {
                LiveAppsList(apps: m.topApps)
                Divider().opacity(0.5)
                Text("Energy used over this period")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                AppsBreakdown(samples: samples)
            } else {
                MetricChart(metric: metric, samples: samples, tint: tint, range: m.historyRange)
            }
        }
        .padding(14)
        .panel(.rect(cornerRadius: 22), tint: tint, strength: 0.12)
    }
}

struct EmptyHistory: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Not enough data yet. A point is saved every 2 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

struct MetricChart: View {
    @EnvironmentObject var m: Model
    let metric: Metric
    let samples: [HistorySample]
    let tint: Color
    let range: HistoryRange

    private var points: [ChartPoint] {
        let raw = samples.filter { metric.value($0) != nil }
        let step = max(1, raw.count / 300)
        return stride(from: 0, to: raw.count, by: step).enumerated().map { i, idx in
            ChartPoint(id: i, date: raw[idx].date, value: metric.value(raw[idx]) ?? 0, apps: raw[idx].apps)
        }
    }

    private var showsApps: Bool { metric == .using || metric == .charging }

    var body: some View {
        let pts = points
        if pts.count < 2 {
            EmptyHistory()
        } else {
            let vals = pts.map(\.value)
            let lo = vals.min() ?? 0
            let hi = vals.max() ?? 0
            let avg = vals.reduce(0, +) / Double(vals.count)
            let pad = max((hi - lo) * 0.15, metric.minSpan / 2)
            let base = metric == .charging || metric == .using ? max(0, lo - pad) : lo - pad
            let selected = m.chartSelection.flatMap { sel in
                pts.min(by: { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) })
            }

            SelectionReadout(metric: metric, point: selected, tint: tint, showsApps: showsApps)

            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Time", p.date),
                             yStart: .value("Base", base),
                             yEnd: .value(metric.title, p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.date), y: .value(metric.title, p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if let sp = selected {
                    RuleMark(x: .value("Selected", sp.date))
                        .foregroundStyle(Color.primary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", sp.date), y: .value(metric.title, sp.value))
                        .symbolSize(90)
                        .foregroundStyle(tint)
                }
            }
            .chartYScale(domain: base...(hi + pad))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(metric.format(d)).font(.caption) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: range == .day
                                   ? Date.FormatStyle.dateTime.hour()
                                   : Date.FormatStyle.dateTime.weekday(.abbreviated))
                        .font(.caption)
                }
            }
            // The whole chart area is the hit target: hover or click anywhere, no need to hit the line.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                if !m.chartPinned { m.chartSelection = date(at: loc, proxy, geo) }
                            case .ended:
                                if !m.chartPinned { m.chartSelection = nil }
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    m.chartPinned = true
                                    m.chartSelection = date(at: v.location, proxy, geo)
                                }
                        )
                }
            }
            .frame(height: 150)

            HStack(spacing: 8) {
                SummaryChip(label: "Low", value: metric.format(lo))
                SummaryChip(label: "Average", value: metric.format(avg))
                SummaryChip(label: "High", value: metric.format(hi))
            }
        }
    }

    private func date(at loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> Date? {
        guard let frame = proxy.plotFrame else { return nil }
        let x = loc.x - geo[frame].origin.x
        return proxy.value(atX: x, as: Date.self)
    }
}

/// Shows the value at the hovered/clicked time, plus the top 3 apps then.
struct SelectionReadout: View {
    @EnvironmentObject var m: Model
    let metric: Metric
    let point: ChartPoint?
    let tint: Color
    let showsApps: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = point {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metric.format(p.value))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text(p.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if m.chartPinned {
                        Button("Clear") {
                            m.chartPinned = false
                            m.chartSelection = nil
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                if showsApps {
                    if p.apps.isEmpty {
                        Text("No app data for this moment")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(p.apps.prefix(3).enumerated()), id: \.offset) { i, a in
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 18, height: 18)
                                    .background(tint.opacity(0.25), in: Circle())
                                Text(a.name).font(.callout).lineLimit(1)
                                Spacer()
                                Text(String(format: "≈ %.1f W", a.watts))
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Label(showsApps ? "Hover or click anywhere on the chart to see the top 3 apps at that time"
                                : "Hover or click anywhere on the chart to see the exact value",
                      systemImage: "hand.point.up.left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: showsApps ? 104 : 34, alignment: .topLeading)
        .animation(.snappy(duration: 0.15), value: point?.id)
    }
}

struct SummaryChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
    }
}

struct LiveAppsList: View {
    let apps: [AppUse]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Right now")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if apps.isEmpty {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            } else {
                let maxW = max(apps.map(\.watts).max() ?? 1, 0.1)
                ForEach(apps, id: \.self) { a in
                    HStack(spacing: 10) {
                        Text(a.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 190, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(LinearGradient(colors: [Color.pink.opacity(0.6), Color.pink],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, geo.size.width * a.watts / maxW))
                        }
                        .frame(height: 6)
                        Text(String(format: "%.1f W", a.watts))
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct AppsBreakdown: View {
    let samples: [HistorySample]

    struct Row: Identifiable {
        let name: String
        let wh: Double
        var id: String { name }
    }

    private var rows: [Row] {
        var totals: [String: Double] = [:]
        for s in samples {
            for a in s.apps { totals[a.name, default: 0] += a.watts * (2.0 / 60.0) }  // 2-minute samples → Wh
        }
        return totals.map { Row(name: $0.key, wh: $0.value) }
            .filter { $0.wh > 0 }
            .sorted { $0.wh > $1.wh }
            .prefix(7)
            .map { $0 }
    }

    var body: some View {
        let r = rows
        if r.isEmpty {
            EmptyHistory()
        } else {
            Chart(r) { row in
                BarMark(x: .value("Energy", row.wh), y: .value("App", row.name))
                    .foregroundStyle(LinearGradient(colors: [Color.pink.opacity(0.65), Color.pink],
                                                    startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(6)
                    .annotation(position: .trailing) {
                        Text(String(format: "%.1f Wh", row.wh))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption) }
            }
            .frame(height: CGFloat(r.count) * 26 + 8)

            Text("Estimated energy each app used in this period, based on macOS energy impact.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(m.daemonAlive ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .shadow(color: (m.daemonAlive ? Color.green : Color.red).opacity(0.6), radius: 3)
                Text(m.daemonAlive ? (m.status?.method ?? "") : "Service not running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .panel(.capsule)

            Spacer(minLength: 4)

            ThemePicker()

            Button {
                m.selectedMetric = nil
                m.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .panel(.circle, interactive: true)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help("Settings")
        }
    }
}

/// Dark / Light / Color / Liquid Glass switch.
struct ThemePicker: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTheme.allCases) { t in
                Button {
                    m.theme = t
                } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(m.theme == t ? Color.white : Color.primary.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(m.theme == t ? Color.accentColor : Color.clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
        }
        .padding(4)
        .panel(.capsule)
        .animation(.snappy(duration: 0.2), value: m.theme)
    }
}

struct WelcomePanel: View {
    @EnvironmentObject var m: Model

    var body: some View {
        let method = m.status?.method ?? "Checking…"
        let canControl = (m.status?.canInhibit ?? false) || (m.status?.canCutAdapter ?? false)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(symbol: "leaf.fill", tint: .green, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Welcome to BatteryKit").font(.system(.title3, design: .rounded).weight(.bold))
                    Text("Keeps your battery at the limit you choose").font(.callout).foregroundStyle(.secondary)
                }
            }

            WelcomeStep(number: 1,
                        title: m.daemonAlive ? (canControl ? "Your Mac supports charge control" : "Your macOS blocks charge control")
                                             : "Starting the background service…",
                        detail: m.daemonAlive
                            ? (canControl ? "Method: \(method). Your limit stays on through restarts and sleep."
                                          : "You'll still get all the battery stats. For a limit, use Apple's Charge Limit in System Settings.")
                            : "This takes a few seconds after installing.",
                        ok: m.daemonAlive && canControl)

            WelcomeStep(number: 2,
                        title: "Turn off Apple's battery controls",
                        detail: "In Battery settings, click ⓘ next to Charging: turn Optimized Battery Charging off and set Charge Limit to 100%. Otherwise macOS fights your limit.",
                        ok: nil)
            Button {
                m.openBatterySettings()
            } label: {
                Label("Open Battery Settings", systemImage: "gear").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            WelcomeStep(number: 3,
                        title: "Pick your limit",
                        detail: "80% is a good everyday choice. Use \"Charge to 100% once\" before a long day away from a charger.",
                        ok: nil)

            Button {
                m.finishWelcome()
            } label: {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.rect(cornerRadius: 22), tint: .green, strength: 0.1)
    }
}

struct WelcomeStep: View {
    let number: Int
    let title: String
    let detail: String
    let ok: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(ok == true ? Color.green : (ok == false ? Color.orange : Color.primary.opacity(0.12)))
                if let ok {
                    Image(systemName: ok ? "checkmark" : "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.bold))
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsPanel: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(symbol: "gearshape.fill", tint: .gray, size: 30)
                Text("Settings").font(.system(.headline, design: .rounded))
                Spacer()
                Button {
                    m.showSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .panel(.circle, interactive: true)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(.subheadline.weight(.semibold))
                Picker("", selection: $m.theme) {
                    ForEach(AppTheme.allCases) { t in Text(t.title).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Start charging again when it drops below the limit by").font(.subheadline.weight(.semibold))
                Picker("", selection: Binding(get: { m.config.sailingGap },
                                              set: { v in m.update { $0.sailingGap = v } })) {
                    ForEach([2, 3, 5, 10], id: \.self) { g in Text("\(g)%").tag(g) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Calibrate for better accuracy").font(.subheadline.weight(.semibold))
                Text("Charges to 100% once, then goes back to your \(m.config.limit)% limit. Doing this about once a month keeps the health and percentage readings accurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if m.config.topUp {
                        Label("Calibrating… charging to 100%", systemImage: "bolt.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Cancel") { m.update { $0.topUp = false } }
                            .buttonStyle(.glass)
                    } else {
                        Text(m.lastCalibrated.map { "Last: \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Never calibrated")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Calibrate") { m.calibrate() }
                            .buttonStyle(.glassProminent)
                            .tint(.green)
                            .disabled(!m.config.enabled)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: BKPaths.log))
                } label: { Text("Open Log").frame(maxWidth: .infinity) }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.diagnostics(), forType: .string)
                } label: { Text("Copy Diagnostics").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.glass)

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit menu bar app (limit stays on)").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            HStack(spacing: 8) {
                Image(systemName: m.updateAvailable ? "arrow.down.circle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(m.updateAvailable ? Color.blue : Color.green)
                Group {
                    if m.updateAvailable, let v = m.latestVersion {
                        Text("Update available: \(v)")
                    } else if m.latestVersion != nil {
                        Text("You're up to date")
                    } else if m.updateCheckFailed {
                        Text("Couldn't check for updates")
                    } else {
                        Text("Checking for updates…")
                    }
                }
                .font(.callout)
                Spacer()
                Button(m.updateAvailable ? "Get Update" : "GitHub") {
                    NSWorkspace.shared.open(m.updateAvailable
                                            ? bkRepoURL.appendingPathComponent("releases/latest")
                                            : bkRepoURL)
                }
                .buttonStyle(.glass)
            }

            Button(role: .destructive) {
                m.uninstall()
            } label: {
                Text("Uninstall BatteryKit").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(.red)

            Text("BatteryKit \(bkVersion) · free and open source")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.rect(cornerRadius: 22), tint: .gray, strength: 0.1)
    }
}
