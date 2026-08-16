import Cocoa

/// Settings for the Taab-specific features layered on top of the window switcher.
/// Keeping them in one first-class page avoids scattering controls across the inherited tabs.
final class TaabTab {
    private static var dockClickToggle: Switch?
    private static var dockHoverPopup: NSPopUpButton?
    private static var displayPopups = [String: NSPopUpButton]()

    static func initTab() -> NSView {
        let dockTable = TableGroupView(
            title: NSLocalizedString("Dock behavior", comment: ""),
            subTitle: NSLocalizedString("Choose how Taab augments the macOS Dock.", comment: ""),
            width: SettingsWindow.contentWidth)

        let hoverModes = GlideDockHoverPreviewMode.allCases
        let hoverPopup = PopupButtonLikeSystemSettings()
        let hoverTitles = hoverModes.map(\.localizedTitle)
        hoverPopup.addItems(withTitles: hoverTitles)
        hoverPopup.selectItem(at: hoverModes.firstIndex(of: GlideDockHoverPreviewController.shared.currentMode) ?? 1)
        hoverPopup.onAction = { control in
            guard let popup = control as? NSPopUpButton,
                  let mode = hoverModes[safe: popup.indexOfSelectedItem] else { return }
            Preferences.set(GlideDockHoverPreviewController.preferenceKey, mode.rawValue)
        }
        SettingsSearchIndex.registerStrings(hoverTitles)
        SettingsSearchIndex.registerTarget(SettingsWindow.highlightTarget(hoverPopup))
        dockHoverPopup = hoverPopup
        dockTable.addRow(TableGroupView.Row(
            leftTitle: NSLocalizedString("Window previews on hover", comment: ""),
            subTitle: NSLocalizedString("Choose which Dock apps show window thumbnails when the pointer rests on their icon.", comment: ""),
            rightViews: [hoverPopup]))

        let clickToggle = LabelAndControl.makeSwitch(GlideDockClickMonitor.preferenceKey)
        dockClickToggle = clickToggle
        dockTable.addRow(TableGroupView.Row(
            leftTitle: NSLocalizedString("Windows-style Dock clicks", comment: ""),
            subTitle: NSLocalizedString("Click an active app to minimize its window; click again to restore it.", comment: ""),
            rightViews: [clickToggle]))

        let sidebarTable = TableGroupView(
            title: NSLocalizedString("Window sidebars", comment: ""),
            subTitle: NSLocalizedString("Choose a position independently for each connected display.", comment: ""),
            width: SettingsWindow.contentWidth)
        let placements = GlideSidebarPlacement.allCases
        let placementTitles = placements.map(placementTitle)
        SettingsSearchIndex.registerStrings(placementTitles)
        for setting in GlideSidebarCoordinator.shared.displaySettings() {
            let popup = PopupButtonLikeSystemSettings()
            placementTitles.forEach { popup.addItem(withTitle: $0) }
            popup.selectItem(at: placements.firstIndex(of: setting.placement) ?? 0)
            popup.onAction = { control in
                guard let popup = control as? NSPopUpButton,
                      let placement = placements[safe: popup.indexOfSelectedItem] else { return }
                GlideSidebarCoordinator.shared.setPlacement(placement, for: setting.identifier)
            }
            SettingsSearchIndex.registerTarget(SettingsWindow.highlightTarget(popup))
            displayPopups[setting.identifier] = popup
            sidebarTable.addRow(leftText: setting.title, rightViews: popup)
        }

        refreshControlsFromPreferences()
        return TableGroupSetView(
            originalViews: [dockTable, sidebarTable],
            padding: 0,
            bottomPadding: 0)
    }

    static func refreshControlsFromPreferences() {
        dockClickToggle?.state = CachedUserDefaults.bool(GlideDockClickMonitor.preferenceKey) ? .on : .off
        if let index = GlideDockHoverPreviewMode.allCases.firstIndex(of: GlideDockHoverPreviewController.shared.currentMode) {
            dockHoverPopup?.selectItem(at: index)
        }
        let placementsByDisplay = Dictionary(uniqueKeysWithValues:
            GlideSidebarCoordinator.shared.displaySettings().map { ($0.identifier, $0.placement) })
        for (identifier, popup) in displayPopups {
            guard let placement = placementsByDisplay[identifier],
                  let index = GlideSidebarPlacement.allCases.firstIndex(of: placement) else { continue }
            popup.selectItem(at: index)
        }
    }

    static func cleanup() {
        dockClickToggle = nil
        dockHoverPopup = nil
        displayPopups.removeAll()
    }

    private static func placementTitle(_ placement: GlideSidebarPlacement) -> String {
        switch placement {
        case .off: return NSLocalizedString("Off", comment: "")
        case .left: return NSLocalizedString("Left", comment: "")
        case .right: return NSLocalizedString("Right", comment: "")
        }
    }
}
