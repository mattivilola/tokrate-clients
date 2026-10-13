import Foundation
import XCTest
@testable import TokrateCore

/// Contract "Community error alerts (0.1.23)": relevance, ordering, the line forms and recovery.
final class CommunityErrorAlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let used: Set<String> = ["m1", "m2", "m3", "m4"]

    private func alert(
        _ model: String, contributors: Int = 3, overloaded: Int = 2, serverError: Int = 0, lastAgo: TimeInterval = 120
    ) -> GlobalBoard.ErrorAlert {
        GlobalBoard.ErrorAlert(
            model: model, provider: "anthropic", clients: ["claude-code"], failingContributors: contributors,
            overloaded: overloaded, serverError: serverError,
            firstFailureAt: now.addingTimeInterval(-lastAgo - 600), lastFailureAt: now.addingTimeInterval(-lastAgo)
        )
    }

    /// The user's own failures, as the local summary reports them.
    private func local(_ model: String, ago: TimeInterval) -> [LocalProviderErrors.Group] {
        var errors = LocalProviderErrors()
        errors.add([
            RequestOutcome(
                dedupeKey: "\(model)-\(ago)", occurredAt: now.addingTimeInterval(-ago), client: "claude-code", clientVersion: "1.0.0",
                parserVersion: "claude-transcript-v4", model: model, provider: "anthropic", kind: .overloaded
            )!
        ], now: now)
        return errors.groups(now: now)
    }

    private func line(
        _ alerts: [GlobalBoard.ErrorAlert], in state: inout CommunityErrorAlerts, used: Set<String>? = nil,
        groups: [LocalProviderErrors.Group] = [], sharing: Bool = true, at date: Date? = nil
    ) -> CommunityErrorAlerts.Line? {
        let at = date ?? now
        let relevant = CommunityErrorAlerts.relevantAlerts(
            alerts, usedModels: used ?? self.used, localGroups: groups, isSharing: sharing, now: at
        )
        return state.line(alerts: alerts, relevant: relevant, now: at) {
            "REL(\(Int(at.timeIntervalSince($0))))"
        }
    }

    private func text(_ alerts: [GlobalBoard.ErrorAlert], used: Set<String>? = nil, groups: [LocalProviderErrors.Group] = [], sharing: Bool = true) -> String? {
        var state = CommunityErrorAlerts()
        return line(alerts, in: &state, used: used, groups: groups, sharing: sharing)?.text
    }

    // MARK: Reporting form

    func testReportingFormWithOverloadedCountsAndPluralContributors() {
        XCTAssertEqual(
            text([alert("m1", contributors: 3, overloaded: 5)]),
            "Tokrate contributors are reporting provider errors on m1: 5 overloaded / at capacity from 3 contributors in the last hour, latest REL(120)."
        )
    }

    func testReportingFormSingularServerErrorAndContributor() {
        XCTAssertEqual(
            text([alert("m1", contributors: 1, overloaded: 0, serverError: 1)]),
            "Tokrate contributors are reporting provider errors on m1: 1 server error from 1 contributor in the last hour, latest REL(120)."
        )
    }

    func testReportingFormJoinsBothCountsAndPluralisesServerErrors() {
        XCTAssertEqual(
            text([alert("m1", contributors: 4, overloaded: 3, serverError: 2)]),
            "Tokrate contributors are reporting provider errors on m1: 3 overloaded / at capacity and 2 server errors from 4 contributors in the last hour, latest REL(120)."
        )
    }

    func testAlertWithoutAnyCountedErrorIsIgnored() {
        XCTAssertNil(text([alert("m1", overloaded: 0, serverError: 0)]))
    }

    // MARK: "It’s not just you"

    func testNotJustYouSubtractsTheUsersOwnContributionWhenSharing() {
        XCTAssertEqual(
            text([alert("m1", contributors: 4)], groups: local("m1", ago: 600)),
            "It’s not just you: 3 other contributors hit provider errors on m1 in the last hour."
        )
        XCTAssertEqual(
            text([alert("m1", contributors: 2)], groups: local("m1", ago: 600)),
            "It’s not just you: 1 other contributor hit provider errors on m1 in the last hour."
        )
    }

    func testAnAlertThatIsOnlyTheUsersOwnReportIsSkippedForTheNextOne() throws {
        let alerts = [alert("m1", contributors: 1), alert("m2", contributors: 3)]
        let line = try XCTUnwrap(text(alerts, groups: local("m1", ago: 600)))
        XCTAssertTrue(line.hasPrefix("Tokrate contributors are reporting provider errors on m2:"), line)
        // The skipped model is not named in "Also" either.
        XCTAssertFalse(line.contains("Also"), line)
    }

    func testAnAlertThatIsOnlyTheUsersOwnReportShowsNothingWhenNothingElseIsRelevant() {
        XCTAssertNil(text([alert("m1", contributors: 1)], groups: local("m1", ago: 600)))
    }

    func testASkippedOwnReportIsNotShownForRecovery() {
        var state = CommunityErrorAlerts()
        XCTAssertNil(line([alert("m1", contributors: 1)], in: &state, groups: local("m1", ago: 600)))
        XCTAssertNil(line([], in: &state, groups: local("m1", ago: 600), at: now.addingTimeInterval(60)))
    }

    func testTheOwnReportIsOnlySkippedForAFailureInTheLastHour() throws {
        // A single contributor with a local failure two hours ago is an ordinary report.
        let line = try XCTUnwrap(text([alert("m1", contributors: 1)], groups: local("m1", ago: 2 * 3_600)))
        XCTAssertTrue(line.hasPrefix("Tokrate contributors are reporting provider errors on m1:"), line)
    }

    func testNotJustYouKeepsAllContributorsWhenSharingIsOff() {
        XCTAssertEqual(
            text([alert("m1", contributors: 1)], groups: local("m1", ago: 600), sharing: false),
            "It’s not just you: 1 other contributor hit provider errors on m1 in the last hour."
        )
    }

    func testALocalFailureOlderThanAnHourDoesNotMakeItNotJustYou() throws {
        let line = try XCTUnwrap(text([alert("m1", contributors: 5)], groups: local("m1", ago: 2 * 3_600)))
        XCTAssertTrue(line.hasPrefix("Tokrate contributors are reporting provider errors on m1:"))
    }

    // MARK: Relevance and ordering

    func testOnlyModelsUsedInSevenDaysOrFailedLocallyInADayAreShown() {
        XCTAssertNil(text([alert("other")]))
        XCTAssertNotNil(text([alert("other")], used: ["other"]))
        // Not used, but failed locally 20 hours ago.
        XCTAssertNotNil(text([alert("other")], used: [], groups: local("other", ago: 20 * 3_600)))
        // Local failures of some other model say nothing about this alert.
        XCTAssertNil(text([alert("other")], used: [], groups: local("m1", ago: 600)))
    }

    func testModelIdsMatchExactly() {
        XCTAssertNil(text([alert("claude-opus-5-5")], used: ["claude-opus-5"]))
    }

    func testAModelWithALocalFailureInTheLastHourComesFirstThenServerOrder() {
        let alerts = [alert("m1"), alert("m2"), alert("m3")]
        let line = text(alerts, groups: local("m3", ago: 300))
        XCTAssertTrue(line?.contains("on m3") == true)
        XCTAssertTrue(line?.hasSuffix(" Also: m1, m2") == true, line ?? "nil")
        // Without a recent failure the server's order stands.
        XCTAssertTrue(text(alerts)?.hasPrefix("Tokrate contributors are reporting provider errors on m1:") == true)
    }

    func testAlsoListsAtMostTwoMoreModelsAndSkipsIrrelevantOnes() throws {
        let alerts = [alert("m1"), alert("nope"), alert("m2"), alert("m3"), alert("m4")]
        let line = try XCTUnwrap(text(alerts))
        XCTAssertTrue(line.hasSuffix("latest REL(120). Also: m2, m3"), line)
    }

    func testAlsoIsAbsentWithASingleRelevantAlert() throws {
        let line = try XCTUnwrap(text([alert("m1"), alert("nope")]))
        XCTAssertFalse(line.contains("Also"))
    }

    func testTheSameModelAlertedForTwoProvidersIsOneEntry() throws {
        let line = try XCTUnwrap(text([alert("m1"), alert("m1"), alert("m2")]))
        XCTAssertTrue(line.hasSuffix(" Also: m2"), line)
    }

    func testNoAlertsAndNoHistoryMeansNoLine() {
        XCTAssertNil(text([]))
    }

    // MARK: Recovery

    func testRecoveryReplacesTheMissingAlertLineForThirtyMinutes() throws {
        var state = CommunityErrorAlerts()
        let shown = line([alert("m1")], in: &state)
        XCTAssertEqual(shown?.kind, .alert)

        let cleared = now.addingTimeInterval(60)
        XCTAssertEqual(
            line([], in: &state, at: cleared),
            CommunityErrorAlerts.Line(kind: .recovery, text: "m1: contributors no longer report provider errors (cleared REL(0)).")
        )
        // Still there, with the time since it cleared, up to the 30th minute.
        XCTAssertEqual(
            line([], in: &state, at: cleared.addingTimeInterval(29 * 60))?.text,
            "m1: contributors no longer report provider errors (cleared REL(1740))."
        )
        XCTAssertNil(line([], in: &state, at: cleared.addingTimeInterval(30 * 60 + 1)))
        // Forgotten for good.
        XCTAssertNil(line([], in: &state, at: cleared.addingTimeInterval(31 * 60)))
    }

    func testNoRecoveryForAModelWhoseAlertWasNeverShown() {
        var state = CommunityErrorAlerts()
        XCTAssertNil(line([alert("nope")], in: &state))
        XCTAssertNil(line([], in: &state, at: now.addingTimeInterval(60)))
    }

    func testNoRecoveryWhileAnotherAlertIsShown() {
        var state = CommunityErrorAlerts()
        _ = line([alert("m1"), alert("m2")], in: &state)
        let later = now.addingTimeInterval(60)
        // m1 cleared, m2 is still alerted: the alert line wins.
        let result = line([alert("m2")], in: &state, at: later)
        XCTAssertEqual(result?.kind, .alert)
        XCTAssertTrue(result?.text.contains("m2") == true)
        // Once m2 clears as well, the most recent clearing (m2) is the one named.
        let muchLater = later.addingTimeInterval(120)
        XCTAssertEqual(
            line([], in: &state, at: muchLater)?.text,
            "m2: contributors no longer report provider errors (cleared REL(0))."
        )
    }

    func testRecoveryIsForgottenWhenTheAlertReturnsAndANewClearingStartsFresh() {
        var state = CommunityErrorAlerts()
        _ = line([alert("m1")], in: &state)
        XCTAssertEqual(line([], in: &state, at: now.addingTimeInterval(60))?.kind, .recovery)
        XCTAssertEqual(line([alert("m1")], in: &state, at: now.addingTimeInterval(120))?.kind, .alert)
        let cleared = now.addingTimeInterval(180)
        XCTAssertEqual(line([], in: &state, at: cleared)?.kind, .recovery)
        XCTAssertEqual(line([], in: &state, at: cleared.addingTimeInterval(10))?.text, "m1: contributors no longer report provider errors (cleared REL(10)).")
    }

    func testAnAlertShownOnlyInAlsoCountsAsShown() {
        var state = CommunityErrorAlerts()
        _ = line([alert("m1"), alert("m2")], in: &state)
        XCTAssertEqual(line([alert("m1")], in: &state, at: now.addingTimeInterval(60))?.kind, .alert)
        XCTAssertEqual(line([], in: &state, at: now.addingTimeInterval(120))?.kind, .recovery)
    }

    func testResetForgetsWhatWasShown() {
        var state = CommunityErrorAlerts()
        _ = line([alert("m1")], in: &state)
        state.reset()
        XCTAssertNil(line([], in: &state, at: now.addingTimeInterval(60)))
    }

    func testTheSharingHintText() {
        XCTAssertEqual(CommunityErrorAlerts.sharingHint, "Turn on sharing to see whether other contributors hit the same errors.")
    }
}
