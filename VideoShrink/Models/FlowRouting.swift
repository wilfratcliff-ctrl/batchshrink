import Foundation

/// Whether the user may move between BatchShrink's two flows, and why they stay put when they
/// may not.
///
/// The two flows drive the same services, and each one carries a control that crosses to the
/// other, so both controls ask this one rule rather than deciding for themselves. The intent is
/// deliberately narrow: a flow may be left when it holds no work in flight, because the screen
/// being left is the only place that work can be seen or stopped.
///
/// A finished copy that has not been saved is not work in flight. The export is over, the app
/// keeps the copy on purpose because it cost the user a whole run, and the one-video flow is the
/// only screen that can save or discard it. Treating `.readyToSave` as work in flight is what
/// makes a kept copy unreachable after a reload, so it is a stage the user may leave.
enum FlowRouting {
    /// Whether the move may go ahead, or which flow is holding the user where they are.
    enum Decision: Equatable {
        /// Nothing on either side is in flight, so the move may go ahead.
        case maySwitch
        /// Refused. The reason names the flow whose work keeps the user where they are.
        case stay(Reason)

        /// Which side refused the move.
        ///
        /// A reason describes that flow's state and never the direction the user was travelling
        /// in, so it stays true whichever control asked and whichever flow the user was on. The
        /// direction is not an input to this rule at all.
        enum Reason: Equatable {
            /// The one-video flow has a run, a save or an open picker under way.
            case oneVideoBusy
            /// The batch flow has a run under way, or items still to process.
            case batchBusy
        }
    }

    /// Whether the one-video flow has come to rest and may be left.
    ///
    /// `canChoose` is the model's own answer: true when no task is running and the stage is one a
    /// run may start from again. Every stage a run is in flight from is outside it, and so is
    /// `.choosing`, where no task runs but a picker owns the screen. The one stage it leaves out
    /// that has still come to rest is `.readyToSave`, where a finished copy waits to be saved or
    /// discarded.
    static func oneVideoIsAtRest(canChoose: Bool, stage: PipelineStage) -> Bool {
        canChoose || stage == .readyToSave
    }

    /// Whether the user may move from one flow to the other.
    ///
    /// The rule is not told which flow is being left, so both sides are asked and either one
    /// holding work keeps the user where that work is. The batch side is its own answer,
    /// `BatchViewModel.canLeaveFlow`, which is true only when no run is under way and nothing is
    /// left to process; it is consulted whichever way the user is moving, so a run cannot be
    /// walked away from by arriving at it either.
    static func decision(oneVideoCanChoose: Bool,
                         stage: PipelineStage,
                         batchCanLeaveFlow: Bool) -> Decision {
        guard oneVideoIsAtRest(canChoose: oneVideoCanChoose, stage: stage) else {
            return .stay(.oneVideoBusy)
        }
        guard batchCanLeaveFlow else { return .stay(.batchBusy) }
        return .maySwitch
    }
}
