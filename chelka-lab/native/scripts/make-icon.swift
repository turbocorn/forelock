import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.84, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 210, yRadius: 210).fill()
NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.055, alpha: 1).setFill()
let p = NSBezierPath()
p.move(to: NSPoint(x: 180, y: 732)); p.line(to: NSPoint(x: 844, y: 732))
p.line(to: NSPoint(x: 844, y: 485)); p.curve(to: NSPoint(x: 680, y: 326), controlPoint1: NSPoint(x: 844, y: 385), controlPoint2: NSPoint(x: 780, y: 326))
p.line(to: NSPoint(x: 344, y: 326)); p.curve(to: NSPoint(x: 180, y: 485), controlPoint1: NSPoint(x: 244, y: 326), controlPoint2: NSPoint(x: 180, y: 385)); p.close(); p.fill()
NSColor(calibratedRed: 0.73, green: 0.85, blue: 0.58, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 694, y: 568, width: 47, height: 47)).fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
