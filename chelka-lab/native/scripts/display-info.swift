import AppKit
import CoreGraphics
for screen in NSScreen.screens {
  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  print("display=\(number?.uint32Value ?? 0) builtin=\(number.map { CGDisplayIsBuiltin($0.uint32Value) } ?? 0) name=\(screen.localizedName) frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor) safe=\(screen.safeAreaInsets) left=\(String(describing: screen.auxiliaryTopLeftArea)) right=\(String(describing: screen.auxiliaryTopRightArea))")
}
