import Foundation
import XCTest
@testable import TokrateCore

/// Contract "Error notifications (0.1.23)": episodes, the recovery window, the hourly limit, the
/// baseline, the clearing, and the exact texts.
final class ErrorNotificationPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let minute: TimeInterval = 60

    private func alert(
        _ model: String, contributors: Int = 3, overloaded: Int = 4, serverError: Int = 0, own: Bool = false
    ) -> CommunityErrorAlerts.RelevantAlert {
        CommunityErrorAlerts.RelevantAlert(
            alert: GlobalBoard.ErrorAlert(
                model: model, provider: "anthropic", clients: ["claude-code"], failingContributors: contributors,
                overloaded: overloaded, serverError: serverError, lastFailureAt: t0
            ),
            ownFailure: own,
            otherContributors: contributors - 1
        )
    }

    private func plan(
        _ planner: inout ErrorNotificationPlanner, _ alerts: [CommunityErrorAlerts.RelevantAlert]?,
        at minutes: Double, sharing: Bool = true, enabled: Bool = true
    ) -> [ErrorNotification] {
        planner.plan(relevant: alerts, isSharing: sharing, isEnabled: enabled, now: t0.addingTimeInterval(minutes * minute))
    }

    /// A planner whose baseline (an empty board) is taken.
    private func baselined() -> ErrorNotificationPlanner {
        var planner = ErrorNotificationPlanner()
        XCTAssertEqual(plan(&planner, [], at: 0), [])
        return planner
    }

    // MARK: Texts

    func testStartTextWhenTheUserHasNotFailed() {
        var planner = baselined()
        let result = plan(&planner, [alert("claude-opus-5-5", contributors: 3, overloaded: 4)], at: 1)
        XCTAssertEqual(result, [
            ErrorNotification(
                kind: .start, model: "claude-opus-5-5", title: "Provider errors on claude-opus-5-5",
                body: "3 Tokrate contributors reported 4 overloaded / at capacity in the last hour."
            )
        ])
    }

    func testStartTextCountsAndSingularContributor() {
        var planner = baselined()
        XCTAssertEqual(
            plan(&planner, [alert("a", contributors: 1, overloaded: 0, serverError: 1)], at: 1).map(\.body),
            ["1 Tokrate contributor reported 1 server error in the last hour."]
        )
        XCTAssertEqual(
            plan(&planner, [alert("a", contributors: 1, overloaded: 0, serverError: 1), alert("b", contributors: 5, overloaded: 1, serverError: 2)], at: 2).map(\.body),
            ["5 Tokrate contributors reported 1 overloaded / at capacity and 2 server errors in the last hour."]
        )
    }

    func testStartTextAfterALocalFailure() {
        var planner = baselined()
        XCTAssertEqual(
            plan(&planner, [alert("m", contributors: 3, own: true)], at: 1),
            [
                ErrorNotification(
                    kind: .start, model: "m", title: "Provider errors on m",
                    body: "It’s not just you: 2 other contributors hit provider errors on this model in the last hour."
                )
            ]
        )
        XCTAssertEqual(
            plan(&planner, [alert("m", contributors: 3, own: true), alert("n", contributors: 2, own: true)], at: 2).map(\.body),
            ["It’s not just you: 1 other contributor hit provider errors on this model in the last hour."]
        )
    }

    func testRecoveryTextAndIdentifiers() {
        var planner = baselined()
        let started = plan(&planner, [alert("m")], at: 1)
        _ = plan(&planner, [], at: 2)
        let ended = plan(&planner, [], at: 32)
        XCTAssertEqual(ended, [
            ErrorNotification(kind: .recovery, model: "m", title: "m looks healthy again", body: "Contributors no longer report provider errors on this model.")
        ])
        XCTAssertEqual(started.first?.identifier, "provider-errors.start.m")
        XCTAssertEqual(ended.first?.identifier, "provider-errors.recovery.m")
    }

    // MARK: Episodes

    func testAnEpisodeStartsOnceNoMatterHowLongTheAlertStays() {
        var planner = baselined()
        XCTAssertEqual(plan(&planner, [alert("m")], at: 1).count, 1)
        for minute in 2...20 { XCTAssertEqual(plan(&planner, [alert("m")], at: Double(minute)), []) }
    }

    func testEachModelHasItsOwnEpisodeInRelevanceOrder() {
        var planner = baselined()
        XCTAssertEqual(plan(&planner, [alert("b"), alert("a")], at: 1).map(\.model), ["b", "a"])
        XCTAssertEqual(plan(&planner, [alert("b"), alert("a"), alert("c")], at: 2).map(\.model), ["c"])
    }

    func testRecoveryNeedsTheFullWindowOfAbsence() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        XCTAssertEqual(plan(&planner, [], at: 2), [])
        XCTAssertEqual(plan(&planner, [], at: 31.9), [])
        XCTAssertEqual(plan(&planner, [], at: 32).map(\.kind), [.recovery])
        // Said once.
        XCTAssertEqual(plan(&planner, [], at: 33), [])
    }

    func testReappearanceWithinTheWindowContinuesTheEpisode() {
        var planner = baselined()
        XCTAssertEqual(plan(&planner, [alert("m")], at: 1).count, 1)
        XCTAssertEqual(plan(&planner, [], at: 5), [])
        XCTAssertEqual(plan(&planner, [alert("m")], at: 20), [])
        // The absence restarts: the window counts from the new departure.
        XCTAssertEqual(plan(&planner, [], at: 25), [])
        XCTAssertEqual(plan(&planner, [], at: 54), [])
        XCTAssertEqual(plan(&planner, [], at: 55).map(\.kind), [.recovery])
    }

    func testAnAlertAfterTheWindowStartsANewEpisode() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        _ = plan(&planner, [], at: 2)
        XCTAssertEqual(plan(&planner, [], at: 40).map(\.kind), [.recovery])
        XCTAssertEqual(plan(&planner, [alert("m")], at: 120).map(\.kind), [.start])
    }

    func testAnEpisodeThatRanOutUnobservedStartsAgainWithoutARecovery() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        XCTAssertEqual(plan(&planner, [], at: 2), [])
        // No evaluation for hours (for example the Mac slept), then the alert is back.
        XCTAssertEqual(plan(&planner, [alert("m")], at: 300).map(\.kind), [.start])
    }

    func testBoardsMissingBrieflyChangeNothing() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        XCTAssertEqual(plan(&planner, nil, at: 10), [])
        // Still the same episode: no second start, and the absence has not begun.
        XCTAssertEqual(plan(&planner, [alert("m")], at: 11), [])
        XCTAssertEqual(plan(&planner, [], at: 12), [])
        XCTAssertEqual(plan(&planner, [], at: 41), [])
        XCTAssertEqual(plan(&planner, [], at: 42).map(\.kind), [.recovery])
    }

    func testBoardsMissingForTheWholeWindowEndTheEpisodeUnannounced() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        XCTAssertEqual(plan(&planner, nil, at: 10), [])
        XCTAssertEqual(plan(&planner, nil, at: 100), [])
        // The alert is back after 30 minutes or more without a board: a new episode starts.
        XCTAssertEqual(plan(&planner, [alert("m")], at: 101).map(\.kind), [.start])
    }

    func testAnEpisodeAbsentFromTheBoardAfterAGapEndsOnceItHasBeenAbsentForTheWindow() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        XCTAssertEqual(plan(&planner, nil, at: 40), [])
        XCTAssertEqual(plan(&planner, [], at: 41), [])
        XCTAssertEqual(plan(&planner, [], at: 70), [])
        XCTAssertEqual(plan(&planner, [], at: 71).map(\.kind), [.recovery])
    }

    // MARK: Hourly limit

    func testAtMostThreePerHourAndASuppressedStartSuppressesItsRecovery() {
        var planner = baselined()
        let started = plan(&planner, [alert("a"), alert("b"), alert("c"), alert("d")], at: 1)
        XCTAssertEqual(started.map(\.model), ["a", "b", "c"])
        // d was suppressed: it stays an episode (no new start) but never gets a recovery.
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c"), alert("d")], at: 2), [])
        // Everything leaves; the first look after the hour finds all four episodes over. The three
        // notified starts recover, the suppressed one (d) does not.
        _ = plan(&planner, [], at: 3)
        XCTAssertEqual(plan(&planner, [], at: 65).map(\.model), ["a", "b", "c"])
    }

    func testTheLimitIsAnHourlyWindow() {
        var planner = baselined()
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c")], at: 1).count, 3)
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c"), alert("d")], at: 30), [])
        // d is an episode already, so it does not start later either.
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c"), alert("d")], at: 50), [])
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c"), alert("d")], at: 70), [])
        // A new model after the hour has room again.
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c"), alert("d"), alert("e")], at: 71).map(\.model), ["e"])
    }

    func testRecoveriesCountTowardsTheLimitAndAreDroppedWhenFull() {
        var planner = baselined()
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b")], at: 1).count, 2)
        _ = plan(&planner, [], at: 2)
        // Two recoveries at minute 32: only one slot is left in the hour of the two starts.
        let recoveries = plan(&planner, [], at: 32)
        XCTAssertEqual(recoveries.map(\.kind), [.recovery])
        XCTAssertEqual(recoveries.map(\.model), ["a"])
        XCTAssertEqual(plan(&planner, [], at: 33), [])
    }

    func testTheLimitSurvivesSwitchingTheSettingOffAndOn() {
        var planner = baselined()
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c")], at: 1).count, 3)
        _ = plan(&planner, [], at: 2, enabled: false)
        _ = plan(&planner, [], at: 3)
        XCTAssertEqual(plan(&planner, [alert("d")], at: 4), [])
    }

    // MARK: Baseline

    func testAlertsPresentAtTheFirstBoardAreNotNotifiedButTheirEndIs() {
        var planner = ErrorNotificationPlanner()
        XCTAssertEqual(plan(&planner, [alert("old")], at: 0), [])
        XCTAssertEqual(plan(&planner, [alert("old")], at: 1), [])
        // A model that appears later does notify.
        XCTAssertEqual(plan(&planner, [alert("old"), alert("new")], at: 2).map(\.model), ["new"])
        // The baselined alert counts as notified: its recovery is posted.
        _ = plan(&planner, [alert("new")], at: 3)
        _ = plan(&planner, [alert("new")], at: 20)
        XCTAssertEqual(plan(&planner, [alert("new")], at: 33).map(\.kind), [.recovery])
    }

    func testTheBaselineWaitsForTheFirstBoard() {
        var planner = ErrorNotificationPlanner()
        XCTAssertEqual(plan(&planner, nil, at: 0), [])
        XCTAssertEqual(plan(&planner, nil, at: 1), [])
        XCTAssertEqual(plan(&planner, [alert("m")], at: 2), [])
        XCTAssertEqual(plan(&planner, [alert("m"), alert("n")], at: 3).map(\.model), ["n"])
    }

    func testAlertsPresentWhenTheSettingTurnsOnAreBaselined() {
        var planner = ErrorNotificationPlanner()
        XCTAssertEqual(plan(&planner, [alert("m")], at: 0, enabled: false), [])
        XCTAssertEqual(plan(&planner, [alert("m")], at: 1, enabled: true), [])
        XCTAssertEqual(plan(&planner, [alert("m")], at: 2, enabled: true), [])
    }

    func testAlertsPresentWhenSharingTurnsOnAreBaselined() {
        var planner = baselined()
        _ = plan(&planner, [alert("a")], at: 1)
        XCTAssertEqual(plan(&planner, nil, at: 2, sharing: false), [])
        // Sharing back on: no board yet, then a board that still lists a and a new b.
        XCTAssertEqual(plan(&planner, nil, at: 3), [])
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b")], at: 4), [])
        XCTAssertEqual(plan(&planner, [alert("a"), alert("b"), alert("c")], at: 5).map(\.model), ["c"])
    }

    // MARK: Clearing

    func testSharingOffClearsEpisodesSoNoRecoveryFollows() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        XCTAssertEqual(plan(&planner, nil, at: 2, sharing: false), [])
        XCTAssertEqual(plan(&planner, [], at: 3), [])
        XCTAssertEqual(plan(&planner, [], at: 40), [])
    }

    func testSettingOffClearsEpisodesSoNoRecoveryFollows() {
        var planner = baselined()
        _ = plan(&planner, [alert("m")], at: 1)
        XCTAssertEqual(plan(&planner, [alert("m")], at: 2, enabled: false), [])
        XCTAssertEqual(plan(&planner, [], at: 3), [])
        XCTAssertEqual(plan(&planner, [], at: 40), [])
    }

    func testNothingIsPlannedWhileOff() {
        var planner = ErrorNotificationPlanner()
        XCTAssertEqual(plan(&planner, [alert("m")], at: 0, sharing: false, enabled: false), [])
        XCTAssertEqual(plan(&planner, [alert("m")], at: 1, sharing: true, enabled: false), [])
        XCTAssertEqual(plan(&planner, [alert("m")], at: 2, sharing: false, enabled: true), [])
    }
}
