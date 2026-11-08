import AppKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var report: [String: Any] = [:]
for name in ["before-top", "hover-top", "expanded-top"] {
    let image = NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent(name + ".png")))!
    // x=810 pt is inside the SDK-reported camera area (790...1010),
    // away from cursor/text. The image is a real 2x WindowServer capture.
    let connected = (0..<100).allSatisfy { y in
        guard let color = image.colorAt(x: 1620, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return max(color.redComponent, color.greenComponent, color.blueComponent) <= 0.01
    }
    report[name] = ["sizePixels": [image.pixelsWide, image.pixelsHigh], "blackConnectionFromScreenTopThrough50pt": connected]
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: folder.appendingPathComponent("screenshot-audit.json"))
print(String(data: data, encoding: .utf8)!)
