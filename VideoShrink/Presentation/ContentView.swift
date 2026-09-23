import SwiftUI

/// BatchShrink has two ways in: shrink several videos at once, or shrink one and look at
/// it before it reaches Photos. Both drive the same services and the same safety rules.
struct ContentView: View {
    enum Flow {
        case batch, single
    }

    @ObservedObject var model: CompressionViewModel
    @ObservedObject var batch: BatchViewModel
    @State private var flow: Flow = .batch
    @AppStorage("batchShrink.onboarding.v1") private var hasOnboarded = false

    var body: some View {
        Group {
            if !hasOnboarded && batch.phase == .start && model.stage == .idle {
                ShrinkOnboarding { hasOnboarded = true }
            } else {
                NavigationStack {
                    switch flow {
                    case .batch:
                        BatchFlow(batch: batch, useSingleVideo: { switchTo(.single) })
                    case .single:
                        SingleVideoFlow(model: model, useBatch: { switchTo(.batch) })
                    }
                }
            }
        }
        .tint(ShrinkStyle.accent)
        .preferredColorScheme(.dark)
        .background(ShrinkStyle.canvas)
    }

    private func switchTo(_ next: Flow) {
        guard flow != next else { return }
        // Each flow stays in charge of its own run: never walk away from work in progress.
        guard model.canChoose, batch.canLeaveFlow else { return }
        flow = next
    }
}
