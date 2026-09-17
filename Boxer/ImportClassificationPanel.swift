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


/// The wizard's state, from "here is what I think this is" through to a
/// finished gamebox.
///
/// Everything the panel does lives here rather than in the window controller:
/// the window is still the NIB-driven `ADBMultiPanelWindowController`, and the
/// less it knows about this screen the less there is to unpick when the rest of
/// the import window follows this one into SwiftUI.
@MainActor
final class ImportWizardModel: ObservableObject {
    enum Phase: Equatable {
        case confirming
        case converting
        /// Converted, but with things the user should know about the result.
        case converted
        case failed(String)
    }

    @Published var phase: Phase = .confirming
    @Published var destination: URL
    @Published var fraction: Double = 0
    @Published var currentItem: String = ""

    /// What the derivation could not account for, once planning has run. Shown
    /// after the fact rather than before: they are things to know about the
    /// finished gamebox, not reasons to stop.
    @Published var warnings: [String] = []

    /// Folders games have been imported into before, newest first. Read once,
    /// when the panel is built: nothing else can change them while it is up.
    @Published var recentDestinations: [URL] = ImportDestinationHistory.recents

    let summary: ArchiveSummary

    init(summary: ArchiveSummary, destination: URL) {
        self.summary = summary
        self.destination = destination
    }
}


/// The first panel of the eXoDOS import wizard: what Boxer believes the dropped
/// archive to be, what it intends to do about it, and — once the user says so —
/// how far through doing it we are.
///
/// Deliberately a plain SwiftUI view over an observable model. The window it
/// lives in is still NIB-driven, and the panels around it are still `NSView`s
/// from that NIB — this one is hosted alongside them rather than replacing any
/// of them, which is what keeps the move to SwiftUI incremental.
struct ImportClassificationView: View {
    @ObservedObject var model: ImportWizardModel

    var onContinue: () -> Void
    var onUnzipAsIs: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            switch model.phase {
            case .confirming:
                details
            case .converting:
                conversion
            case .converted:
                notes
            case .failed(let message):
                failure(message)
            }

            Spacer(minLength: 0)

            buttons
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.summary.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(model.summary.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Unpacked size", value: model.summary.formattedSize)
            LabeledContent("eXoDOS pack") {
                Label(model.summary.packFound ? "Found alongside the game" : "Not found",
                      systemImage: model.summary.packFound ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.summary.packFound ? Color.secondary : Color.orange)
            }
            LabeledContent("Import into") {
                DestinationPathControl(url: $model.destination, recents: model.recentDestinations)
                    .frame(height: 22)
                    .frame(maxWidth: 260, alignment: .leading)
            }

            if let advice = model.summary.packAdvice {
                Text(advice)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .font(.callout)
    }

    private var conversion: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: model.fraction) {
                Text("Converting…")
            }
            Text(model.currentItem.isEmpty ? " " : model.currentItem)
                .font(.callout)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .lineLimit(1)
        }
    }

    /// What the derivation could not account for. Every one of these is a real
    /// property of the pack rather than a failure — a game whose A: drive eXo
    /// creates during its Windows-side install and never ships, say — but the
    /// gamebox is not quite what the config asked for, and saying nothing about
    /// that is how an importer comes to be distrusted.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The game was imported, with notes.", systemImage: "info.circle")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        Text("• " + warning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The game could not be converted.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()

            switch model.phase {
            case .converting:
                EmptyView()
            case .converted:
                Button("Done", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            case .confirming, .failed:
                // Unzipping the archive as-is is the escape hatch for when the
                // clever path gets something wrong. It is not built yet, and a
                // button that silently does nothing is worse than one that says
                // it cannot: see EXODOS-IMPORT.md, stage 7.
                Button("Unzip As-Is", action: onUnzipAsIs)
                    .disabled(true)
                    .help("Not available yet — see the import notes.")
                Button(model.phase == .confirming ? "Continue" : "Try Again", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.summary.canConvert)
            }
        }
    }
}


/// Bridges the SwiftUI panel to the NIB-driven import window, which swaps plain
/// `NSView`s in and out, and drives the conversion behind it.
///
/// Objective-C asks for `view` and hands it to `currentPanel`, and hears back
/// only when there is a gamebox or the user has given up; everything between
/// those two points stays in Swift.
@MainActor
@objc(BXImportClassificationPanelController)
final class ImportClassificationPanelController: NSObject {
    @objc var view: NSView { hostingView }

    /// Called with the finished gamebox and its box art, if the media pack had
    /// any. The session takes it from there.
    @objc var onGameboxReady: ((URL, NSImage?) -> Void)?

    /// Called when the user abandons the import altogether.
    @objc var onCancel: (() -> Void)?

    private let model: ImportWizardModel
    private let gameArchiveURL: URL
    private let metadataArchiveURL: URL?
    private let queue = OperationQueue()
    private var operation: ExoDOSImportOperation?
    private var finishedGameboxURL: URL?
    private var finishedCoverArt: NSImage?
    private var observers: [NSObjectProtocol] = []

    private lazy var hostingView: NSView = {
        let root = ImportClassificationView(
            model: model,
            onContinue: { [weak self] in self?.advance() },
            onUnzipAsIs: {},
            onCancel: { [weak self] in self?.cancel() })
        let view = NSHostingView(rootView: root)

        // The window this goes into sizes itself from the panel's frame
        // (ADBMultiPanelWindowController.setCurrentPanel:), and every other
        // panel is a NIB view that arrives with one already set. A hosting
        // view's frame is zero until something lays it out, so the window
        // would shrink to nothing and the panel would never be seen. Give it
        // its SwiftUI fitting size up front.
        var size = view.fittingSize
        if size.width < 1 || size.height < 1 {
            size = Self.fallbackSize
        }
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        return view
    }()

    private static let fallbackSize = CGSize(width: 520, height: 360)

    /// Builds the panel from an Objective-C classification.
    ///
    /// `destinationURL` is where the gamebox will go unless the user says
    /// otherwise — the games folder, which the app controller owns and this
    /// class deliberately does not reach for itself.
    @objc(initWithClassification:gameArchiveURL:metadataArchiveURL:destinationURL:)
    init(classification: BXArchiveClassification,
         gameArchiveURL: URL,
         metadataArchiveURL: URL?,
         destinationURL: URL) {
        let isGame = classification.kind == .exoDOSGame
        let packFound = metadataArchiveURL != nil
        var advice: String? = nil
        if isGame && !packFound {
            advice = NSLocalizedString(
                "The game's configuration — its drives, its launch command and its machine settings — lives in the pack's “!DOSmetadata.zip”, not in this archive. Boxer needs that file to convert the game.",
                comment: "Shown when an eXoDOS game's pack could not be found next to it.")
        }

        let summary = ArchiveSummary(
            title: classification.gameTitle ?? NSLocalizedString(
                "Unrecognised archive",
                comment: "Title shown for an archive Boxer could not classify."),
            detail: classification.rejectionReason ?? classification.localizedSummary,
            unpackedSize: classification.unpackedSize,
            packFound: packFound,
            packAdvice: advice,
            canConvert: isGame && packFound)

        self.model = ImportWizardModel(summary: summary, destination: destinationURL)
        self.gameArchiveURL = gameArchiveURL
        self.metadataArchiveURL = metadataArchiveURL
        self.queue.maxConcurrentOperationCount = 1
        super.init()

        // The same kind of test hook as --importURL, and for the same reason:
        // a wizard nobody can drive from a script is a wizard that gets tested
        // by hand every time. Given a folder, this presses Continue itself as
        // soon as the panel is up and converts into that folder rather than the
        // user's games folder.
        // Where the last import actually went beats the games folder: a user
        // who keeps their eXoDOS conversions somewhere else said so once and
        // should not have to say it again.
        if let remembered = ImportDestinationHistory.mostRecent {
            model.destination = remembered
        }

        if let folder = Self.automaticDestination() {
            model.destination = folder
            DispatchQueue.main.async { [weak self] in self?.beginConversion() }
        }
    }

    private static func automaticDestination() -> URL? {
        let flag = "--exodosAutoContinue="
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix(flag) {
            return URL(fileURLWithPath: String(argument.dropFirst(flag.count)), isDirectory: true)
        }
        return nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }


    // MARK: - Driving the conversion


    private func beginConversion() {
        guard let metadataArchiveURL = metadataArchiveURL else { return }

        // Recorded here rather than when the folder is picked, so the list is
        // of places games were really imported into and a browse that came to
        // nothing leaves no trace.
        ImportDestinationHistory.remember(model.destination)

        let operation = ExoDOSImportOperation(gameArchiveURL: gameArchiveURL,
                                              metadataArchiveURL: metadataArchiveURL,
                                              destinationURL: model.destination)
        self.operation = operation

        model.phase = .converting
        model.fraction = 0
        model.currentItem = ""

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .ADBOperationInProgress,
                                            object: operation, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.fraction = Double(operation.currentProgress)
                self?.model.currentItem = operation.currentItemName
            }
        })
        observers.append(center.addObserver(forName: .ADBOperationDidFinish,
                                            object: operation, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.conversionDidFinish(operation)
            }
        })

        queue.addOperation(operation)
    }

    /// The panel's one forward action, which means different things in each
    /// phase: convert, try again, or hand the finished gamebox over.
    private func advance() {
        switch model.phase {
        case .confirming, .failed:
            beginConversion()
        case .converted:
            finish()
        case .converting:
            break
        }
    }

    private func finish() {
        guard let gameboxURL = finishedGameboxURL else { return }
        onGameboxReady?(gameboxURL, finishedCoverArt)
    }

    private func conversionDidFinish(_ operation: ExoDOSImportOperation) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        self.operation = nil

        model.warnings = operation.planWarnings

        if let gameboxURL = operation.gameboxURL, operation.error == nil {
            finishedGameboxURL = gameboxURL
            // Drawing the cover art has to happen here rather than on the
            // operation's thread, which is why the operation hands back the
            // image file rather than an icon.
            finishedCoverArt = operation.boxArtData
                .flatMap { NSImage(data: $0) }
                .flatMap { CoverArt.coverArt(with: $0) ?? $0 }

            // Nothing to report means nothing to stop for.
            if model.warnings.isEmpty {
                finish()
            } else {
                model.phase = .converted
            }
            return
        }

        // A cancelled operation is not a failure to report back to the user:
        // they asked for it, and the half-written gamebox has already been
        // taken away again.
        if operation.isCancelled {
            model.phase = .confirming
            return
        }
        model.phase = .failed(operation.error?.localizedDescription
                              ?? NSLocalizedString("The conversion stopped without saying why.",
                                                   comment: "Fallback message for a failed eXoDOS conversion."))
    }

    private func cancel() {
        if let operation = operation, !operation.isFinished {
            operation.cancel()
            return
        }
        onCancel?()
    }
}
