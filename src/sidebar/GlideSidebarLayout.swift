import CoreGraphics

enum GlideSidebarPlacement: String, CaseIterable {
    case off
    case left
    case right
}

enum GlideSidebarLayout {
    static let preferredWidth: CGFloat = 260
    static let edgeMargin: CGFloat = 8

    static func frame(in visibleFrame: CGRect, placement: GlideSidebarPlacement) -> CGRect? {
        guard placement != .off else { return nil }
        let width = min(preferredWidth, max(0, visibleFrame.width - edgeMargin * 2))
        let height = max(0, visibleFrame.height - edgeMargin * 2)
        let x = placement == .left
            ? visibleFrame.minX + edgeMargin
            : visibleFrame.maxX - edgeMargin - width
        return CGRect(x: x, y: visibleFrame.minY + edgeMargin, width: width, height: height)
    }
}
