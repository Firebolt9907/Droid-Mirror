import AppKit
import SwiftUI

@main
struct AndroidActivityRendererPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/droidmirror-activity-preview")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let pictureRenderer = ImageRenderer(content: ZStack {
            LinearGradient(colors: [.indigo, .blue.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "mountain.2.fill").font(.system(size: 90)).foregroundStyle(.white.opacity(0.75))
        }.frame(width: 340, height: 170))
        let picture = NSBitmapImageRep(cgImage: pictureRenderer.cgImage!).representation(using: .jpeg, properties: [.compressionFactor: 0.7])!.base64EncodedString()
        precondition(AndroidActivityPresentation.image(picture) != nil, "Picture fixture must fit the wire image budget")
        var scoreNodes: [[String: Any]] = [
            ["kind": "image", "x": 0.05, "y": 0.02, "width": 0.15, "height": 0.2],
            ["kind": "text", "text": "24", "size": 28, "x": 0.05, "y": 0.24, "width": 0.15, "height": 0.12],
            ["kind": "text", "text": "TENN", "x": 0.05, "y": 0.4, "width": 0.15, "height": 0.08],
            ["kind": "text", "text": "17", "size": 28, "x": 0.8, "y": 0.24, "width": 0.15, "height": 0.12],
            ["kind": "text", "text": "SC", "x": 0.8, "y": 0.4, "width": 0.15, "height": 0.08],
            ["kind": "text", "text": "2:15 - 4th", "x": 0.35, "y": 0.15, "width": 0.3, "height": 0.1],
            ["kind": "text", "text": "1st & 15", "x": 0.35, "y": 0.28, "width": 0.3, "height": 0.1],
            ["kind": "text", "text": "Receiving Leaders", "x": 0.0, "y": 0.6, "width": 0.7, "height": 0.1]]
        scoreNodes += [
            ["kind": "text", "text": "B. Staley", "x": 0.05, "y": 0.73, "width": 0.4, "height": 0.1, "size": 13],
            ["kind": "text", "text": "5 REC, 50 YDS, 0 TD", "x": 0.52, "y": 0.73, "width": 0.48, "height": 0.1, "size": 12],
            ["kind": "text", "text": "M. Bennett Jr.", "x": 0.05, "y": 0.86, "width": 0.4, "height": 0.1, "size": 13],
            ["kind": "text", "text": "6 REC, 88 YDS, 1 TD", "x": 0.52, "y": 0.86, "width": 0.48, "height": 0.1, "size": 12]]
        func sampleLogo(_ text: String, color: Color) -> String {
            let renderer = ImageRenderer(content: Text(text).font(.system(size: 36, weight: .black, design: .serif))
                .foregroundStyle(color).frame(width: 60, height: 60))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!.base64EncodedString()
        }
        scoreNodes[0]["image"] = sampleLogo("T", color: .white)
        scoreNodes[0]["sportsTeam"] = 1; scoreNodes[0]["sportsField"] = "logo"
        scoreNodes[0]["y"] = 0.3 // Regression: logo is below the score's top edge.
        scoreNodes.append(["kind": "image", "sportsTeam": 2, "sportsField": "logo", "x": 0.8, "y": 0.3, "width": 0.15, "height": 0.2,
                           "image": sampleLogo("SC", color: Color(red: 0.72, green: 0.5, blue: 0.55))])
        scoreNodes.append(["kind": "indicator", "sportsTeam": 1, "sportsField": "possession"])
        scoreNodes[5]["sportsField"] = "statusPrimary"
        scoreNodes[6]["sportsField"] = "statusSecondary"
        scoreNodes[6]["text"] = "2nd & Goal\nWIS 8"
        scoreNodes[3]["color"] = 4290678949
        let sportsEvent: [String: Any] = ["app": "ESPN", "layout": "custom", "customNodes": scoreNodes, "customHeight": 260.0, "canOpen": true]
        func sportEvent(_ name: String, left: String, right: String, scores: (String, String), primary: String, secondary: String, turn: String?, side: Int = 1) -> [String: Any] {
            var nodes = scoreNodes.filter { $0["kind"] as? String != "indicator" }
            nodes[0]["image"] = sampleLogo(String(left.prefix(1)), color: .red)
            nodes[1].merge(["sportsTeam": 1, "sportsField": "score", "text": scores.0]) { _, n in n }
            nodes[2].merge(["sportsTeam": 1, "sportsField": "name", "text": left]) { _, n in n }
            nodes[3].merge(["sportsTeam": 2, "sportsField": "score", "text": scores.1]) { _, n in n }
            nodes[4].merge(["sportsTeam": 2, "sportsField": "name", "text": right]) { _, n in n }
            nodes[5]["text"] = primary; nodes[6]["text"] = secondary
            if let i = nodes.firstIndex(where: { ($0["sportsTeam"] as? Int) == 2 && $0["sportsField"] as? String == "logo" }) {
                nodes[i]["image"] = sampleLogo(String(right.prefix(1)), color: .yellow)
            }
            if name == "football" || name == "baseball" {
                nodes[7]["text"] = name == "football" ? "Rushing Leaders" : "Batting Leaders"
                nodes[7]["sportsField"] = "note"
                nodes[8].merge(["sportsField": "playerName", "sportsRow": 1, "text": name == "football" ? "C. Joseph" : "R. Devers"]) { _, n in n }
                nodes[9].merge(["sportsField": "playerStats", "sportsRow": 1, "text": name == "football" ? "2 CAR, -2 YDS, 0 TD" : "2 HITS, 1 RBI"]) { _, n in n }
                nodes[10].merge(["sportsField": "playerName", "sportsRow": 2, "text": name == "football" ? "X. Williams" : "A. Judge"]) { _, n in n }
                nodes[11].merge(["sportsField": "playerStats", "sportsRow": 2, "text": name == "football" ? "6 CAR, 16 YDS, 0 TD" : "1 HIT, 1 RBI"]) { _, n in n }
            } else { nodes.removeSubrange(7...11) }
            if let turn { nodes.append(["kind": "indicator", "sportsTeam": side, "sportsField": turn]) }
            var event = sportsEvent
            event["id"] = name; event["version"] = "v1"; event["customNodes"] = nodes
            return event
        }
        let fieldHistory = ActivitySportsHistory()
        _ = fieldHistory.observe(sportEvent("football", left: "WIS", right: "IOWA", scores: ("0", "3"), primary: "1st 2:20", secondary: "1st & 10\nIOWA 15", turn: "possession"))
        var football = sportEvent("football", left: "WIS", right: "IOWA", scores: ("0", "3"), primary: "1st 2:13", secondary: "1st & Goal\nIOWA 8", turn: "possession")
        football["version"] = "v2"
        football = fieldHistory.observe(football)
        let baseRenderer = ImageRenderer(content: Canvas { context, size in
            let points = [CGPoint(x: 28, y: 2), CGPoint(x: 51, y: 15), CGPoint(x: 28, y: 29), CGPoint(x: 5, y: 15)]
            var diamond = Path(); diamond.addLines(points); diamond.closeSubpath()
            context.stroke(diamond, with: .color(.white.opacity(0.65)), lineWidth: 1)
            for (i, p) in points.prefix(3).enumerated() {
                let rect = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                context.fill(Path(rect), with: .color(i == 0 || i == 1 ? .yellow : .gray))
            }
        }.frame(width: 56, height: 32))
        baseRenderer.scale = 2
        let basePNG = NSBitmapImageRep(cgImage: baseRenderer.cgImage!).representation(using: .png, properties: [:])!.base64EncodedString()
        var baseball = sportEvent("baseball", left: "BOS", right: "NYY", scores: ("3", "1"), primary: "Top 7th", secondary: "2 outs\n2-1 count", turn: "batting", side: 2)
        var baseballNodes = baseball["customNodes"] as! [[String: Any]]
        baseballNodes.append(["kind": "image", "sportsField": "bases", "image": basePNG])
        baseball["customNodes"] = baseballNodes
        var tennis = sportEvent("tennis", left: "Player A", right: "Player B", scores: ("AD", "40"), primary: "3rd set", secondary: "", turn: "serving")
        var tennisNodes = tennis["customNodes"] as! [[String: Any]]
        tennisNodes.append(["kind": "text", "sportsField": "setScore", "sportsTeam": 1, "text": "6 3"])
        tennisNodes.append(["kind": "text", "sportsField": "setScore", "sportsTeam": 2, "text": "4 6"])
        tennis["customNodes"] = tennisNodes
        var pregame = sportEvent("pregame", left: "ND", right: "NAVY", scores: ("", ""), primary: "12:00 PM", secondary: "", turn: nil)
        var pregameNodes = pregame["customNodes"] as! [[String: Any]]
        pregameNodes.append(["kind": "text", "sportsField": "broadcast", "text": "ABC"])
        pregame["customNodes"] = pregameNodes
        var sportCards = [AnyView]()
        for (name, event) in [("football", football), ("baseball", baseball), ("tennis", tennis), ("pregame", pregame)] {
            let model = AndroidActivityCardModel(AndroidActivityPresentation(event: event, clockAnchor: 0))
            let view = VStack(spacing: 8) {
                Text("Sample source data · " + name).font(.system(size: 11)).foregroundStyle(.secondary)
                AndroidActivityHostedCard(model: model, onAction: { _, _ in })
            }.padding(16).environment(\.colorScheme, .dark).background(Color(white: 0.15))
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            try NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
                .write(to: destination.appendingPathComponent("sport-" + name + ".png"))
            sportCards.append(AnyView(view))
        }
        let sportGallery = HStack(alignment: .top, spacing: 16) { ForEach(Array(sportCards.enumerated()), id: \.offset) { _, card in card } }
        let sportRenderer = ImageRenderer(content: sportGallery); sportRenderer.scale = 1.5
        try NSBitmapImageRep(cgImage: sportRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("sports-context-gallery.png"))
        let sportsModel = AndroidActivityCardModel(AndroidActivityPresentation(event: sportsEvent, clockAnchor: 0))
        let sportsStatus = AndroidActivityStatusModel()
        sportsStatus.event = sportsEvent
        var goldNodes = scoreNodes
        goldNodes[0]["image"] = sampleLogo("ND", color: Color(red: 0.82, green: 0.65, blue: 0.02))
        if let index = goldNodes.firstIndex(where: { ($0["sportsTeam"] as? Int) == 2 && $0["sportsField"] as? String == "logo" }) {
            goldNodes[index]["image"] = sampleLogo("N", color: Color(red: 0.82, green: 0.77, blue: 0.57))
        }
        let goldStatus = AndroidActivityStatusModel()
        var goldEvent = sportsEvent
        goldEvent["customNodes"] = goldNodes
        goldStatus.event = goldEvent
        for dark in [true, false] {
            let contrastPreview = HStack(spacing: 24) {
                AndroidActivityStatusLabel(model: goldStatus).frame(width: ActivityCompactScoreLayout.itemWidth(ActivityScoreboard(event: goldStatus.event)!), height: 24)
                AndroidActivityStatusLabel(model: sportsStatus).frame(width: ActivityCompactScoreLayout.itemWidth(ActivityScoreboard(event: sportsStatus.event)!), height: 24)
            }.padding(24).environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(white: dark ? 0.35 : 0.8))
            let renderer = ImageRenderer(content: contrastPreview)
            renderer.scale = 3
            try NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
                .write(to: destination.appendingPathComponent(dark ? "compact-gold-dark.png" : "compact-gold-light.png"))
        }
        let scoreCases = [("0", "3"), ("9", "10"), ("24", "99"), ("100", "103"), ("999", "999")]
        let widthModels = scoreCases.map { scores -> AndroidActivityStatusModel in
            let model = AndroidActivityStatusModel()
            var nodes = scoreNodes
            nodes[1]["text"] = scores.0; nodes[3]["text"] = scores.1
            var event = sportsEvent; event["customNodes"] = nodes
            model.event = event
            return model
        }
        let widthPreview = VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(widthModels.enumerated()), id: \.offset) { _, model in
                AndroidActivityStatusLabel(model: model)
                    .frame(width: ActivityCompactScoreLayout.itemWidth(ActivityScoreboard(event: model.event)!), height: 24)
            }
        }.padding(24).environment(\.colorScheme, .dark).background(Color(white: 0.35))
        let widthRenderer = ImageRenderer(content: widthPreview)
        widthRenderer.scale = 3
        try NSBitmapImageRep(cgImage: widthRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("compact-score-widths.png"))
        let sportsPreview = VStack(spacing: 24) {
            Text("Sample scoreboard · notification data").font(.system(size: 11)).foregroundStyle(.secondary)
            AndroidActivityStatusLabel(model: sportsStatus).frame(width: ActivityCompactScoreLayout.itemWidth(ActivityScoreboard(event: sportsStatus.event)!), height: 24)
                .padding(8)
            AndroidActivityHostedCard(model: sportsModel, onAction: { _, _ in }).clipShape(RoundedRectangle(cornerRadius: 24))
        }.padding(24).environment(\.colorScheme, .dark).background(Color(white: 0.12))
        let sportsRenderer = ImageRenderer(content: sportsPreview)
        sportsRenderer.scale = 2
        try NSBitmapImageRep(cgImage: sportsRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("scoreboard.png"))
        let fixtures: [(String, [String: Any])] = [
            ("bigPicture", ["app": "Trip", "title": "Your destination is ready", "body": "Offline map downloaded", "layout": "bigPicture", "contentImage": picture]),
            ("progress", ["app": "Maps", "title": "Turn right onto Market Street", "body": "In 400 ft · Arrive at 8:42 PM", "layout": "progress", "status": "12 min", "progressMax": 100, "progressValue": 62,
                "progressSegments": [["fraction": 0.4, "color": 4284989308], ["fraction": 0.35, "color": 4284246973], ["fraction": 0.25, "color": 4289003775]], "progressPoints": [0.4, 0.75], "actions": [["id": "0", "title": "Exit navigation"]]]),
            ("timer", ["app": "Clock", "title": "Pasta timer", "body": "Timer", "layout": "standard", "chronometer": true, "countDown": true, "actions": [["id": "0", "title": "Pause"], ["id": "1", "title": "Add 1 min"]]]),
            ("bigText", ["app": "Delivery", "title": "Your order is on its way", "body": "Jamie has picked up your order and is heading your way. Your food should arrive between 8:35 and 8:45 PM.", "layout": "bigText", "actions": [["id": "0", "title": "Track order"]]]),
            ("inbox", ["app": "Downloads", "title": "3 downloads in progress", "layout": "inbox", "lines": ["Trip photos.zip · 42%", "Boarding pass.pdf · Waiting", "Offline map · 85%"], "actions": [["id": "0", "title": "Pause all"]]]),
            ("call", ["app": "Phone", "title": "Alex Morgan", "body": "Ongoing call", "layout": "call", "chronometer": true, "actions": [["id": "0", "title": "Hang up"], ["id": "1", "title": "Mute"]]]),
            ("messaging", ["app": "Messages", "title": "Trip planning", "layout": "messaging", "messages": [["sender": "Alex", "text": "The tickets are booked!"], ["sender": "Sam", "text": "See you at the station at 9."]]]),
            ("custom", ["app": "Recorder", "layout": "custom", "customHeight": 72, "customNodes": [["kind": "text", "text": "Recording audio", "x": 0.0, "y": 0.0, "width": 1.0, "height": 0.35, "size": 16.0, "bold": true], ["kind": "text", "text": "03:42", "x": 0.0, "y": 0.5, "width": 0.5, "height": 0.5, "size": 24.0]], "actions": [["id": "0", "title": "Stop"], ["id": "1", "title": "Pause"]]])
        ]
        let iconRenderer = ImageRenderer(content: ZStack {
            Circle().fill(.black)
            Text("W").font(.system(size: 30, weight: .black)).foregroundStyle(.white)
        }.frame(width: 40, height: 40))
        let icon = NSBitmapImageRep(cgImage: iconRenderer.cgImage!).representation(using: .png, properties: [:])!.base64EncodedString()
        let matched: [String: Any] = ["app": "Walkcloser", "title": "Runner", "subtitle": "Head start", "body": "1 runner left",
            "layout": "progress", "chronometer": true, "countDown": true, "canOpen": true, "appIcon": icon,
            "progressTrackerIcon": icon, "progressMax": 1000, "progressValue": 80, "accentColor": 4281949132,
            "progressSegments": [["fraction": 0.1, "color": 4287601854], ["fraction": 0.9, "color": 4281949132]],
            "actions": [["id": "0", "title": "Caught"], ["id": "1", "title": "Map"], ["id": "2", "title": "Leave"]]]
        var embeddedSample = matched
        let secondaryText = "1 runner left · Reveal in 00:16\nZone shrinks in 00:16"
        embeddedSample["subtitle"] = ""
        embeddedSample["body"] = secondaryText
        embeddedSample["countDown"] = false
        embeddedSample["_timersReceivedAt"] = ActivityClock.now
        let secondarySource = secondaryText as NSString
        let ranges = try NSRegularExpression(pattern: "00:16").matches(in: secondaryText, range: NSRange(location: 0, length: secondarySource.length))
        embeddedSample["embeddedTimers"] = ranges.map { match in
            ["hash": ActivityEmbeddedText.hash(secondaryText), "start": match.range.location,
             "end": match.range.location+match.range.length, "token": "00:16", "seconds": 16.0,
             "down": true, "hours": false, "width": 2] as [String: Any]
        }
        let embeddedCard = VStack(alignment: .leading, spacing: 8) {
            Text("Sample layout • not live phone data").font(.system(size: 11)).padding(.horizontal, 16)
            AndroidActivityCard(presentation: AndroidActivityPresentation(event: embeddedSample, clockAnchor: ActivityClock.now - 1511), onAction: { _ in })
        }.environment(\.colorScheme, .dark).padding(.vertical, 12).background(Color(white: 0.14))
        let embeddedRenderer = ImageRenderer(content: embeddedCard)
        embeddedRenderer.scale = 2
        try NSBitmapImageRep(cgImage: embeddedRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("embedded-timers.png"))
        let comparison = VStack(alignment: .leading, spacing: 8) {
            Text("Sample layout • not live phone data").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16)
            AndroidActivityCard(presentation: AndroidActivityPresentation(event: matched, clockAnchor: ActivityClock.now + 126), onAction: { _ in })
        }.environment(\.colorScheme, .dark).padding(.vertical, 12).background(Color(white: 0.14))
        let comparisonRenderer = ImageRenderer(content: comparison)
        comparisonRenderer.scale = 2
        try NSBitmapImageRep(cgImage: comparisonRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("android-progress-layout.png"))
        let safety: [String: Any] = ["app": "Sample", "title": "Game safety check",
            "body": "Open game to respond to the safety check", "layout": "progress", "appIcon": icon,
            "progressMax": 100, "progressValue": 30,
            "actions": [["id": "0", "title": "Caught"], ["id": "1", "title": "Map"], ["id": "2", "title": "Leave"]]]
        for dark in [true, false] {
            let model = AndroidActivityCardModel(AndroidActivityPresentation(event: safety, clockAnchor: ActivityClock.now))
            let legibility = VStack(spacing: 16) {
                Text("Sample contrast check • simulated bright and dark backdrops")
                    .font(.system(size: 10)).foregroundStyle(dark ? Color.white : Color.black)
                ForEach([1.0, 0.0], id: \.self) { brightness in
                    AndroidActivityHostedCard(model: model, onAction: { _, _ in })
                        .background(Color(white: brightness))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }.padding(16).background(dark ? Color(white: 0.15) : Color(white: 0.85))
                .environment(\.colorScheme, dark ? .dark : .light)
            let rendered = ImageRenderer(content: legibility)
            rendered.scale = 2
            try NSBitmapImageRep(cgImage: rendered.cgImage!).representation(using: .png, properties: [:])!
                .write(to: destination.appendingPathComponent(dark ? "contrast-dark.png" : "contrast-light.png"))
        }
        var cards = [AnyView]()
        for (name, event) in fixtures {
            var supplied = event
            supplied["app"] = "Sample · " + (event["app"] as? String ?? "Android")
            supplied["canOpen"] = true
            supplied["accentColor"] = 4289434879
            let anchor = ActivityClock.now + (name == "timer" ? 217 : -142)
            let card = AndroidActivityCard(presentation: AndroidActivityPresentation(event: supplied, clockAnchor: anchor), onAction: { _ in })
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Could not render \(name)") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
            cards.append(AnyView(card))
        }
        let gallery = HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 20) { ForEach(Array(cards.prefix(4).enumerated()), id: \.offset) { _, card in card } }
            VStack(spacing: 20) { ForEach(Array(cards.dropFirst(4).enumerated()), id: \.offset) { _, card in card } }
        }.padding(24).background(Color(white: 0.08))
        let renderer = ImageRenderer(content: gallery)
        renderer.scale = 1.5
        guard let image = renderer.cgImage else { fatalError("Could not render gallery") }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("gallery.png"))
        print("Rendered \(fixtures.count) Android-style native cards in \(destination.path)")
    }
}
