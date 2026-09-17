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
/// This is `NSPathControl` in its pop-up style, which AppKit describes as
/// looking and working "like an NSPopUpButton to display the full path, or
/// select a new path, if the control is editable" — the same control a Mac user
/// meets wherever an app asks for a folder. Being editable buys three things
/// for free: the menu of the path's own ancestors, a "Choose…" item backed by
/// an `NSOpenPanel`, and a folder dropped straight onto the control.
///
/// The one thing AppKit does not provide is a list of places used before, so
/// the delegate adds those to the menu on its way up.
///
/// Note for anyone tempted to set `font` or `controlSize` here: both were set
/// once and both are left alone now, because on macOS 27 this control came up
/// with no chrome at all — white on white, no bezel — and those are the only
/// two knobs that were being touched.
struct DestinationPathControl: NSViewRepresentable {
    @Binding var url: URL

    /// Folders offered under the path's own components. Empty on a first run.
    var recents: [URL]

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .popUp
        control.isEditable = true
        control.allowedTypes = [UTType.folder.identifier]
        control.delegate = context.coordinator
        control.target = context.coordinator
        control.action = #selector(Coordinator.pathDidChange(_:))
        // A long path must not be allowed to widen the window: the panel is
        // sized from this view's fitting size, so the control has to be willing
        // to be narrower than its contents and truncate instead.
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.parent = self
        if control.url != url {
            control.url = url
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSPathControlDelegate {
        var parent: DestinationPathControl

        init(_ parent: DestinationPathControl) {
            self.parent = parent
        }

        /// Sent whichever way the value changed.
        ///
        /// Picking one of the path's own components selects that folder and
        /// reports it as `clickedPathItem`, without the control changing its own
        /// URL — that part is ours to do. Choosing from the open panel or
        /// dropping a folder changes the URL and sends the action with no
        /// clicked item at all.
        @objc func pathDidChange(_ sender: NSPathControl) {
            if let clicked = sender.clickedPathItem?.url {
                sender.url = clicked
                parent.url = clicked
            } else if let chosen = sender.url {
                parent.url = chosen
            }
        }

        @objc private func selectRecent(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.url = url
        }

        func pathControl(_ pathControl: NSPathControl, willPopUp menu: NSMenu) {
            let current = parent.url.standardizedFileURL
            let offered = parent.recents
                .filter { $0.standardizedFileURL != current }
                .prefix(ImportDestinationHistory.limit)
            guard !offered.isEmpty else { return }

            // The path's own components come first and AppKit's "Choose…" last,
            // separated. Slot the recents in between, at the first separator, so
            // the control's own structure is left alone.
            var index = menu.items.firstIndex(where: { $0.isSeparatorItem }) ?? menu.numberOfItems

            func insert(_ item: NSMenuItem) {
                menu.insertItem(item, at: index)
                index += 1
            }

            insert(.separator())

            let header = NSMenuItem(title: NSLocalizedString("Recent Locations",
                                                             comment: "Heading above previously used folders in the import destination popup."),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            insert(header)

            for folder in offered {
                let item = NSMenuItem(title: FileManager.default.displayName(atPath: folder.path),
                                      action: #selector(selectRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = folder
                item.indentationLevel = 1
                let icon = NSWorkspace.shared.icon(forFile: folder.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                item.toolTip = folder.path
                insert(item)
            }
        }

        /// AppKit builds this panel from `allowedTypes`; all it needs is Boxer's
        /// own wording and the ability to make a folder on the spot.
        func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
            openPanel.canChooseDirectories = true
            openPanel.canChooseFiles = false
            openPanel.canCreateDirectories = true
            openPanel.allowsMultipleSelection = false
            openPanel.directoryURL = parent.url
            openPanel.prompt = NSLocalizedString("Choose",
                                                 comment: "Confirmation button in the import destination picker.")
            openPanel.message = NSLocalizedString("Choose where to keep the imported game:",
                                                  comment: "Prompt in the import destination picker.")
        }
    }
}
