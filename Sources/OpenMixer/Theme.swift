import AppKit
import AVKit
import MixerCore
import SwiftUI

/// Colours are semantic so the UI follows light/dark mode like a system app.
enum Theme {
    static let accent = Color.accentColor
    static let track = Color.primary.opacity(0.14)
    static let secondary = Color.secondary
}

extension View {
    /// Liquid Glass on macOS 26+, a quiet material on older systems.
    @ViewBuilder func glassCard(_ radius: CGFloat = 14, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.quaternary.opacity(0.7), in: shape)
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}

/// Slider with a pill knob, a snap mark, haptics and an optional level meter underneath.
struct LevelSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var meterID: String?
    var markAt: Double?
    @State private var dragging = false
    @State private var snapped = false

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width, span = range.upperBound - range.lowerBound
                let knobW: CGFloat = dragging ? 26 : 22
                let x = CGFloat((value - range.lowerBound) / span) * (w - knobW) + knobW / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track).frame(height: 6)
                    Capsule().fill(Theme.accent).frame(width: max(6, x), height: 6)
                    if let m = markAt {
                        Capsule().fill(Color.primary.opacity(0.35)).frame(width: 2, height: 10)
                            .offset(x: CGFloat((m - range.lowerBound) / span) * (w - knobW) + knobW / 2 - 1)
                    }
                    Capsule().fill(Color.white).frame(width: knobW, height: 16)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .offset(x: x - knobW / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { withAnimation(.spring(duration: 0.25, bounce: 0.35)) { dragging = true } }
                        let f = min(1, max(0, Double((g.location.x - 11) / (w - 22))))
                        var v = range.lowerBound + f * span
                        if let m = markAt, abs(v - m) < span * 0.025 {
                            v = m
                            if !snapped { snapped = true; NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                        } else { snapped = false }
                        value = v
                    }
                    .onEnded { _ in withAnimation(.spring(duration: 0.3, bounce: 0.3)) { dragging = false } })
            }
            .frame(height: 18)
            if let id = meterID { MeterBar(id: id) }
        }
    }
}

struct MeterBar: View {
    @EnvironmentObject var levels: LevelStore
    let id: String

    var body: some View {
        GeometryReader { geo in
            let level = CGFloat(min(1, max(0, levels.levels[id] ?? 0)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * level))
                    .clipShape(Capsule())
            }
        }
        .frame(height: 3)
    }
}

struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...12
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, span = range.upperBound - range.lowerBound
            let knob: CGFloat = dragging ? 16 : 13
            let y = h - CGFloat((value - range.lowerBound) / span) * h
            ZStack(alignment: .top) {
                Capsule().fill(Theme.track).frame(width: 4)
                Capsule().fill(Theme.accent.opacity(0.9)).frame(width: 4, height: abs(h / 2 - y)).offset(y: min(y, h / 2))
                Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 12, height: 1).offset(y: h / 2)
                Circle().fill(Color.white).frame(width: knob, height: knob).offset(y: min(max(0, y - knob / 2), h - knob))
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { withAnimation(.spring(duration: 0.2, bounce: 0.3)) { dragging = true } }
                    let f = 1 - min(1, max(0, Double(g.location.y / h)))
                    var v = range.lowerBound + f * span
                    if abs(v) < 0.5 { v = 0 }
                    value = (v * 2).rounded() / 2
                }
                .onEnded { _ in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { dragging = false } })
        }
    }
}

struct IconButton: View {
    let symbol: String
    var active = false
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .foregroundStyle(active ? Theme.accent : Color.primary.opacity(0.8))
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// Segmented control that shares the available width, so it can never overflow the popover.
struct SegmentedTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button {
                    withAnimation(.smooth(duration: 0.28)) { selection = item.0 }
                } label: {
                    Text(item.1).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(selection == item.0 ? Color.primary : Color.secondary)
                        .background {
                            if selection == item.0 {
                                Capsule().fill(Color.primary.opacity(0.16)).matchedGeometryEffect(id: "selection", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassCard(18)
    }
}

/// AirPlay destination picker (system control).
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {}
}

/// Records a global shortcut when clicked.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Type shortcut…" : shortcut.map(HotKeyCenter_label) ?? "Record") {
                recording ? stop() : start()
            }
            .frame(minWidth: 110)
            if shortcut != nil && !recording { Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // esc cancels
            if let s = HotKeyCenter.shortcut(from: e) { shortcut = s; stop(); return nil }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

func HotKeyCenter_label(_ s: Shortcut) -> String { HotKeyCenter.label(for: s) }
