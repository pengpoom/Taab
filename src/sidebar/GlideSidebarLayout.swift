import CoreGraphics
import Foundation

enum GlideSidebarPlacement: String, CaseIterable {
    case off
    case left
    case right
}

enum GlideSidebarIdleMode: String, CaseIterable, Hashable {
    case hidden
    case icons
    case expanded

    var localizedTitle: String {
        switch self {
        case .hidden: return NSLocalizedString("Hide at screen edge", comment: "")
        case .icons: return NSLocalizedString("Show icons only", comment: "")
        case .expanded: return NSLocalizedString("Keep expanded", comment: "")
        }
    }
}

enum GlideSidebarRowVisualState: Equatable {
    case normal
    case hovered
    case focused
    case focusedHovered
}

enum GlideSidebarLayout {
    static let expandedWidth: CGFloat = 188
    static let iconOnlyWidth: CGFloat = 48
    static let hiddenTriggerWidth: CGFloat = 4
    static let edgeMargin: CGFloat = 4
    static let verticalMargin: CGFloat = 8

    static func width(for idleMode: GlideSidebarIdleMode, isPointerInside: Bool) -> CGFloat {
        if isPointerInside || idleMode == .expanded { return expandedWidth }
        switch idleMode {
        case .hidden: return hiddenTriggerWidth
        case .icons: return iconOnlyWidth
        case .expanded: return expandedWidth
        }
    }

    static func rowVisualState(isFocused: Bool, isHovered: Bool) -> GlideSidebarRowVisualState {
        switch (isFocused, isHovered) {
        case (false, false): return .normal
        case (false, true): return .hovered
        case (true, false): return .focused
        case (true, true): return .focusedHovered
        }
    }

    static func hiddenActivationFrame(in visibleFrame: CGRect,
                                      placement: GlideSidebarPlacement) -> CGRect? {
        guard placement != .off else { return nil }
        let x = placement == .left
            ? visibleFrame.minX
            : visibleFrame.maxX - hiddenTriggerWidth
        return CGRect(x: x, y: visibleFrame.minY,
            width: hiddenTriggerWidth, height: visibleFrame.height)
    }

    static func frame(in visibleFrame: CGRect, placement: GlideSidebarPlacement,
                      width requestedWidth: CGFloat = expandedWidth,
                      height requestedHeight: CGFloat? = nil,
                      margin: CGFloat = edgeMargin) -> CGRect? {
        guard placement != .off else { return nil }
        let width = min(requestedWidth, max(0, visibleFrame.width - margin * 2))
        let verticalInset = requestedHeight == nil ? margin : verticalMargin
        let maximumHeight = max(0, visibleFrame.height - verticalInset * 2)
        let height = min(requestedHeight ?? maximumHeight, maximumHeight)
        let x = placement == .left
            ? visibleFrame.minX + margin
            : visibleFrame.maxX - margin - width
        let proposedY = visibleFrame.midY - height / 2
        let y = min(max(proposedY, visibleFrame.minY + verticalInset),
            visibleFrame.maxY - verticalInset - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
