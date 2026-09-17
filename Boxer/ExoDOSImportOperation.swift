//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import Foundation

/// Converting one eXoDOS game into a gamebox, as an operation.
///
/// An `ADBOperation` rather than something the wizard owns, because the wizard
/// is only ever going to be one client of it: there are 7,633 games in the pack,
/// and pointing Boxer at a folder of them is a second client rather than a
/// rewrite (decision 4). Everything the wizard needs — a fraction, a filename,
/// cancellation — arrives through the same delegate and notification plumbing
/// as Boxer's other long jobs.
@objc(BXExoDOSImportOperation)
final class ExoDOSImportOperation: ADBOperation {
    /// The game archive, straight out of the pack.
    @objc let gameArchiveURL: URL

    /// The pack's `!DOSmetadata.zip`, which holds the game's `dosbox.conf`.
    @objc let metadataArchiveURL: URL

    /// The folder the finished gamebox goes into.
    @objc let destinationURL: URL

    /// Whether an existing gamebox of the same name may be replaced.
    @objc var replacesExistingGamebox = false

    /// Where the gamebox ended up. Nil until the operation has succeeded.
    @objc private(set) var gameboxURL: URL?

    /// The name of the file currently being written, for display.
    @objc private(set) var currentItemName = ""

    /// Everything the derivation could not account for, in the order it was
    /// found. Populated once planning is done, which is before any extraction.
    @objc private(set) var planWarnings: [String] = []

    /// The game's box front, as it sits in the media pack, or nil if the pack
    /// is absent or has none for this game.
    ///
    /// Deliberately the raw file rather than an `NSImage`: turning it into
    /// cover art means drawing, and drawing belongs on the main thread.
    @objc private(set) var boxArtData: Data?

    /// A plan worked out earlier — by the wizard, which shows it to the user
    /// before they commit. Left nil, the operation works one out itself.
    var plan: ExoDOSPlan?

    private var progress: ADBOperationProgress = 0
    private var lastNotified = Date.distantPast

    /// How often progress notifications go out. Extraction produces a callback
    /// per megabyte, which on a local disk is far more often than any progress
    /// bar can use.
    private static let notificationInterval: TimeInterval = 0.1

    @objc(initWithGameArchiveURL:metadataArchiveURL:destinationURL:)
    init(gameArchiveURL: URL, metadataArchiveURL: URL, destinationURL: URL) {
        self.gameArchiveURL = gameArchiveURL
        self.metadataArchiveURL = metadataArchiveURL
        self.destinationURL = destinationURL
        super.init()
    }

    override var currentProgress: ADBOperationProgress { progress }

    override var isIndeterminate: Bool { false }

    override func main() {
        guard !isCancelled else { return }

        do {
            let plan = try self.plan ?? ExoDOSPlanner.plan(gameArchiveAt: gameArchiveURL,
                                                           metadataArchiveAt: metadataArchiveURL)
            self.plan = plan
            planWarnings = plan.warnings

            let converter = ExoDOSConverter(plan: plan,
                                            destinationDirectory: destinationURL,
                                            overwrite: replacesExistingGamebox)
            converter.isCancelled = { [weak self] in self?.isCancelled ?? true }
            converter.onProgress = { [weak self] progress in
                self?.report(progress)
            }
            gameboxURL = try converter.run()
            boxArtData = Self.boxArt(for: plan, metadataArchiveURL: metadataArchiveURL)
            progress = 1
        } catch {
            // Cancellation is the user's doing, and ADBOperation has already
            // recorded its own error for it; anything else is ours to report.
            if !isCancelled { self.error = error as NSError }
        }
    }

    /// Box art is a nicety, not part of the conversion: a media pack that is
    /// missing, unreadable or simply has no picture of this game must not cost
    /// the user their gamebox.
    private static func boxArt(for plan: ExoDOSPlan, metadataArchiveURL: URL) -> Data? {
        guard let mediaURL = ExoDOSBoxArt.mediaArchiveURL(besideMetadataArchiveAt: metadataArchiveURL)
        else { return nil }
        return ExoDOSBoxArt.imageData(forShortName: plan.shortName,
                                      longName: plan.longName,
                                      mediaArchiveAt: mediaURL)
    }

    private func report(_ update: ExoDOSConverter.Progress) {
        progress = ADBOperationProgress(update.fraction)
        currentItemName = update.currentItem

        let now = Date()
        guard now.timeIntervalSince(lastNotified) >= Self.notificationInterval else { return }
        lastNotified = now
        _sendInProgressNotification(withInfo: nil)
    }
}
