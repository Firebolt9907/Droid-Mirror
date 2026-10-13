import Foundation

@main
struct PairingKeyCacheTests {
    static func main() {
        let key = Data(repeating: 7, count: 32)
        var cache = PairingKeyCache(), reads = 0
        for _ in 0..<100 {
            precondition(cache.value { reads += 1; return key } == key)
        }
        precondition(reads == 1)
        cache = PairingKeyCache(); reads = 0
        for _ in 0..<100 { precondition(cache.value { reads += 1; return nil } == nil) }
        precondition(reads == 1, "Denial must not trigger repeated prompts")
        cache.store(key)
        precondition(cache.value { fatalError("Cached save must not read Keychain") } == key)
        print("Pairing key cache tests passed")
    }
}
