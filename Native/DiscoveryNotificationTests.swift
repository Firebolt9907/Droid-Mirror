import Foundation

@main
struct DiscoveryNotificationTests {
    static func main() {
        var missing = DiscoveryNotificationPolicy()
        precondition(missing.discoveryExpired())
        precondition(!missing.discoveryExpired(), "Retry must not notify again")

        var connected = DiscoveryNotificationPolicy()
        connected.connected()
        precondition(!connected.discoveryExpired(), "Connected launches must not notify")

        var quit = DiscoveryNotificationPolicy()
        quit.stopped()
        precondition(!quit.discoveryExpired(), "Quitting during discovery must not notify")

        missing.connected()
        precondition(!missing.discoveryExpired(), "Recovery must not notify again")
        print("Discovery notification policy tests passed")
    }
}
