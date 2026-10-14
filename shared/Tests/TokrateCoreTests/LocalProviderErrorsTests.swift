import Foundation
import XCTest
@testable import TokrateCore

/// Contract "Local provider errors (0.1.23)": the in-memory 24-hour summary and its one line.
final class LocalProviderErrorsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func outcome(
        _ key: String, client: String = "claude-code", model: String = "claude-opus-5-5",
        kind: RequestOutcome.Kind = .overloaded, ago: TimeInterval = 60, percent: Int? = nil
    ) -> RequestOutcome {
        let parsers = ["claude-code": "claude-transcript-v4", "codex": "codex-rollout-v2", "opencode": "opencode-db-v1", "kimi-code": "kimi-wire-v1"]
        let providers = ["claude-code": "anthropic", "codex": "openai", "opencode": "anthropic", "kimi-code": "moonshot"]
        return RequestOutcome(
            dedupeKey: key, occurredAt: now.addingTimeInterval(-ago), client: client, clientVersion: "1.0.0",
            parserVersion: parsers[client]!, model: model, provider: providers[client]!, kind: kind, planUsagePercent: percent
        )!
    }

    private func line(_ errors: LocalProviderErrors, at date: Date? = nil) -> String? {
        errors.line(now: date ?? now) { "REL(\(Int((date ?? now).timeIntervalSince($0))))" }
    }

    // MARK: Templates

    func testCodexOverloadedIsModelAtCapacityWithPluralTimes() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", client: "codex", model: "gpt-5.5", ago: 120), outcome("b", client: "codex", model: "gpt-5.5", ago: 60)], now: now)
        XCTAssertEqual(line(errors), "You hit “model at capacity” 2 times on gpt-5.5 in the last 24 hours, most recently REL(60). That’s the provider at capacity, not your connection.")
    }

    func testSingularTimeAndOtherToolsSayOverloaded() {
        for client in ["claude-code", "opencode", "kimi-code"] {
            var errors = LocalProviderErrors()
            errors.add([outcome("a", client: client, model: "m1")], now: now)
            XCTAssertEqual(line(errors), "You hit “overloaded” 1 time on m1 in the last 24 hours, most recently REL(60). That’s the provider at capacity, not your connection.", client)
        }
    }

    func testServerErrorTemplateSingularAndPlural() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", kind: .serverError)], now: now)
        XCTAssertEqual(line(errors), "claude-opus-5-5 returned 1 server error in the last 24 hours, most recently REL(60). That’s a failure at the provider, not your connection.")
        errors.add([outcome("b", kind: .serverError, ago: 30)], now: now)
        XCTAssertEqual(line(errors), "claude-opus-5-5 returned 2 server errors in the last 24 hours, most recently REL(30). That’s a failure at the provider, not your connection.")
    }

    func testThrottledTemplateWithAndWithoutThePlanPercentage() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", client: "codex", model: "gpt-5.5", kind: .throttled, percent: 41)], now: now)
        XCTAssertEqual(line(errors), "You were rate limited 1 time on gpt-5.5 in the last 24 hours while your plan still had quota left (41% used). That’s the provider throttling, not your plan limit.")
        var plain = LocalProviderErrors()
        plain.add([outcome("a", model: "m1", kind: .throttled)], now: now)
        XCTAssertEqual(line(plain), "You were rate limited 1 time on m1 in the last 24 hours while your plan still had quota left. That’s the provider throttling, not your plan limit.")
    }

    func testThrottledPluralUsesThePercentageOfTheLatestFailure() {
        var errors = LocalProviderErrors()
        errors.add([
            outcome("a", client: "codex", model: "gpt-5.5", kind: .throttled, ago: 300, percent: 12),
            outcome("c", client: "codex", model: "gpt-5.5", kind: .throttled, ago: 30, percent: 58),
            outcome("b", client: "codex", model: "gpt-5.5", kind: .throttled, ago: 120, percent: 33)
        ], now: now)
        XCTAssertEqual(line(errors), "You were rate limited 3 times on gpt-5.5 in the last 24 hours while your plan still had quota left (58% used). That’s the provider throttling, not your plan limit.")
        // A later failure without a percentage replaces the figure rather than showing a stale one.
        errors.add([outcome("d", client: "codex", model: "gpt-5.5", kind: .throttled, ago: 10)], now: now)
        XCTAssertEqual(line(errors)?.contains("used)"), false)
    }

    func testThrottledGroupsOrderAndAppearInAlsoLikeOtherKinds() {
        var errors = LocalProviderErrors()
        errors.add([
            outcome("a", model: "main", kind: .serverError, ago: 10),
            outcome("b", model: "slow", kind: .throttled, ago: 100),
            outcome("c", model: "slow", kind: .throttled, ago: 110),
            outcome("d", model: "slow", kind: .overloaded, ago: 200)
        ], now: now)
        XCTAssertEqual(errors.groups(now: now).map(\.kind), [.serverError, .throttled, .overloaded])
        XCTAssertEqual(line(errors)?.hasSuffix(" Also: slow (2), slow (1)"), true)
        var onlyThrottled = LocalProviderErrors()
        onlyThrottled.add([outcome("a", kind: .throttled, ago: 10), outcome("b", model: "other", ago: 50)], now: now)
        XCTAssertEqual(line(onlyThrottled)?.hasPrefix("You were rate limited 1 time on claude-opus-5-5"), true)
        XCTAssertEqual(line(onlyThrottled)?.hasSuffix(" Also: other (1)"), true)
    }

    func testAnOutcomeKeepsAPlanPercentageOnlyWhenThrottledAndInRange() {
        XCTAssertEqual(outcome("a", kind: .throttled, percent: 94).planUsagePercent, 94)
        XCTAssertNil(outcome("a", kind: .overloaded, percent: 50).planUsagePercent)
        XCTAssertNil(outcome("a", kind: .throttled, percent: 101).planUsagePercent)
        XCTAssertNil(outcome("a", kind: .throttled, percent: -1).planUsagePercent)
    }

    func testCodexServerErrorDoesNotUseTheCapacityWording() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", client: "codex", model: "gpt-5.5", kind: .serverError)], now: now)
        XCTAssertEqual(line(errors)?.hasPrefix("gpt-5.5 returned 1 server error"), true)
    }

    func testNoFailureHasNoLine() {
        var errors = LocalProviderErrors()
        XCTAssertNil(line(errors))
        errors.add([outcome("a", kind: .succeeded)], now: now)
        XCTAssertNil(line(errors))
        XCTAssertTrue(errors.groups(now: now).isEmpty)
    }

    // MARK: Also suffix

    func testAlsoSuffixListsAtMostTwoOtherGroupsMostRecentFirst() {
        var errors = LocalProviderErrors()
        errors.add([
            outcome("a", model: "main", ago: 10),
            outcome("b", model: "older", ago: 300),
            outcome("c", model: "older", ago: 310),
            outcome("d", model: "newer", kind: .serverError, ago: 100),
            outcome("e", client: "codex", model: "third", ago: 400)
        ], now: now)
        XCTAssertEqual(line(errors)?.hasSuffix(" Also: newer (1), older (2)"), true)
        XCTAssertEqual(line(errors)?.contains("third"), false)
    }

    func testTheSameModelOfAnotherKindOrToolIsAnotherGroup() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", ago: 10), outcome("b", kind: .serverError, ago: 20), outcome("c", client: "opencode", ago: 30)], now: now)
        XCTAssertEqual(errors.groups(now: now).count, 3)
        XCTAssertEqual(line(errors)?.hasSuffix(" Also: claude-opus-5-5 (1), claude-opus-5-5 (1)"), true)
    }

    // MARK: Window, dedupe, bounds

    func testFailuresExpire24HoursAfterTheirTimeAndCountsDecay() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", ago: 23 * 3_600), outcome("b", ago: 60)], now: now)
        XCTAssertEqual(line(errors, at: now)?.contains(" 2 times"), true)
        let later = now.addingTimeInterval(2 * 3_600)
        XCTAssertEqual(line(errors, at: later)?.contains(" 1 time "), true)
        XCTAssertNil(line(errors, at: now.addingTimeInterval(24 * 3_600 + 61)))
        errors.prune(now: now.addingTimeInterval(24 * 3_600 + 61))
        XCTAssertTrue(errors.groups(now: now).isEmpty)
    }

    func testOutcomesOlderThanTheWindowAreIgnored() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", ago: 24 * 3_600 + 1)], now: now)
        XCTAssertNil(line(errors))
    }

    func testFutureOutcomeCountsAsNow() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", ago: -600)], now: now)
        XCTAssertEqual(errors.groups(now: now).first?.latest, now)
    }

    func testTheSameDedupeKeyCountsOnce() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a")], now: now)
        errors.add([outcome("a"), outcome("a")], now: now)
        XCTAssertEqual(errors.groups(now: now).first?.count, 1)
    }

    func testGroupsAreBoundedAndTheOldestLatestIsDropped() {
        var errors = LocalProviderErrors()
        errors.add((0..<(LocalProviderErrors.maximumGroups + 5)).map { outcome("k\($0)", model: "m\($0)", ago: Double(10_000 - $0)) }, now: now)
        let groups = errors.groups(now: now)
        XCTAssertEqual(groups.count, LocalProviderErrors.maximumGroups)
        XCTAssertEqual(groups.first?.model, "m204")
        XCTAssertFalse(groups.contains { $0.model == "m0" || $0.model == "m4" })
        XCTAssertTrue(groups.contains { $0.model == "m5" })
    }

    func testFailuresPerGroupAreBounded() {
        var errors = LocalProviderErrors()
        errors.add((0..<(LocalProviderErrors.maximumFailuresPerGroup + 10)).map { outcome("k\($0)", ago: Double(5_000 - $0)) }, now: now)
        XCTAssertEqual(errors.groups(now: now).first?.count, LocalProviderErrors.maximumFailuresPerGroup)
        XCTAssertEqual(errors.groups(now: now).first?.latest, now.addingTimeInterval(-(5_000 - Double(LocalProviderErrors.maximumFailuresPerGroup + 9))))
    }

    func testOutOfOrderFailuresKeepTheLatestTime() {
        var errors = LocalProviderErrors()
        errors.add([outcome("a", ago: 10), outcome("b", ago: 500)], now: now)
        XCTAssertEqual(errors.groups(now: now).first?.latest, now.addingTimeInterval(-10))
    }
}
