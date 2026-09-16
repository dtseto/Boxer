//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import AppKit
import SwiftUI

/// What the panel needs to know, lifted out of the Objective-C classification
/// so the SwiftUI view has a value type to render and can be previewed without
/// an archive on disk.
struct ArchiveSummary {
    var title: String
    var detail: String
    var unpackedSize: UInt64
    var packFound: Bool
    var packAdvice: String?
    var canConvert: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(unpackedSize), countStyle: .file)
    }
}

/// The first panel of the eXoDOS import wizard: what Boxer believes the dropped
/// archive to be, and what it intends to do about it.
///
/// Deliberately a plain SwiftUI view over a value type. The window it lives in
/// is still NIB-driven, and the panels around it are still `NSView`s from that
/// NIB — this one is hosted alongside them rather than replacing any of them,
/// which is what keeps the move to SwiftUI incremental.
struct ImportClassificationView: View {
    let summary: ArchiveSummary
    var onContinue: () -> Void
    var onUnzipAsIs: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.title)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Unpacked size", value: summary.formattedSize)
                LabeledContent("eXoDOS pack") {
                    Label(summary.packFound ? "Found alongside the game" : "Not found",
                          systemImage: summary.packFound ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(summary.packFound ? Color.secondary : Color.orange)
                }
            }
            .font(.callout)

            if let advice = summary.packAdvice {
                Text(advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Unzip As-Is", action: onUnzipAsIs)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!summary.canConvert)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 300, alignment: .topLeading)
    }
}

/// Bridges the SwiftUI panel to the NIB-driven import window, which swaps plain
/// `NSView`s in and out. Objective-C asks for `view` and hands it to
/// `currentPanel`; everything above this line stays Swift.
@objc(BXImportClassificationPanelController)
final class ImportClassificationPanelController: NSObject {
    @objc var view: NSView { hostingView }

    private lazy var hostingView: NSView = {
        let root = ImportClassificationView(
            summary: summary,
            onContinue: { [weak self] in self?.onContinue?() },
            onUnzipAsIs: { [weak self] in self?.onUnzipAsIs?() },
            onCancel: { [weak self] in self?.onCancel?() })
        let view = NSHostingView(rootView: root)

        // The window this goes into sizes itself from the panel's frame
        // (ADBMultiPanelWindowController.setCurrentPanel:), and every other
        // panel is a NIB view that arrives with one already set. A hosting
        // view's frame is zero until something lays it out, so the window
        // would shrink to nothing and the panel would never be seen. Give it
        // its SwiftUI fitting size up front.
        var size = view.fittingSize
        if size.width < 1 || size.height < 1 {
            size = NSSize(width: Self.fallbackSize.width, height: Self.fallbackSize.height)
        }
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        return view
    }()

    private static let fallbackSize = CGSize(width: 520, height: 340)

    private let summary: ArchiveSummary

    @objc var onContinue: (() -> Void)?
    @objc var onUnzipAsIs: (() -> Void)?
    @objc var onCancel: (() -> Void)?

    /// Builds the panel from an Objective-C classification.
    @objc(initWithClassification:packFound:)
    init(classification: BXArchiveClassification, packFound: Bool) {
        let isGame = classification.kind == .exoDOSGame
        var advice: String? = nil
        if isGame && !packFound {
            advice = NSLocalizedString(
                "The game's configuration — its drives, its launch command and its machine settings — lives in the pack's “!DOSmetadata.zip”, not in this archive. Boxer needs that file to convert the game.",
                comment: "Shown when an eXoDOS game's pack could not be found next to it.")
        }

        summary = ArchiveSummary(
            title: classification.gameTitle ?? NSLocalizedString(
                "Unrecognised archive",
                comment: "Title shown for an archive Boxer could not classify."),
            detail: classification.rejectionReason ?? classification.localizedSummary,
            unpackedSize: classification.unpackedSize,
            packFound: packFound,
            packAdvice: advice,
            canConvert: isGame && packFound)
        super.init()
    }
}
