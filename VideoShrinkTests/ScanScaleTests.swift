import XCTest
import AVFoundation
import Photos
@testable import VideoShrink

/// The library scan against a library far larger than a test can build, and against one that
/// changes while the scan is reading it.
///
/// Nothing here touches PhotoKit. The part of the pass that decides what to do when the library
/// moves under it is driven through the seam that exists for exactly that reason, and the rest
/// through the view model's own protocols, because a simulator has no photo library to change and
/// a Photos fetch result cannot be built by hand. What these tests cannot prove - and what still
/// needs a device - is what PhotoKit itself does mid-pass.
@MainActor final class ScanScaleTests: XCTestCase {

    // MARK: - The listing walk, against a library that moves

    func testTheWalkEndsAtTheEndOfAListingThatShrankUnderIt() async throws {
        // Photos can shorten a fetch result while it is being read, and asking such a listing for
        // an index it no longer has raises rather than returning nothing. Reading the count first
        // is what lets a shortened listing end.
        let service = PhotoLibraryScanService()
        var liveCount = 8
        var read: [Int] = []

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> Int in
                read.append(index)
                // Photos loses the last three videos while the pass is running.
                if index == 4 { liveCount = 5 }
                return index
            },
            describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(read, [0, 1, 2, 3, 4])
        XCTAssertEqual(outcome.assets.map(\.id),
                       ["video-0", "video-1", "video-2", "video-3", "video-4"])
        XCTAssertEqual(outcome.videoCount, 5)
    }

    func testTheWalkPicksUpAVideoAddedWhileItIsRunning() async throws {
        // The other direction: a video recorded or synced down mid-pass used to be missed because
        // the pass had already decided how many videos it was going to read.
        let service = PhotoLibraryScanService()
        var liveCount = 3

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> Int in
                if index == 1 { liveCount = 5 }
                return index
            },
            describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(outcome.assets.map(\.id),
                       ["video-0", "video-1", "video-2", "video-3", "video-4"])
        XCTAssertEqual(outcome.videoCount, 5)
    }

    func testTheWalkListsEachVideoOnceWhenAnAdditionShiftsTheListing() async throws {
        // A video arriving at the top of a newest-first listing pushes every video below it along
        // by one, so the next step arrives at a video the pass has already described. Naming it
        // twice would put it on the summary twice and offer it twice in a run.
        let service = PhotoLibraryScanService()
        var liveCount = 3
        var names = ["a", "b", "c"]
        var arrived = false

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> String in
                let name = names[index]
                if index == 0 && !arrived {
                    arrived = true
                    names = ["new", "a", "b", "c"]
                    liveCount = 4
                }
                return name
            },
            describe: { (id: String) -> LibraryAsset in scanScaleAsset(id) },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(outcome.assets.map(\.id), ["a", "b", "c"])
        // "new" arrived after the pass began, so the pass cannot report it: that is what the
        // reconciliation after a scan is for.
        XCTAssertEqual(outcome.videoCount, 3)
    }

    func testTheWalkNeverReportsMoreCheckedThanItsTotal() async throws {
        // The count under the progress bar is the user's only evidence that a long scan is moving,
        // so it must never read "45 of 30 checked" when the library loses videos part-way.
        let service = PhotoLibraryScanService()
        var updates: [LibraryScanProgress] = []
        var liveCount = 70

        let outcome = try await service.walkListing(
            liveCount: { liveCount },
            assetAt: { (index: Int) -> Int in
                if index == 40 { liveCount = 45 }
                return index
            },
            describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
            scanOwned: false,
            progress: { updates.append($0) })

        XCTAssertEqual(updates.first, LibraryScanProgress(phase: .listing, scanned: 0, total: 70))
        XCTAssertEqual(updates.last, LibraryScanProgress(phase: .listing, scanned: 45, total: 45))
        XCTAssertTrue(updates.allSatisfy { $0.scanned <= $0.total })
        XCTAssertTrue(updates.allSatisfy { $0.phase == .listing })
        XCTAssertEqual(outcome.videoCount, 45)
    }

    func testUnsupportedVideosAreCountedAndTheTotalsStillAddUp() async throws {
        // `videoCount` is what the pass read, so the summary's own numbers add up whatever the
        // library did while it was being read.
        let service = PhotoLibraryScanService()

        let outcome = try await service.walkListing(
            liveCount: { 4 },
            assetAt: { (index: Int) -> Int in index },
            describe: { (index: Int) -> LibraryAsset in
                index.isMultiple(of: 2)
                    ? scanScaleAsset("video-\(index)")
                    : scanScaleAsset("video-\(index)", unsupported: "Cinematic videos are not supported yet.")
            },
            scanOwned: false,
            progress: { _ in })

        XCTAssertEqual(outcome.assets.map(\.id), ["video-0", "video-2"])
        XCTAssertEqual(outcome.skipped, 2)
        XCTAssertEqual(outcome.videoCount, 4)
    }

    func testTheWalkStopsWithinOneVideoOfTheStopButton() async {
        // Cancellability is a constraint, not a nicety: the pass reads one video at a time and
        // checks the stop switch before each one, so stopping never waits for the rest of a large
        // library to be read.
        let service = PhotoLibraryScanService()
        var read = 0

        do {
            _ = try await service.walkListing(
                liveCount: { 10_000 },
                assetAt: { (index: Int) -> Int in
                    read += 1
                    return index
                },
                describe: { (index: Int) -> LibraryAsset in scanScaleAsset("video-\(index)") },
                scanOwned: true,
                progress: { update in
                    // The user taps Stop on the scanning screen.
                    if update.scanned == 32 { service.cancel() }
                })
            XCTFail("A stopped scan must not report a library")
        } catch {
            XCTAssertEqual(PipelineError.normalize(error, fallback: .libraryScan), .cancelled)
        }

        // The next video is never read: the stop is seen before it, not after the library.
        XCTAssertEqual(read, 32)
    }

    // MARK: - The bounded on-device pass

    // The pass reads originals that are already on the iPhone, so none of this needs a Photos
    // library: the loop is driven through the seam that exists for exactly that reason, as the
    // listing walk is. What these tests cannot prove, and what still needs a device, is what
    // PhotoKit hands back for a real library.

    func testAVideoThePassReadAndRefusedComesOutOfTheListWithTheRulesOwnWords() async throws {
        let service = PhotoLibraryScanService()

        let outcome = try await service.classifyOnDevice(
            [scanScaleAsset("hdr"), scanScaleAsset("ordinary")],
            phase: .inspectingFormats,
            progress: { _ in },
            probe: { identifier in
                identifier == "hdr"
                    ? PhotoLibraryScanService.OnDeviceFinding(refusal: scanScaleHDRReason)
                    : nil
            })

        // The video the pass read and refused cannot be chosen, because everything the list offers
        // can be run and this one cannot.
        XCTAssertEqual(outcome.assets.map(\.id), ["ordinary"])
        // It is carried out of the pass all the same, so the library screen can say why instead of
        // the video quietly disappearing.
        XCTAssertEqual(outcome.refused.map(\.id), ["hdr"])
        // The words come from the rules and not from this test, so they cannot drift from what the
        // pipeline says about the same video (EligibilityTests pins the sentence itself).
        XCTAssertEqual(outcome.refused.first?.unsupportedReason, scanScaleHDRReason)
        XCTAssertFalse(outcome.refused.first?.isEligible ?? true)
        XCTAssertEqual(outcome.measured, 0)
    }

    func testAPassThatCouldNotReadAVideoLeavesItExactlyAsTheListingDescribedIt() async throws {
        // The honest rule. A video whose original is in iCloud, or whose header could not be
        // opened, is never refused here: it stays a candidate and is refused later in a run on the
        // media itself, exactly as it was before this pass existed.
        let service = PhotoLibraryScanService()
        let inTheCloud = scanScaleAsset("in-the-cloud")
        let unreadable = scanScaleAsset("unreadable")

        let outcome = try await service.classifyOnDevice(
            [inTheCloud, unreadable],
            phase: .inspectingFormats,
            progress: { _ in },
            probe: { identifier in
                // Nothing came back for the first one, and nothing decidable came back for the
                // second: a file that was read but names no refusal.
                identifier == "unreadable" ? PhotoLibraryScanService.OnDeviceFinding() : nil
            })

        XCTAssertEqual(outcome.assets, [inTheCloud, unreadable])
        XCTAssertTrue(outcome.refused.isEmpty)
        XCTAssertEqual(outcome.measured, 0)
    }

    func testThePassMeasuresOnlyTheSizesPhotosDidNotReport() async throws {
        // A size Photos reported is not this app's to replace, and a size this pass takes is
        // reported as measured, which is what tells the summary where its numbers came from.
        let service = PhotoLibraryScanService()
        let reported = scanScaleAsset("reported", bytes: 999)
        let unmeasured = scanScaleAsset("unmeasured", bytes: nil)

        let outcome = try await service.classifyOnDevice(
            [reported, unmeasured],
            phase: .measuring,
            progress: { _ in },
            probe: { _ in PhotoLibraryScanService.OnDeviceFinding(bytes: 4_000) })

        XCTAssertEqual(outcome.assets.first?.bytes, 999)
        XCTAssertEqual(outcome.assets.last?.bytes, 4_000)
        XCTAssertEqual(outcome.measured, 1)
    }

    func testThePassStopsAtItsBoundAndLeavesTheRestUnknown() async throws {
        // A library bigger than the bound cannot turn a scan into an unbounded wait. The videos
        // past the bound keep the listing's own answer, which is never a refusal on a reading this
        // app did not take.
        let service = PhotoLibraryScanService()
        let assets = (0..<(PhotoLibraryScanService.onDeviceProbeLimit + 25))
            .map { scanScaleAsset("video-\($0)") }
        var read: [String] = []

        let outcome = try await service.classifyOnDevice(
            assets,
            phase: .inspectingFormats,
            progress: { _ in },
            probe: { identifier in
                read.append(identifier)
                return nil
            })

        XCTAssertEqual(read.count, PhotoLibraryScanService.onDeviceProbeLimit)
        XCTAssertEqual(read.first, "video-0")
        XCTAssertEqual(read.last, "video-\(PhotoLibraryScanService.onDeviceProbeLimit - 1)")
        XCTAssertEqual(outcome.assets, assets)
        XCTAssertTrue(outcome.refused.isEmpty)
    }

    func testThePassStopsWithinOneVideoOfTheStopButton() async throws {
        // The same constraint the listing walk has: one video is read at a time and the stop switch
        // is checked before each one, so stopping never waits for the rest of a large library.
        let service = PhotoLibraryScanService()
        var read = 0

        do {
            _ = try await service.classifyOnDevice(
                (0..<10_000).map { scanScaleAsset("video-\($0)") },
                phase: .inspectingFormats,
                progress: { update in
                    // The user taps Stop on the scanning screen.
                    if update.scanned == 32 { service.cancel() }
                },
                probe: { _ in
                    read += 1
                    return nil
                })
            XCTFail("A stopped pass must not report a library")
        } catch {
            XCTAssertEqual(PipelineError.normalize(error, fallback: .libraryScan), .cancelled)
        }

        XCTAssertEqual(read, 32)
    }

    func testThePassReportsThePhaseItWasGivenAndItsOwnTotal() async throws {
        // The scanning screen reads the phase to choose its wording, so the pass says which
        // question it is answering: measuring sizes where Photos reports none, reading formats
        // where it does.
        let service = PhotoLibraryScanService()
        var updates: [LibraryScanProgress] = []

        _ = try await service.classifyOnDevice(
            [scanScaleAsset("a", bytes: nil), scanScaleAsset("b", bytes: nil)],
            phase: .inspectingFormats,
            progress: { updates.append($0) },
            probe: { _ in PhotoLibraryScanService.OnDeviceFinding(bytes: 10) })

        XCTAssertEqual(updates.first,
                       LibraryScanProgress(phase: .inspectingFormats, scanned: 0, total: 2))
        XCTAssertEqual(updates.last,
                       LibraryScanProgress(phase: .inspectingFormats, scanned: 2, total: 2))
        XCTAssertTrue(updates.allSatisfy { $0.scanned <= $0.total })
    }

    func testAPassWithNothingToReadReportsNothingAtAll() async throws {
        // An empty library must not start a phase the screen would draw a progress bar for.
        let service = PhotoLibraryScanService()
        var updates: [LibraryScanProgress] = []
        var read = 0

        let outcome = try await service.classifyOnDevice(
            [],
            phase: .inspectingFormats,
            progress: { updates.append($0) },
            probe: { _ in
                read += 1
                return nil
            })

        XCTAssertTrue(updates.isEmpty)
        XCTAssertEqual(read, 0)
        XCTAssertTrue(outcome.assets.isEmpty)
        XCTAssertTrue(outcome.refused.isEmpty)
        XCTAssertEqual(outcome.measured, 0)
    }

    // MARK: - The chosen-video read before a run starts

    // The residual version of the worst experience was that a video turning out to be unsupported
    // surfaced only halfway through a run, when the pipeline opened it. These tests cover the read
    // that closes that for the videos the user actually chose, and the two answers it must never
    // give: refusing a video it could not read, and downloading one to find out.

    func testTheChosenVideoReadNamesEachRefusalInTheRulesOwnWords() async throws {
        // The sentence has one owner. This read writes no second copy of it, and the video the
        // media refused is the only one that comes back refused.
        let service = PhotoLibraryScanService()

        let refused = try await service.refusedByFormat(
            among: [scanScaleAsset("ordinary"), scanScaleAsset("hdr")],
            progress: { _ in },
            probe: { identifier in
                identifier == "hdr"
                    ? PhotoLibraryScanService.OnDeviceFinding(refusal: scanScaleHDRReason)
                    : nil
            })

        XCTAssertEqual(refused.map(\.id), ["hdr"])
        XCTAssertEqual(refused.first?.unsupportedReason, scanScaleHDRReason)
        XCTAssertFalse(refused.first?.isEligible ?? true)
    }

    func testTheChosenVideoReadIsNotBoundedByTheScansOwnLimit() async throws {
        // The cap belongs to reading a library nobody chose. A selection is the user's own answer
        // to which videos matter, so all of it is read however deep it sits: leaving the rest to be
        // refused half-way through a run is the experience this read exists to close.
        let service = PhotoLibraryScanService()
        let assets = (0..<(PhotoLibraryScanService.onDeviceProbeLimit + 25))
            .map { scanScaleAsset("video-\($0)") }
        var read: [String] = []

        let refused = try await service.refusedByFormat(
            among: assets,
            progress: { _ in },
            probe: { identifier in
                read.append(identifier)
                return nil
            })

        XCTAssertEqual(read, assets.map(\.id))
        XCTAssertTrue(refused.isEmpty)
    }

    func testAStopThatBelongedToAScanDoesNotStopTheChosenVideoRead() async throws {
        // The scan's stop switch belongs to the scan, and only a new scan clears it. A read that
        // consulted it would refuse to run at all after any scan the user had stopped, for a reason
        // the user could not see. This read stops for its own task and nothing else.
        let service = PhotoLibraryScanService()
        service.cancel()
        var read = 0

        let refused = try await service.refusedByFormat(
            among: [scanScaleAsset("a"), scanScaleAsset("b")],
            progress: { _ in },
            probe: { _ in
                read += 1
                return nil
            })

        XCTAssertEqual(read, 2)
        XCTAssertTrue(refused.isEmpty)
    }

    func testAChosenVideoTheMediaRefusesIsTakenOutBeforeTheRunStarts() async {
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("ordinary"), scanScaleAsset("hdr")])
        fixture.scanner.formatRefusals = ["hdr": scanScaleHDRReason]

        await scanScaleStart(fixture, choosing: ["ordinary", "hdr"])

        // The run holds one video, and the refused one never reached it.
        XCTAssertEqual(fixture.batch.items.map(\.id), ["ordinary"])
        // It is named where the user will see it, in the rules' own words...
        XCTAssertEqual(fixture.batch.preflightRefusals.map(\.id), ["hdr"])
        XCTAssertEqual(fixture.batch.preflightRefusals.first?.unsupportedReason, scanScaleHDRReason)
        // ...and the library stops offering it, exactly as it stops offering one the scan refused.
        XCTAssertEqual(fixture.batch.scanResult?.refusedAssets.map(\.id), ["hdr"])
        XCTAssertFalse(fixture.batch.selection.contains("hdr"))
        XCTAssertFalse(fixture.batch.preflightLeftNothingToRun)
        // The queue describes what is actually running, which is the durability rule a run keeps
        // whatever it worked out before it started.
        XCTAssertFalse(fixture.queue.saved.isEmpty)
        XCTAssertTrue(fixture.queue.saved.allSatisfy { $0.items.map(\.identifier) == ["ordinary"] })
    }

    func testAVideoTheReadCouldNotAnswerStaysInTheRun() async {
        // The honest rule, at the moment before a run. A video whose original is only in iCloud
        // cannot be read with the network switched off, so it is not refused here: it rides into
        // the run and is refused later, when the pipeline opens it, exactly as before this read
        // existed.
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("in-the-cloud"),
                                                scanScaleAsset("ordinary")])

        await scanScaleStart(fixture, choosing: ["in-the-cloud", "ordinary"])

        XCTAssertEqual(fixture.batch.items.map(\.id), ["in-the-cloud", "ordinary"])
        XCTAssertTrue(fixture.batch.preflightRefusals.isEmpty)
        XCTAssertEqual(fixture.batch.scanResult?.assets.map(\.id), ["in-the-cloud", "ordinary"])
    }

    func testAReadThatFailedLeavesEveryChosenVideoEligible() async {
        // A read that could not be taken is not evidence about anything. Refusing on it would be
        // the one thing this app must never do: refusing a video it could not read.
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a"), scanScaleAsset("b")])
        fixture.scanner.formatError = PipelineError.libraryScan

        await scanScaleStart(fixture, choosing: ["a", "b"])

        XCTAssertEqual(fixture.batch.items.map(\.id), ["a", "b"])
        XCTAssertTrue(fixture.batch.preflightRefusals.isEmpty)
        XCTAssertFalse(fixture.batch.preflightLeftNothingToRun)
    }

    func testEveryVideoTheUserChoseIsOfferedToTheRead() async {
        // The read is given the selection itself, in the order the library lists it, and nothing
        // else: not the videos the app made, not the ones it already shrank, not a cap of one.
        let fixture = ScanScaleFixture(assets: (0..<12).map { scanScaleAsset("video-\($0)") })
        let chosen = (0..<12).map { "video-\($0)" }

        await scanScaleStart(fixture, choosing: chosen)

        XCTAssertEqual(fixture.scanner.formatRead, chosen)
        XCTAssertEqual(fixture.batch.items.map(\.id), chosen)
    }

    func testASelectionWhereEveryVideoIsRefusedStartsNoRun() async {
        // Nothing to export is a run that must not begin, and the user has to be told that rather
        // than left watching a count that never moves.
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("hdr"), scanScaleAsset("prores")])
        fixture.scanner.formatRefusals = [
            "hdr": scanScaleHDRReason,
            "prores": AssetRules.unsupportedFormatReason(isHDR: false, isProRes: true) ?? ""
        ]

        await scanScaleStart(fixture, choosing: ["hdr", "prores"])

        XCTAssertEqual(fixture.batch.phase, .selecting)
        XCTAssertTrue(fixture.batch.items.isEmpty)
        XCTAssertTrue(fixture.batch.preflightLeftNothingToRun)
        XCTAssertEqual(fixture.batch.scanResult?.refusedAssets.map(\.id), ["hdr", "prores"])
        XCTAssertTrue(fixture.batch.selection.isEmpty)
        XCTAssertTrue(fixture.queue.saved.isEmpty)
    }

    func testTheReadIsShownWhileItRunsAndCanBeStopped() async {
        // Cancellable, and honest about what it is doing: the screen names the pass while it runs,
        // and the stop puts the user back on their choice without refusing or exporting anything.
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a"), scanScaleAsset("b")])
        fixture.scanner.holdFormats = true
        fixture.scanner.formatRefusals = ["a": scanScaleHDRReason]
        fixture.batch.scan()
        await scanScaleEventually { fixture.batch.phase == .scanned }
        fixture.batch.beginSelecting()
        fixture.batch.toggle("a")
        fixture.batch.toggle("b")
        fixture.batch.start()
        await scanScaleEventually { fixture.scanner.formatGate != nil }

        // What the user sees while they wait: the pass, and how far through it is.
        XCTAssertEqual(fixture.batch.phase, .scanning)
        XCTAssertEqual(fixture.batch.preflight?.phase, .inspectingFormats)
        XCTAssertEqual(fixture.batch.preflight?.total, 2)
        XCTAssertTrue(fixture.batch.isRunning)

        fixture.batch.cancelScan()
        fixture.scanner.releaseFormats()

        await scanScaleEventually { !fixture.batch.isRunning }
        XCTAssertEqual(fixture.batch.phase, .selecting)
        XCTAssertTrue(fixture.batch.items.isEmpty)
        XCTAssertTrue(fixture.batch.preflightRefusals.isEmpty)
        XCTAssertNil(fixture.batch.preflight)
        XCTAssertTrue(fixture.queue.saved.isEmpty)
    }

    // MARK: - A format read on the device survives a refresh

    func testARefreshKeepsAFormatThisAppReadOnTheDevice() {
        // A refresh reads library metadata only, so it cannot read a codec again. The format this
        // app already read stays the answer, and the video stays out of the list while still being
        // counted, instead of looking ordinary again on the next refresh.
        let previous = scanScaleListing([scanScaleAsset("ordinary")],
                                        refused: [scanScaleAsset("hdr", unsupported: scanScaleHDRReason)])
        let fresh = scanScaleListing([scanScaleAsset("ordinary"), scanScaleAsset("hdr")])

        let reconciliation = LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                                         selection: [], running: [])

        XCTAssertEqual(reconciliation.result.assets.map(\.id), ["ordinary"])
        XCTAssertEqual(reconciliation.result.refusedAssets.map(\.id), ["hdr"])
        XCTAssertEqual(reconciliation.result.refusedAssets.first?.unsupportedReason, scanScaleHDRReason)
        XCTAssertTrue(reconciliation.changedIdentifiers.isEmpty)
        XCTAssertTrue(reconciliation.removedIdentifiers.isEmpty)
        // The summary still adds up: the refused video is counted as unsupported.
        XCTAssertEqual(reconciliation.result.unsupportedCount, 1)
        XCTAssertEqual(reconciliation.result.videoCount,
                       reconciliation.result.assets.count + reconciliation.result.unsupportedCount)
    }

    func testARefreshDropsARefusalForAVideoPhotosHasChanged() {
        // A video edited in Photos is not the video this app read. It goes back in the list as an
        // ordinary candidate rather than being refused on a reading that no longer describes it,
        // and it is reported as changed so the picture drawn from the older version is dropped.
        let previous = scanScaleListing([], refused: [scanScaleAsset("hdr", unsupported: scanScaleHDRReason)])
        let fresh = scanScaleListing([scanScaleAsset("hdr", duration: 30)])

        let reconciliation = LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                                         selection: [], running: [])

        XCTAssertEqual(reconciliation.changedIdentifiers, ["hdr"])
        XCTAssertEqual(reconciliation.result.assets.map(\.id), ["hdr"])
        XCTAssertTrue(reconciliation.result.refusedAssets.isEmpty)
        XCTAssertEqual(reconciliation.result.unsupportedCount, 0)
    }

    func testARefreshDropsARefusalForAVideoPhotosNoLongerLists() {
        let previous = scanScaleListing([scanScaleAsset("ordinary")],
                                        refused: [scanScaleAsset("hdr", unsupported: scanScaleHDRReason)])
        let fresh = scanScaleListing([scanScaleAsset("ordinary")])

        let reconciliation = LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                                         selection: [], running: [])

        XCTAssertEqual(reconciliation.result.assets.map(\.id), ["ordinary"])
        XCTAssertTrue(reconciliation.result.refusedAssets.isEmpty)
        XCTAssertTrue(reconciliation.removedIdentifiers.contains("hdr"))
        XCTAssertEqual(reconciliation.result.unsupportedCount, 0)
    }

    func testAFormatRefusalSaysTheSameThingWhereverItIsRefused() {
        // One sentence, one owner. The scan and the pipeline both come back to `AssetRules` for
        // their words, and this is what stops the two drifting apart.
        let scanWords = scanScaleHDRReason
        let pipelineRefusal = VideoVerificationService.unsupportedFormatRefusal(isHDR: true, isProRes: false)
        XCTAssertEqual(pipelineRefusal, .unsupportedOriginal(reason: scanWords))
        XCTAssertEqual(pipelineRefusal?.localizedDescription, scanWords)
        XCTAssertNil(VideoVerificationService.unsupportedFormatRefusal(isHDR: false, isProRes: false))
    }

    // MARK: - A library that changes while the scan is reading it

    func testAChangeReportedWhileScanningIsReconciledOnceTheScanLands() async {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a"), scanScaleAsset("b")], monitor: monitor)
        fixture.scanner.hold = true
        fixture.batch.scan()
        await scanScaleEventually { fixture.scanner.gate != nil }

        // Photos changes while the pass is reading. The pass began before the change, so its
        // listing cannot be trusted to describe one moment of the library - and the report must
        // not be dropped just because a scan was in flight.
        fixture.scanner.refreshResult = scanScaleListing([scanScaleAsset("a")])
        monitor.enteredForeground()
        XCTAssertEqual(fixture.scanner.reconcileCount, 0)

        fixture.scanner.hold = false
        fixture.scanner.release()

        await scanScaleEventually { fixture.scanner.reconcileCount == 1 }
        await scanScaleEventually { fixture.batch.scanResult?.assets.map(\.id) == ["a"] }
        XCTAssertEqual(fixture.batch.phase, .scanned)
    }

    func testAChangeReportedWhileScanningSurvivesTheScanBeingStopped() async {
        let monitor = LibraryChangeMonitor(authorizationStatus: { .authorized })
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a")], monitor: monitor)
        fixture.batch.scan()
        await scanScaleEventually { fixture.batch.phase == .scanned }

        // A second pass, stopped by the user, with a change reported under it.
        fixture.scanner.hold = true
        fixture.batch.scan()
        await scanScaleEventually { fixture.scanner.gate != nil }
        fixture.scanner.refreshResult = scanScaleListing([scanScaleAsset("b")])
        monitor.enteredForeground()
        fixture.batch.cancelScan()

        await scanScaleEventually { fixture.scanner.reconcileCount == 1 }
        await scanScaleEventually { fixture.batch.scanResult?.assets.map(\.id) == ["b"] }
        XCTAssertEqual(fixture.batch.phase, .scanned)
    }

    func testAScanWithNoChangeReportedLeavesTheLibraryAlone() async {
        // The reconcile after a scan costs a full listing, so it must only ever run when Photos
        // actually said something while the pass was reading.
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a"), scanScaleAsset("b")])
        fixture.batch.scan()
        await scanScaleEventually { fixture.batch.phase == .scanned }

        XCTAssertEqual(fixture.scanner.reconcileCount, 0)
        XCTAssertEqual(fixture.batch.scanResult?.assets.map(\.id), ["a", "b"])
    }

    func testAccessWithdrawnWhileScanningStopsThePassAndSaysWhy() async {
        let status = ScanScaleAccessBox(.authorized)
        let monitor = LibraryChangeMonitor(authorizationStatus: { status.value })
        let fixture = ScanScaleFixture(assets: [scanScaleAsset("a")], monitor: monitor)
        fixture.scanner.hold = true
        fixture.batch.scan()
        await scanScaleEventually { fixture.scanner.gate != nil }

        // The user leaves the app, revokes Photos access in Settings and comes back.
        status.value = .denied
        monitor.enteredForeground()

        XCTAssertEqual(fixture.scanner.cancelCount, 1)
        await scanScaleEventually { fixture.batch.phase == .failed }
        XCTAssertEqual(fixture.batch.message, PipelineError.permissionDenied.localizedDescription)
        // The cancellation that follows lands after the decision to fail, and must not put the
        // flow back on the scanning screen with a library the app may no longer read.
        await scanScaleEventually { !fixture.batch.isRunning }
        XCTAssertEqual(fixture.batch.phase, .failed)
    }
}

// MARK: - Helpers

private func scanScaleAsset(_ id: String, bytes: Int64? = 3_000_000_000, duration: Double = 120,
                            unsupported: String? = nil) -> LibraryAsset {
    LibraryAsset(id: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000), duration: duration,
                 pixelWidth: 3840, pixelHeight: 2160, bytes: bytes,
                 unsupportedReason: unsupported)
}

private func scanScaleListing(_ assets: [LibraryAsset],
                              refused: [LibraryAsset] = []) -> LibraryScanResult {
    LibraryScanResult(assets: assets,
                      videoCount: assets.count + refused.count,
                      unsupportedCount: refused.count,
                      unknownSizeCount: assets.filter { $0.bytes == nil }.count,
                      sizeSource: .reportedByPhotos,
                      measuredOnDeviceCount: 0,
                      refusedAssets: refused)
}

/// The sentence `AssetRules` writes for a format only the media can decide, so these tests assert
/// against the rule rather than against a second copy of its words.
private var scanScaleHDRReason: String {
    AssetRules.unsupportedFormatReason(isHDR: true, isProRes: false) ?? ""
}

/// Takes a selection through the confirmation dialog and lets the run it starts end, so a test
/// asserts on the state the user is left with rather than on a moment inside the pass.
///
/// The run itself always ends without a copy here: this fixture's Photos service cannot retrieve a
/// video. What these tests are about is which videos reached the run at all.
@MainActor private func scanScaleStart(_ fixture: ScanScaleFixture, choosing ids: [String]) async {
    fixture.batch.scan()
    await scanScaleEventually { fixture.batch.phase == .scanned }
    fixture.batch.beginSelecting()
    for id in ids { fixture.batch.toggle(id) }
    fixture.batch.start()
    await scanScaleEventually { !fixture.batch.isRunning }
}

private func scanScaleEventually(_ predicate: () -> Bool, file: StaticString = #filePath,
                                 line: UInt = #line) async {
    for _ in 0..<500 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for the scan", file: file, line: line)
}

/// A Photos authorization status a test can change between reads.
private final class ScanScaleAccessBox {
    var value: PHAuthorizationStatus
    init(_ value: PHAuthorizationStatus) { self.value = value }
}

@MainActor private final class ScanScaleFixture {
    let photos = ScanScaleMockPhotos()
    let scanner: ScanScaleMockScanner
    let transcoder = ScanScaleMockTranscoder()
    let verifier = ScanScaleMockVerifier()
    let files = ScanScaleMockFiles()
    let history = ScanScaleMockHistory()
    let queue = ScanScaleMockQueue()
    let screenAwake = ScanScaleMockScreenAwake()
    let monitor: LibraryChangeMonitor
    let settings = ShrinkSettings(defaults: UserDefaults(suiteName: "videoshrink.scan.\(UUID().uuidString)")
                                  ?? .standard)
    lazy var batch = BatchViewModel(photos: photos, scanner: scanner, transcoder: transcoder,
                                    verifier: verifier, temporary: files, history: history,
                                    queueStore: queue, screenAwake: screenAwake,
                                    libraryChanges: monitor, settings: settings)

    /// The scanner starts holding exactly the library this fixture was given, so a test says what
    /// the library is once rather than twice.
    init(assets: [LibraryAsset], monitor: LibraryChangeMonitor? = nil) {
        let mockScanner = ScanScaleMockScanner()
        mockScanner.result = scanScaleListing(assets)
        self.scanner = mockScanner
        self.monitor = monitor ?? LibraryChangeMonitor(authorizationStatus: { .authorized })
    }
}

@MainActor private final class ScanScaleMockScanner: LibraryScanning, OriginalFormatProbing {
    var result = LibraryScanResult(assets: [], videoCount: 0, unsupportedCount: 0, unknownSizeCount: 0,
                                   sizeSource: .reportedByPhotos, measuredOnDeviceCount: 0)
    /// The library as Photos now has it, for a refresh. Left nil, a refresh repeats the last pass.
    var refreshResult: LibraryScanResult?
    /// Holds the pass open so a test can change the library while it is being read.
    var hold = false
    var gate: CheckedContinuation<Void, Error>?
    var cancelCount = 0
    var reconcileCount = 0
    /// What the chosen-video read says about each video. A video it does not name could not be
    /// read, which is not a refusal: it stays eligible.
    var formatRefusals: [String: String] = [:]
    /// The identifiers that read took, in the order it took them.
    var formatRead: [String] = []
    /// Makes the read fail rather than answer, for the rule that a read this app could not take
    /// refuses nothing.
    var formatError: Error?
    /// Holds the chosen-video read open, so a test can stop it the way the Stop button does.
    var holdFormats = false
    var formatGate: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult {
        cancelled = false
        progress(LibraryScanProgress(phase: .listing, scanned: 0, total: result.assets.count))
        if hold { try await withCheckedThrowingContinuation { gate = $0 } }
        if cancelled { throw PipelineError.cancelled }
        return result
    }

    func refreshListing() async throws -> LibraryScanResult { refreshResult ?? result }

    func reconcile(previous: LibraryScanResult?,
                   selection: Set<String>,
                   running: Set<String>) async throws -> LibraryReconciliation {
        reconcileCount += 1
        let fresh = try await refreshListing()
        return LibraryScanResult.reconcile(previous: previous, fresh: fresh,
                                           selection: selection, running: running)
    }

    func cancel() {
        cancelCount += 1
        cancelled = true
        gate?.resume(throwing: PipelineError.cancelled)
        gate = nil
    }

    /// Lets a held pass finish, so a test can drive what the model does when it lands.
    func release() {
        gate?.resume(returning: ())
        gate = nil
    }

    /// The chosen-video read, reporting the same phase and the same "n of m" a scan's format pass
    /// does, because the screen draws both from one place.
    func refusedByFormat(among assets: [LibraryAsset],
                         progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> [LibraryAsset] {
        progress(LibraryScanProgress(phase: .inspectingFormats, scanned: 0, total: assets.count))
        if holdFormats { try await withCheckedThrowingContinuation { formatGate = $0 } }
        if let formatError = formatError { throw formatError }
        var refused: [LibraryAsset] = []
        for (index, asset) in assets.enumerated() {
            formatRead.append(asset.id)
            if let reason = formatRefusals[asset.id] { refused.append(asset.refusing(reason)) }
            progress(LibraryScanProgress(phase: .inspectingFormats, scanned: index + 1, total: assets.count))
        }
        return refused
    }

    /// Lets a held chosen-video read answer, which is what happens on a device when the read the
    /// user stopped finishes the video it was on.
    func releaseFormats() {
        formatGate?.resume(returning: ())
        formatGate = nil
    }
}

@MainActor private final class ScanScaleMockPhotos: PhotoLibraryServing {
    func requestAccess() async throws -> Bool { false }

    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo {
        throw PipelineError.assetUnavailable
    }

    func cancelRetrieval() {}
    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String? { nil }
    func localFileURL(identifier: String) async -> URL? { nil }

    func playerItem(identifier: String) async throws -> AVPlayerItem {
        throw PipelineError.assetUnavailable
    }

    func deleteOriginals(identifiers: [String]) async throws -> [String] { [] }
    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence? { nil }
    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation { .unavailable }

    func deleteOriginals(afterRevalidating evidence: [String: DeletionEvidence]) async throws -> DeletionResult {
        DeletionResult()
    }
}

@MainActor private final class ScanScaleMockTranscoder: VideoTranscoding {
    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        throw PipelineError.assetUnavailable
    }

    func cancel() {}
}

private final class ScanScaleMockVerifier: VideoVerifying {
    func inspect(_ url: URL) async throws -> VideoMetadata { throw PipelineError.assetUnavailable }

    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata {
        throw PipelineError.assetUnavailable
    }

    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata {
        throw PipelineError.assetUnavailable
    }
}

@MainActor private final class ScanScaleMockFiles: TemporaryFileManaging {
    func ensureWorkspace() throws {}
    func outputURL() throws -> URL { URL(fileURLWithPath: "/scan-scale-root/output.mov") }
    func remove(_ url: URL) throws {}
    func requireCapacity(for bytes: Int64) throws {}
    func cleanup() throws {}
}

@MainActor private final class ScanScaleMockHistory: ShrinkHistoryStoring {
    func completedIdentifiers() -> Set<String> { [] }
    func createdCopyIdentifiers() -> Set<String> { [] }
    func copyMeasurements() -> [CopyMeasurement] { [] }
    func record(identifier: String, measurement: CopyMeasurement?) {}
    func recordCreatedCopy(identifier: String) {}
}

@MainActor private final class ScanScaleMockQueue: BatchQueueStoring {
    /// Every record this run wrote, so a test can read what the app said it was doing.
    var saved: [BatchQueueRecord] = []
    func load() -> BatchQueueRecord? { nil }
    func save(_ record: BatchQueueRecord) throws { saved.append(record) }
    func clear() {}
}

@MainActor private final class ScanScaleMockScreenAwake: ScreenAwakeControlling {
    func hold(_ hold: Bool) {}
}
