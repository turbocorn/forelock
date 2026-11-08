import AppKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = folder.deletingLastPathComponent()
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
func black(_ image: NSBitmapImageRep, _ x: Int) -> Bool {
    guard let c = image.colorAt(x: x, y: 2)?.usingColorSpace(.deviceRGB) else { return false }
    return max(c.redComponent, c.greenComponent, c.blueComponent) <= 0.012
}
var measurements: [(URL, Double)] = []
for file in files {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: file)) else { continue }
    // The native control tool draws a cursor halo that can cross the top scanline.
    // Use both outer black edges rather than a contiguous run through that halo.
    let samples = (0..<image.pixelsWide).filter { black(image, $0) }
    guard let left = samples.first, let right = samples.last else { measurements.append((file, 0)); continue }
    measurements.append((file, Double(right - left + 1) / 2))
}
var selected: [[String: Any]] = []
for (name, target, low, high) in [("hover-top", 420.0, 419.0, 422.0), ("transition-early-top", 500.0, 440.0, 600.0),
                                  ("transition-top", 650.0, 480.0, 840.0), ("transition-late-top", 820.0, 700.0, 890.0),
                                  ("expanded-top", 900.0, 899.0, 902.0)] {
    let destination = output.appendingPathComponent(name + ".png")
    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    if let frame = measurements.filter({ $0.1 >= low && $0.1 <= high }).min(by: { abs($0.1 - target) < abs($1.1 - target) }) {
        try FileManager.default.copyItem(at: frame.0, to: destination)
        selected.append(["output": destination.lastPathComponent, "source": frame.0.lastPathComponent, "topWidthPoints": frame.1])
    }
}
let report: [String: Any] = ["method": "Original WindowServer PNGs, byte-for-byte copies; Outer black edges at display y=1pt; cursor-halo holes excluded", "selected": selected,
                             "frames": measurements.map { ["file": $0.0.lastPathComponent, "topWidthPoints": $0.1] }]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.appendingPathComponent("transition-audit.json"))
print(String(data: try JSONSerialization.data(withJSONObject: selected, options: .prettyPrinted), encoding: .utf8)!)
print("Distinct top widths:", Array(Set(measurements.map { Int($0.1.rounded()) })).sorted())
