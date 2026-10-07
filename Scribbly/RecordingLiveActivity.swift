import Foundation
import Combine
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Mirrors Recorder.shared into a Live Activity so a recording stays visible in
/// the Dynamic Island and on the Lock Screen whenever you leave the app.
@MainActor
final class RecordingLiveActivity {
    static let shared = RecordingLiveActivity()
    private var bag = Set<AnyCancellable>()
    private var started = false

    func bind() {
        guard !started else { return }
        started = true
        let rec = Recorder.shared
        rec.$state.combineLatest(rec.$appendTo)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, appendTo in self?.sync(state: state, appending: appendTo != nil) }
            .store(in: &bag)
    }

    private func sync(state: Recorder.State, appending: Bool) {
        guard #available(iOS 16.2, *) else { return }
        let elapsed = Recorder.shared.elapsed
        switch state {
        case .recording, .paused:
            let cs = RecordingActivityAttributes.ContentState(
                timerStart: Date().addingTimeInterval(-elapsed),
                paused: state == .paused,
                pausedElapsed: Int(elapsed),
                appending: appending)
            let content = ActivityContent(state: cs, staleDate: nil)
            if let a = Activity<RecordingActivityAttributes>.activities.first {
                Task { await a.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                _ = try? Activity.request(attributes: RecordingActivityAttributes(title: "Scribbly"),
                                          content: content, pushType: nil)
            }
        case .finishing, .idle:
            for a in Activity<RecordingActivityAttributes>.activities {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}
