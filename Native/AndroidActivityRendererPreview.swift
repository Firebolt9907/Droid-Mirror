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
