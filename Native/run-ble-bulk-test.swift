#!/usr/bin/env swift
import Foundation

// An explicit local diagnostic request, serviced only by the authenticated background receiver.
var config: [String: Any] = ["id": UUID().uuidString, "transport": "l2cap", "bytes": 1_048_576, "window": 0]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let option = args.removeFirst()
    guard !args.isEmpty, ["--transport", "--bytes", "--window"].contains(option) else {
        fputs("Usage: swift Native/run-ble-bulk-test.swift [--transport l2cap|gatt|iroh] [--bytes 1..4000000] [--window 0|1|8|32]\n", stderr); exit(2)
    }
    let value = args.removeFirst(), key = String(option.dropFirst(2))
    if key == "transport" { config[key] = value }
    else { guard let number = Int(value) else { exit(2) }; config[key] = number }
}
guard let bytes = config["bytes"] as? Int, (1...4_000_000).contains(bytes),
      let window = config["window"] as? Int, [0, 1, 8, 32].contains(window),
      let transport = config["transport"] as? String, ["l2cap", "gatt", "iroh"].contains(transport) else { exit(2) }
let center = DistributedNotificationCenter.default()
var done = false
let observer = center.addObserver(forName: Notification.Name("app.droidmirror.bulkTestResult"), object: nil, queue: .main) { event in
    guard let result = event.userInfo as? [String: Any], result["id"] as? String == config["id"] as? String else { return }
    if let json = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: json, encoding: .utf8) {
        print(text); fflush(stdout)
    }
    done = true
    if result["success"] as? Bool != true { exit(1) }
}
center.postNotificationName(Notification.Name("app.droidmirror.bulkTest"), object: nil, userInfo: config, deliverImmediately: true)
let deadline = Date().addingTimeInterval(190)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
center.removeObserver(observer)
if !done { fputs("No benchmark result before deadline. Ensure the background receiver is running and authenticated.\n", stderr); exit(1) }
