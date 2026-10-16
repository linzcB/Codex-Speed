import Foundation
import CoreGraphics

public enum ScreenPlacement {
    /// Place the top of the dropdown below its menu-bar button, then constrain
    /// the entire frame to this display's usable area (not the main display).
    public static func dropdown(anchor: CGRect, visible: CGRect, size: CGSize) -> CGRect {
        let usable = visible.insetBy(dx: 8, dy: 8)
        // Status-item windows can temporarily report an origin at (0, 0)
        // during launch. The menu bar is always at this display's top edge;
        // never use that unfinished Y coordinate to calculate available height.
        let top = usable.maxY
        let width = min(size.width, max(1, usable.width))
        let height = min(size.height, max(1, top - usable.minY))
        let left = min(max(anchor.midX - width / 2, usable.minX), usable.maxX - width)
        return CGRect(x: left, y: top - height, width: width, height: height)
    }

    public static func constrained(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let usable = visible.insetBy(dx: 8, dy: 8)
        let width = min(frame.width, max(1, usable.width))
        let height = min(frame.height, max(1, usable.height))
        return CGRect(x: min(max(frame.minX, usable.minX), usable.maxX - width),
                      y: min(max(frame.minY, usable.minY), usable.maxY - height),
                      width: width, height: height)
    }
}
