import XCTest
@testable import VideoShrink

/// Cases for the one rule that decides whether the user may move between the two flows.
///
/// The rule exists because of a kept copy. A finished one-video export that has not been saved is
/// deliberately held on `.readyToSave`, and the one-video flow is the only screen that can save
/// or discard it. If that stage counts as work in flight, a reload lands the user on the batch
/// flow with no way back to the copy, and the next launch's cleanup takes it for good. So every
/// case below is one half of that question: what may be left, and what may not.
@MainActor final class FlowRoutingTests: XCTestCase {

    // MARK: - Fixtures

    /// The model's own answer, as `CompressionViewModel.canChoose` computes it: no task running,
    /// on a stage a run may start from again. `.readyToSave` is deliberately not one of those
    /// stages, and that gap is exactly what the rule closes, so this mirror is the interesting
    /// input rather than a convenience.
    private func modelCanChoose(_ stage: PipelineStage) -> Bool {
        [.idle, .saved, .failed, .cancelled].contains(stage)
    }

    /// The rule, with the batch flow at rest unless a case says otherwise.
    private func decision(stage: PipelineStage,
                          batchCanLeaveFlow: Bool = true) -> FlowRouting.Decision {
        FlowRouting.decision(oneVideoCanChoose: modelCanChoose(stage),
                             stage: stage,
                             batchCanLeaveFlow: batchCanLeaveFlow)
    }

    // MARK: - What may be left

    func testThatAnIdleOneVideoFlowMayBeLeftForTheBatchFlow() {
        XCTAssertEqual(decision(stage: .idle), .maySwitch)
    }

    func testThatAFinishedCopyWaitingToBeSavedMayBeLeft() {
        // The regression this rule was written for. `.readyToSave` has no task running and the
        // copy is kept on purpose, so refusing the move would hide the only screen that can save
        // it - and the copy would be lost, not merely misplaced.
        XCTAssertEqual(decision(stage: .readyToSave), .maySwitch)
    }

    func testThatEveryStageTheOneVideoFlowComesToRestOnMayBeLeft() {
        // The four stages a new run may start from are also the four with nothing to lose; the
        // fifth is the kept copy above.
        for stage in [PipelineStage.idle, .saved, .failed, .cancelled, .readyToSave] {
            XCTAssertEqual(decision(stage: stage), .maySwitch, "\(stage.rawValue)")
        }
    }

    func testThatAnOpenPickerKeepsTheUserOnTheOneVideoFlow() {
        // No task is running while the picker sheet is up, so a rule that only asked "is a task
        // running" would let the user walk away with a choice half made and the sheet stranded.
        XCTAssertEqual(decision(stage: .choosing), .stay(.oneVideoBusy))
    }

    func testThatEveryStageWithWorkInFlightKeepsTheUserOnTheOneVideoFlow() {
        for stage in [PipelineStage.waitingForPermission, .retrieving, .preparing, .transcoding,
                      .verifying, .saving] {
            XCTAssertEqual(decision(stage: stage), .stay(.oneVideoBusy), "\(stage.rawValue)")
        }
    }

    // MARK: - The batch flow's own answer

    func testThatTheBatchFlowsAnswerIsRespectedWhicheverWayTheUserIsMoving() {
        // The rule is deliberately not told which flow is being left, and both controls ask it
        // with the same two answers. So a batch run is protected whether the user is leaving that
        // flow or arriving at it: a run finishing quietly behind the one-video screen must not be
        // walked away from in either direction.
        for stage in [PipelineStage.idle, .saved, .readyToSave] {
            XCTAssertEqual(decision(stage: stage, batchCanLeaveFlow: false), .stay(.batchBusy),
                           "\(stage.rawValue)")
        }
    }

    func testThatBothSidesAreAskedWhenBothHoldWork() {
        // Which reason is reported where both sides are busy is decided by the order the rule asks
        // them in, so it is fixed here: a caller that shows the reason must not see it vary.
        XCTAssertEqual(decision(stage: .transcoding, batchCanLeaveFlow: false),
                       .stay(.oneVideoBusy))
    }

    // MARK: - Every stage is decided

    /// The sweep that keeps the rule honest as the pipeline grows: a stage added later fails here
    /// rather than quietly acquiring a default, and the `.readyToSave` exception stays deliberate.
    func testThatEveryPipelineStageHasAnAnswer() {
        let atRest: [PipelineStage] = [.idle, .readyToSave, .saved, .failed, .cancelled]
        for stage in PipelineStage.allCases {
            XCTAssertEqual(FlowRouting.oneVideoIsAtRest(canChoose: modelCanChoose(stage),
                                                        stage: stage),
                           atRest.contains(stage), "\(stage.rawValue)")
        }
    }
}
