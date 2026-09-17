//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where imported games have been put before.
///
/// Boxer is not sandboxed, so these are kept as plain paths rather than
/// security-scoped bookmarks: a folder that has since been moved or unmounted
/// simply drops out of the list when it is read back, which is the behaviour
/// wanted anyway.
enum ImportDestinationHistory {
    static let defaultsKey = "importDestinationRecents"

    /// Enough to be useful, few enough that the menu stays a menu.
    static let limit = 8

    /// The folders used before, most recent first, minus any that have gone.
    static var recents: [URL] {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        var seen = Set<String>()
        return stored.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// The last folder a game was actually imported into, if it is still there.
    static var mostRecent: URL? { recents.first }

    /// Records a folder as the newest choice, moving it up if it is already known.
    static func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            .filter { $0 != path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: defaultsKey)
    }
}


/// The standard macOS location popup, for choosing where an import will go.
///
/// An `NSPopUpButton` showing the chosen folder with its icon, the folders used
/// before under it, and "Other…" to browse — the control Safari uses for "Save
/// downloads to" and the shape a Mac user expects when an app asks where to put
/// something.
///
/// It was built on `NSPathControl` in its pop-up style first, which is the
/// literal control for this and brings a folder-drop target and the path's own
/// ancestors for free. On macOS 27 it draws no chrome at all: `NSPathCell`
/// documents `backgroundColor` as defaulting to "a light blue color for
/// NSPathStyleStandard, and nil for everything else", so the pop-up style has
/// no background of its own and leans entirely on a bezel that this release no
/// longer draws for a programmatically created control. It worked, invisibly.
/// A pop-up button draws its own chrome and cannot go the same way.
struct DestinationPathControl: NSViewRepresentable {
    @Binding var url: URL

    /// Folders offered under the current one. Empty on a first run.
    var recents: [URL]

    /// Tagged so a rebuilt menu can tell its own items apart from "Other…".
    private enum Item: Int {
        case current = 1, recent = 2, other = 3
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionDidChange(_:))
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        rebuildMenu(of: button, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func item(for folder: URL, tag: Item) -> NSMenuItem {
        let item = NSMenuItem(title: FileManager.default.displayName(atPath: folder.path),
                              action: nil, keyEquivalent: "")
        item.tag = tag.rawValue
        item.representedObject = folder
        item.toolTip = folder.path
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    private func rebuildMenu(of button: NSPopUpButton, coordinator: Coordinator) {
        let current = url.standardizedFileURL
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(for: url, tag: .current))

        let offered = recents.filter { $0.standardizedFileURL != current }
            .prefix(ImportDestinationHistory.limit)
        if !offered.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: NSLocalizedString("Recent Locations",
                                                             comment: "Heading above previously used folders in the import destination popup."),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for folder in offered {
                let entry = item(for: folder, tag: .recent)
                entry.indentationLevel = 1
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let other = NSMenuItem(title: NSLocalizedString("Other…",
                                                        comment: "Item that opens a file chooser in the import destination popup."),
                               action: nil, keyEquivalent: "")
        other.tag = Item.other.rawValue
        menu.addItem(other)

        button.menu = menu
        button.selectItem(at: 0)
    }

    final class Coordinator: NSObject {
        var parent: DestinationPathControl

        init(_ parent: DestinationPathControl) {
            self.parent = parent
        }

        @objc func selectionDidChange(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem else { return }

            if item.tag == Item.other.rawValue {
                // Put the shown value back first: if the panel is cancelled the
                // button must not be left reading "Other…".
                sender.selectItem(at: 0)
                if let chosen = browseForFolder(startingAt: parent.url) {
                    parent.url = chosen
                }
                return
            }

            if let folder = item.representedObject as? URL {
                parent.url = folder
            }
        }

        private func browseForFolder(startingAt directory: URL) -> URL? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = directory
            panel.prompt = NSLocalizedString("Choose",
                                             comment: "Confirmation button in the import destination picker.")
            panel.message = NSLocalizedString("Choose where to keep the imported game:",
                                              comment: "Prompt in the import destination picker.")
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
}
