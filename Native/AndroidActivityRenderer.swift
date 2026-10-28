import AppKit
import SwiftUI

/// Android notification styles share a header and action row; only their body layout changes.
struct AndroidActivityPresentation {
    enum Layout: String { case standard, bigText, bigPicture, inbox, messaging, call, progress, custom }
    let event: [String: Any]
    let clockAnchor: TimeInterval
    var layout: Layout {
        if let raw = event["layout"] as? String, let supplied = Layout(rawValue: raw) { return supplied }
        if event["indeterminate"] as? Bool == true || number("progressMax") > 0 { return .progress }
        return .standard
    }
    func text(_ key: String) -> String { event[key] as? String ?? "" }
    func number(_ key: String) -> Double { (event[key] as? NSNumber)?.doubleValue ?? 0 }
    var actions: [[String: Any]] {
        Array((event["actions"] as? [[String: Any]] ?? []).prefix(3)).filter { $0["reply"] as? Bool != true }
    }
    var progress: Double? { number("progressMax") > 0 ? min(1, max(0, number("progressValue") / number("progressMax"))) : nil }
    var lines: [String] { Array((event["lines"] as? [String] ?? []).prefix(7)) }
    var messages: [[String: Any]] { Array((event["messages"] as? [[String: Any]] ?? []).suffix(5)) }
    var customNodes: [[String: Any]] { Array((event["customNodes"] as? [[String: Any]] ?? []).prefix(24)) }
    var dark: Bool { event["dark"] as? Bool ?? true }
    var accent: Color {
        let value = UInt32(truncatingIfNeeded: Int64(number("accentColor")))
        guard value & 0x00ffffff != 0 else { return dark ? Color(red: 0.67, green: 0.78, blue: 1) : Color(red: 0.2, green: 0.35, blue: 0.65) }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    func image(_ key: String) -> NSImage? { Self.image(event[key] as? String) }
    static func image(_ encoded: String?) -> NSImage? {
        guard let encoded, encoded.count <= 174764, let data = Data(base64Encoded: encoded), data.count <= 131072 else { return nil }
        return NSImage(data: data)
    }
    func clock(now: TimeInterval) -> String? {
        if event["clockPausedMs"] is NSNumber { return AndroidActivityMenu.clock(number("clockPausedMs") / 1000, countDown: event["countDown"] as? Bool == true) }
        guard event["chronometer"] as? Bool == true else { return nil }
        let down = event["countDown"] as? Bool == true
        return AndroidActivityMenu.clock(down ? clockAnchor - now : now - clockAnchor, countDown: down)
    }
}

/// Stable observable state keeps the hosting controller and SwiftUI identity across updates.
final class AndroidActivityCardModel: ObservableObject {
    @Published var presentation: AndroidActivityPresentation
    @Published var enabled = true
    init(_ presentation: AndroidActivityPresentation) { self.presentation = presentation }
}

/// A full-surface tint keeps the system glass readable without introducing an inner card edge.
struct AndroidActivityGlassLegibility: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let dark = scheme == .dark
        // Retain the native refractive surface underneath; bound the brightest/darkest backdrop.
        (dark ? Color.black : Color.white)
            .opacity(reduceTransparency ? 1 : (contrast == .increased ? 0.82 : (dark ? 0.60 : 0.68)))
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct AndroidActivityHostedCard: View {
    @ObservedObject var model: AndroidActivityCardModel
    let onAction: (String, String) -> Void
    var body: some View {
        let current = model.presentation
        VStack(alignment: .leading, spacing: 0) {
            if !model.enabled {
                Text("Reconnecting to phone…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.top, 12)
            }
            AndroidActivityCard(presentation: current) { action in
                onAction(current.text("version"), action)
            }.disabled(!model.enabled)
        }
        .background { AndroidActivityGlassLegibility() }
    }
}

/// Wake at the clocks' actual digit boundaries, independent of when the card opens.
struct ActivityTimerSchedule: TimelineSchedule {
    let anchors: [TimeInterval]
    struct Entries: Sequence, IteratorProtocol {
        var initial: Date?
        var nextDates: [TimeInterval]
        mutating func next() -> Date? {
            if let first = initial { initial = nil; return first }
            guard let next = nextDates.min() else { return nil }
            for i in nextDates.indices where nextDates[i] <= next + 0.0001 { nextDates[i] += 1 }
            return Date(timeIntervalSince1970: next)
        }
    }
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let wall = Date().timeIntervalSince1970
        let mono = ActivityClock.now
        let start = startDate.timeIntervalSince1970
        let dates = anchors.filter(\.isFinite).map { anchor in
            let localStart = mono + start - wall
            return wall + ActivityClock.nextTick(after: localStart, anchor: anchor) - mono
        }
        return Entries(initial: startDate, nextDates: dates)
    }
}

private struct ActivityTimerEventKey: EnvironmentKey {
    static let defaultValue: [String: Any] = [:]
}
extension EnvironmentValues {
    fileprivate var activityTimerEvent: [String: Any] {
        get { self[ActivityTimerEventKey.self] }
        set { self[ActivityTimerEventKey.self] = newValue }
    }
}

struct AndroidActivityNumericText: View {
    let text: String
    var countsDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activityTimerEvent) private var event
    @Environment(\.lineLimit) private var lineLimit
    var body: some View {
        if ActivityEmbeddedText.spans(text, event: event).isEmpty {
            inline(now: ActivityClock.now)
        } else {
            TimelineView(ActivityTimerSchedule(anchors: ActivityEmbeddedText.tickAnchors(text, event: event, now: ActivityClock.now))) { _ in inline(now: ActivityClock.now) }
        }
    }
    private func inline(now: TimeInterval) -> some View {
        let runs = ActivityEmbeddedText.runs(text, event: event, now: now)
        return ActivityTimerFlow(lineLimit: lineLimit) {
            ForEach(runs) { run in
                Group {
                    if run.numeric { digitLabel(run.text, down: run.timer ? run.down : countsDown).monospacedDigit() }
                    else { Text(run.newline ? " " : run.text) }
                }
                .layoutValue(key: ActivityTimerLineBreak.self, value: run.newline)
                .layoutValue(key: ActivityTimerWhitespace.self, value: !run.newline && run.text.allSatisfy(\.isWhitespace))
            }
        }.clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ActivityEmbeddedText.render(text, event: event, now: now))
    }
    private func digitLabel(_ value: String, down: Bool) -> some View {
        Text(value)
            .contentTransition(.numericText(countsDown: down))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
    }
}

private struct ActivityTimerLineBreak: LayoutValueKey { static let defaultValue = false }
private struct ActivityTimerWhitespace: LayoutValueKey { static let defaultValue = false }

/// Flow individual words/timers using the inherited font, preserving explicit line breaks.
private struct ActivityTimerFlow: Layout {
    var lineLimit: Int?
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (CGSize, [Int: (CGPoint, CGSize)]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var row = 0
        var positions = [Int: (CGPoint, CGSize)]()
        for index in subviews.indices {
            guard row < (lineLimit ?? Int.max) else { break }
            let view = subviews[index]
            if x == 0 && view[ActivityTimerWhitespace.self] { continue }
            let ideal = view.sizeThatFits(.unspecified)
            if view[ActivityTimerLineBreak.self] {
                y += max(rowHeight, ideal.height); x = 0; rowHeight = 0; row += 1
                continue
            }
            let size = ideal.width > width ? view.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            if x > 0 && x + size.width > width {
                y += rowHeight; x = 0; rowHeight = 0; row += 1
                if row >= (lineLimit ?? Int.max) { break }
            }
            positions[index] = (CGPoint(x: x, y: y), size)
            x += size.width; usedWidth = max(usedWidth, x); rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 10000).0
    }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let positions = arrange(subviews, width: bounds.width).1
        let candidates = positions.map { index, placement in
            placement.0.y + subviews[index].dimensions(in: ProposedViewSize(placement.1))[guide]
        }
        return guide == .firstTextBaseline ? candidates.min() : candidates.max()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).1
        for index in subviews.indices {
            if let (point, size) = positions[index] {
                subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(size))
            } else { subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY - 100000), proposal: .zero) }
        }
    }
}

final class AndroidActivityStatusModel: ObservableObject {
    @Published var event: [String: Any] = [:]
    @Published var text = ""
    @Published var image: NSImage?
    @Published var enabled = true
}

struct AndroidActivityStatusLabel: View {
    @ObservedObject var model: AndroidActivityStatusModel
    var body: some View {
        HStack(spacing: 4) {
            if let image = model.image { Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18) }
            if !model.text.isEmpty {
                AndroidActivityNumericText(text: model.text).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.activityTimerEvent, model.event)
            .opacity(model.enabled ? 1 : 0.5).accessibilityHidden(true)
    }
}

/// Keep AppKit's status button as the click/accessibility target beneath its SwiftUI label.
final class AndroidActivityStatusHostingView: NSHostingView<AndroidActivityStatusLabel> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct AndroidActivityCard: View {
    let presentation: AndroidActivityPresentation
    let onAction: (String) -> Void
    private var foreground: Color { .primary }
    private var secondary: Color { foreground.opacity(0.88) }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation.layout == .progress ? 12 : 14) {
            if presentation.layout == .progress {
                progressHeader
                progressTrack
            } else {
                header
                content
                if !presentation.text("subtitle").isEmpty {
                    AndroidActivityNumericText(text: presentation.text("subtitle")).font(.system(size: 12)).foregroundStyle(secondary)
                }
            }
            if !presentation.actions.isEmpty { actions }
        }
        .padding(presentation.layout == .progress ? 16 : 20)
        .frame(width: 380, alignment: .leading)
        .foregroundStyle(foreground)
        .environment(\.activityTimerEvent, presentation.event)
        // NSPopover supplies the material, arrow, clipping and appearance as one surface.
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.text("app") + " notification")
    }

    // Android's ProgressStyle uses an app-icon column beside title/time and text,
    // with a full-width track and equally sized outlined actions below it.
    private var progressHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            if let icon = presentation.image("appIcon") ?? presentation.image("activityIcon") {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 40, height: 40)
                    .clipShape(Circle()).accessibilityHidden(true)
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit().frame(width: 40, height: 40)
                    .foregroundStyle(presentation.accent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    heading
                    if presentation.event["chronometer"] as? Bool == true || presentation.event["clockPausedMs"] is NSNumber {
                        Text("·").foregroundStyle(secondary)
                        inlineClock
                    }
                    Spacer(minLength: 0)
                }
                if !presentation.text("subtitle").isEmpty {
                    AndroidActivityNumericText(text: presentation.text("subtitle"))
                        .font(.system(size: 14)).foregroundStyle(secondary)
                }
                if !presentation.text("body").isEmpty { textBody.padding(.top, 8) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if presentation.event["canOpen"] as? Bool == true { onAction("open") }
        }
        .accessibilityAction(named: "Open on Phone") {
            if presentation.event["canOpen"] as? Bool == true { onAction("open") }
        }
    }

    private var inlineClock: some View {
        TimelineView(ActivityTimerSchedule(anchors: presentation.event["chronometer"] as? Bool == true ? [presentation.clockAnchor] : [])) { _ in
            AndroidActivityNumericText(text: presentation.clock(now: ActivityClock.now) ?? "",
                countsDown: presentation.event["countDown"] as? Bool == true)
                .font(.system(size: 14)).monospacedDigit().foregroundStyle(secondary)
                .fixedSize()
        }
    }

    @ViewBuilder private var progressTrack: some View {
        if presentation.event["indeterminate"] as? Bool == true {
            ProgressView().progressViewStyle(.linear).tint(presentation.accent).frame(height: 24)
        } else if let progress = presentation.progress {
            AndroidActivityProgress(presentation: presentation, fraction: progress)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = presentation.image("activityIcon") ?? presentation.image("appIcon") {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(presentation.text("app")).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if !presentation.text("status").isEmpty {
                Text("·").foregroundStyle(secondary)
                AndroidActivityNumericText(text: presentation.text("status")).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if presentation.event["canOpen"] as? Bool == true {
                Button { onAction("open") } label: { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("Open on Phone")
            }
        }
        .foregroundStyle(presentation.accent)
    }

    @ViewBuilder private var heading: some View {
        if !presentation.text("title").isEmpty {
            AndroidActivityNumericText(text: presentation.text("title")).font(.system(size: 16, weight: .semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var textBody: some View {
        if !presentation.text("body").isEmpty {
            AndroidActivityNumericText(text: presentation.text("body")).font(.system(size: 14)).foregroundStyle(secondary)
                .lineLimit(12).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 5) { heading; textBody }
    }

    @ViewBuilder private var content: some View {
        switch presentation.layout {
        case .bigPicture:
            textContent
            if let picture = presentation.image("contentImage") {
                Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Notification picture")
            }
        case .inbox:
            heading
            if presentation.lines.isEmpty { textBody }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, line in
                    AndroidActivityNumericText(text: line).font(.system(size: 14)).lineLimit(2)
                }
            }
        case .messaging:
            heading
            ForEach(Array(presentation.messages.enumerated()), id: \.offset) { _, message in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(presentation.accent.opacity(0.22)).frame(width: 30, height: 30)
                        .overlay(Text(String((message["sender"] as? String ?? "?").prefix(1))).font(.system(size: 13, weight: .medium)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message["sender"] as? String ?? "").font(.system(size: 12, weight: .semibold))
                        AndroidActivityNumericText(text: message["text"] as? String ?? "").font(.system(size: 14)).foregroundStyle(secondary).lineLimit(4)
                    }
                }
            }
            if presentation.messages.isEmpty { textBody }
        case .call:
            HStack(alignment: .center, spacing: 14) {
                if let image = presentation.image("contactImage") ?? presentation.image("appIcon") {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: presentation.layout == .call ? 32 : 12))
                }
                textContent
            }
            clock
        case .progress:
            progressHeader
            progressTrack
        case .custom:
            if !presentation.customNodes.isEmpty { customContent } else { textContent }
            clock
        case .standard, .bigText:
            HStack(alignment: .top, spacing: 12) {
                textContent.frame(maxWidth: .infinity, alignment: .leading)
                if let image = presentation.image("contactImage") {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            clock
        }
    }

    @ViewBuilder private var clock: some View {
        if presentation.event["chronometer"] as? Bool == true || presentation.event["clockPausedMs"] is NSNumber {
            TimelineView(ActivityTimerSchedule(anchors: presentation.event["chronometer"] as? Bool == true ? [presentation.clockAnchor] : [])) { _ in
                AndroidActivityNumericText(text: presentation.clock(now: ActivityClock.now) ?? "",
                    countsDown: presentation.event["countDown"] as? Bool == true)
                    .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(presentation.accent)
            }
        }
    }

    private var customContent: some View {
        let height = min(380, max(40, presentation.number("customHeight")))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(presentation.customNodes.enumerated()), id: \.offset) { _, node in
                customNode(node, height: height)
            }
        }.frame(width: 340, height: height)
    }
    @ViewBuilder private func customNode(_ node: [String: Any], height: Double) -> some View {
        let x = (node["x"] as? Double ?? 0) * 340
        let y = (node["y"] as? Double ?? 0) * height
        let width = max(1, (node["width"] as? Double ?? 1) * 340)
        let nodeHeight = max(1, (node["height"] as? Double ?? 0.1) * height)
        if node["kind"] as? String == "progress" {
            ProgressView(value: min(1, max(0, node["progress"] as? Double ?? 0)))
                .tint(presentation.accent).frame(width: width, height: nodeHeight).offset(x: x, y: y)
        } else if let text = node["text"] as? String, !text.isEmpty {
            AndroidActivityNumericText(text: text).font(.system(size: min(32, max(10, node["size"] as? Double ?? 14)),
                weight: node["bold"] as? Bool == true ? .semibold : .regular))
                .foregroundStyle(nodeColor(node)).lineLimit(6)
                .frame(width: width, height: nodeHeight, alignment: .topLeading).offset(x: x, y: y)
        } else if let image = AndroidActivityPresentation.image(node["image"] as? String) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: width, height: nodeHeight).offset(x: x, y: y)
        }
    }
    private func nodeColor(_ node: [String: Any]) -> Color {
        guard let color = node["color"] as? NSNumber else { return foreground }
        let value = color.uint32Value
        let r = Double((value >> 16) & 255) / 255
        let g = Double((value >> 8) & 255) / 255
        let b = Double(value & 255) / 255
        // Android's neutral text ink must follow the Mac surface's appearance too.
        if max(r, g, b) - min(r, g, b) < 0.12 { return foreground }
        return Color(red: r, green: g, blue: b)
    }

    private var actions: some View {
        HStack(spacing: presentation.layout == .progress ? 8 : 12) {
            ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, spec in
                if let id = spec["id"] as? String, let title = spec["title"] as? String {
                    Button { onAction(id) } label: {
                        Text(title).font(.system(size: presentation.layout == .progress ? 15 : 13, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, presentation.layout == .progress ? 8 : 9)
                            .frame(maxWidth: presentation.layout == .progress ? .infinity : nil,
                                minHeight: presentation.layout == .progress ? 40 : nil)
                            .background(presentation.layout == .progress ? Color.clear : presentation.accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(presentation.layout == .progress ? foreground.opacity(0.35) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).foregroundStyle(presentation.layout == .progress ? foreground : presentation.accent)
                        .frame(maxWidth: presentation.layout == .progress ? .infinity : nil)
                }
            }
        }.padding(.top, 2)
    }
}

private struct AndroidActivityProgress: View {
    let presentation: AndroidActivityPresentation
    let fraction: Double
    private var segments: [[String: Any]] { Array((presentation.event["progressSegments"] as? [[String: Any]] ?? []).prefix(12)) }
    private func segmentColor(_ segment: [String: Any]) -> Color {
        guard let number = segment["color"] as? NSNumber, number.uint32Value & 0x00ffffff != 0 else { return presentation.accent }
        let value = number.uint32Value
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var body: some View {
        HStack(spacing: 8) {
            if let image = presentation.image("progressStartIcon") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(presentation.accent.opacity(0.2)).frame(height: 6)
                    if segments.isEmpty {
                        Capsule().fill(presentation.accent).frame(width: max(6, geometry.size.width * fraction), height: 6)
                    } else {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            let start = segments.prefix(index).reduce(0.0) { $0 + (($1["fraction"] as? NSNumber)?.doubleValue ?? 0) }
                            let length = min(1 - min(1, start), max(0, (segment["fraction"] as? NSNumber)?.doubleValue ?? 0))
                            Capsule().fill(segmentColor(segment).opacity(start <= fraction ? 1 : 0.3))
                                .frame(width: max(0, geometry.size.width * length - 2), height: 6)
                                .offset(x: geometry.size.width * min(1, start))
                        }
                    }
                    ForEach(Array((presentation.event["progressPoints"] as? [Double] ?? []).prefix(12).enumerated()), id: \.offset) { _, point in
                        Circle().fill(presentation.accent).frame(width: 8, height: 8)
                            .offset(x: min(geometry.size.width - 8, max(0, geometry.size.width * point)))
                    }
                    if let tracker = presentation.image("progressTrackerIcon") {
                        Image(nsImage: tracker).resizable().scaledToFit().frame(width: 22, height: 22)
                            .offset(x: max(0, min(geometry.size.width - 22, geometry.size.width * fraction - 11)))
                    } else {
                        Circle().fill(presentation.accent).frame(width: 12, height: 12)
                            .offset(x: max(0, min(geometry.size.width - 12, geometry.size.width * fraction - 6)))
                    }
                }.frame(height: 24)
            }.frame(height: 24)
            if let image = presentation.image("progressEndIcon") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
            }
        }
    }
}
