import Foundation
import SwiftUI

@main
struct PhoneAppearanceTests {
    static func main() {
        let square = PhoneScreenShape(topRatio: 0, bottomRatio: 0).path(in: CGRect(x: 0, y: 0, width: 360, height: 800))
        assert(square.contains(CGPoint(x: 1, y: 1)))
        for width in [180.0, 360, 720] {
            let height = width * 2
            let shape = PhoneScreenShape(topRatio: 0.1, bottomRatio: 0.05).path(in: CGRect(x: 0, y: 0, width: width, height: height))
            assert(shape.contains(CGPoint(x: width / 2, y: 1)))
            assert(shape.contains(CGPoint(x: 1, y: height / 2)))
            assert(shape.contains(CGPoint(x: width - 1, y: height / 2)))
            assert(shape.contains(CGPoint(x: width / 2, y: height - 1)))
            assert(!shape.contains(CGPoint(x: 1, y: 1)))
            assert(!shape.contains(CGPoint(x: width - 1, y: 1)))
            assert(!shape.contains(CGPoint(x: 1, y: height - 1)))
            assert(!shape.contains(CGPoint(x: width - 1, y: height - 1)))
            // Asymmetric physical radii remain asymmetric in the fallback.
            assert(!shape.contains(CGPoint(x: width * 0.02, y: width * 0.02)))
            assert(shape.contains(CGPoint(x: width * 0.02, y: height - width * 0.02)))
        }
        print("PASS: fallback silhouette preserves all four edges, square phones, asymmetric radii and resizing")
    }
}
