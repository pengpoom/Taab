import Cocoa

enum GlideDockEdge: Equatable {
    case bottom
    case left
    case right
}

/// Controls which Dock apps are eligible for a hover preview. The decision is made after
/// Taab has collected the app's actionable windows, but before any thumbnails are captured.
enum GlideDockHoverPreviewMode: String, CaseIterable, Hashable {
    case allApps
    case multipleWindowsOnly
    case disabled

    var localizedTitle: String {
        switch self {
        case .allApps: return NSLocalizedString("All apps with windows", comment: "")
        case .multipleWindowsOnly: return NSLocalizedString("Only apps with multiple windows", comment: "")
        case .disabled: return NSLocalizedString("No previews", comment: "")
        }
    }

    func shouldShowPreview(windowCount: Int) -> Bool {
        switch self {
        case .allApps: return windowCount >= 1
        case .multipleWindowsOnly: return windowCount >= 2
        case .disabled: return false
        }
    }
}

/// Coordinate and panel-placement rules shared by the live Dock preview and unit tests.
/// CGEvent/AX use a primary-screen top-left origin; AppKit windows use a primary-screen bottom-left origin.
enum GlideDockHoverLayout {
    static func appKitPoint(fromQuartz point: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    static func appKitRect(fromQuartz rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func quartzRect(fromAppKit rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func edge(for iconFrame: CGRect, in screenFrame: CGRect) -> GlideDockEdge {
        let left = abs(iconFrame.minX - screenFrame.minX)
        let right = abs(screenFrame.maxX - iconFrame.maxX)
        let bottom = abs(iconFrame.minY - screenFrame.minY)
        if left <= right, left <= bottom { return .left }
        if right <= left, right <= bottom { return .right }
        return .bottom
    }

    static func panelFrame(iconFrame: CGRect, screenFrame: CGRect, visibleFrame: CGRect,
                           panelSize: CGSize, edge: GlideDockEdge,
                           gap: CGFloat = 10, margin: CGFloat = 10) -> CGRect {
        var origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: iconFrame.midX - panelSize.width / 2,
                y: max(iconFrame.maxY + gap, visibleFrame.minY + margin))
        case .left:
            origin = CGPoint(x: max(iconFrame.maxX + gap, visibleFrame.minX + margin),
                y: iconFrame.midY - panelSize.height / 2)
        case .right:
            origin = CGPoint(x: min(iconFrame.minX - gap - panelSize.width,
                    visibleFrame.maxX - panelSize.width - margin),
                y: iconFrame.midY - panelSize.height / 2)
        }

        let bounds = visibleFrame.isEmpty ? screenFrame : visibleFrame
        let minimumX = bounds.minX + margin
        let maximumX = max(minimumX, bounds.maxX - panelSize.width - margin)
        let minimumY = bounds.minY + margin
        let maximumY = max(minimumY, bounds.maxY - panelSize.height - margin)
        origin.x = min(maximumX, max(minimumX, origin.x))
        origin.y = min(maximumY, max(minimumY, origin.y))
        return CGRect(origin: origin, size: panelSize)
    }

    /// A small bridge between the Dock icon and the panel prevents the preview disappearing while the pointer
    /// crosses the gap. It is deliberately bounded to the union of those two frames, not an entire Dock row.
    static func transitionRegion(iconFrame: CGRect, panelFrame: CGRect, padding: CGFloat = 8) -> CGRect {
        iconFrame.union(panelFrame).insetBy(dx: -padding, dy: -padding)
    }
}
