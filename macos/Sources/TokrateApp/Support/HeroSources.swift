import Foundation
import TokrateCore

// The one place that decides which value the gauge and the menu-bar item show. The popover builds
// it through `DashboardSnapshot`, the menu bar through `HistoryStore.refreshLiveReadout`; both end
// in `reading(live:liveGroup:)`, so they cannot drift. Nothing here builds a whole snapshot.

/// The selected cohort and the two history turns a hero reading can fall back to.
struct HeroSources: Equatable, Sendable {
    /// The cohort the selection resolves to; nil for All models and when there is no history.
    let cohort: ModelCohort?
    /// The selected model's latest turn with response data (any coding tool and source kind).
    let responseHero: TurnMetric?
    /// The selected cohort's latest turn with an eligible turn speed: the fallback for sources
    /// without per-response timing.
    let turnHero: TurnMetric?

    /// `retained` are the turns inside retention that pass the client and provider filters
    /// (`withinRetention`, `filtered`). One pass over them finds both heroes.
    init(retained: [TurnMetric], selection: DashboardSelection, activeModel: ResponseGroupKey?) {
        let resolved: ModelCohort? = switch selection {
        case .auto, .autoTool: AutoSelection.resolve(records: retained, activeModel: activeModel, client: selection.autoClient)
        case .cohort(let cohort): cohort
        case .all: nil
        }
        cohort = resolved
        guard let resolved else {
            responseHero = nil
            turnHero = nil
            return
        }
        // Response speed is one definition across tools: it merges a model's cohorts. An unknown
        // model has no identity to merge on, so it stays in its exact cohort.
        let group = resolved.model == nil ? nil : ResponseGroupKey(resolved)
        var response: TurnMetric?
        var turn: TurnMetric?
        for metric in retained {
            if metric.responseSpeedTPS != nil, response.map({ $0.completedAt < metric.completedAt }) ?? true,
               group.map({ ResponseGroupKey(metric) == $0 }) ?? (ModelCohort(metric) == resolved) {
                response = metric
            }
            if DashboardSnapshot.isThroughputEligible(metric), turn.map({ $0.completedAt < metric.completedAt }) ?? true,
               ModelCohort(metric) == resolved {
                turn = metric
            }
        }
        responseHero = response
        turnHero = turn
    }

    /// The same, from raw history: applies the retention window and the dashboard filters first.
    init(
        records: [TurnMetric], selection: DashboardSelection, activeModel: ResponseGroupKey?,
        now: Date, clientFilter: String?, providerFilter: String?
    ) {
        self.init(
            retained: Self.filtered(Self.withinRetention(records, now: now), clientFilter: clientFilter, providerFilter: providerFilter),
            selection: selection, activeModel: activeModel
        )
    }

    /// Turns completed inside the retention window and not in the future.
    static func withinRetention(_ records: [TurnMetric], now: Date) -> [TurnMetric] {
        let cutoff = now.addingTimeInterval(-MetricHistory.retention)
        return records.filter { $0.completedAt >= cutoff && $0.completedAt <= now }
    }

    /// Turns that pass the dashboard's coding-tool and provider filters.
    static func filtered(_ records: [TurnMetric], clientFilter: String?, providerFilter: String?) -> [TurnMetric] {
        guard clientFilter != nil || providerFilter != nil else { return records }
        return records.filter { metric in
            (clientFilter == nil || metric.client == clientFilter)
                && (providerFilter == nil || (metric.provider ?? "unknown") == providerFilter)
        }
    }

    /// The reading: the live median first, then the model's latest turn with response data, then the
    /// cohort's latest turn speed for sources without per-response timing. A live value stands on its
    /// own, even before any turn of its model is in the history.
    func reading(live: LiveSpeed?, liveGroup: ResponseGroupKey?) -> HeroReading {
        if let live, let liveGroup {
            return HeroReading(
                kind: .live, value: live.medianTPS, model: liveGroup.model, provider: liveGroup.provider,
                effort: cohort?.reasoningEffort, chip: cohort?.measurement.chipTitle, completedAt: live.latestAt,
                responseCount: live.responseCount, cohort: cohort, client: live.client
            )
        }
        guard let cohort else { return .empty }
        if let turn = responseHero, let speed = turn.responseSpeedTPS {
            return Self.reading(of: turn, kind: .latestTurnResponse, value: speed, responseCount: turn.responseCount)
        }
        if let turn = turnHero {
            return Self.reading(of: turn, kind: .turnFallback, value: turn.turnThroughputTPS, responseCount: nil)
        }
        return HeroReading(
            kind: .empty, value: nil, model: cohort.model, provider: cohort.provider, effort: cohort.reasoningEffort,
            chip: cohort.measurement.chipTitle, completedAt: nil, responseCount: nil, cohort: cohort, client: cohort.client
        )
    }

    private static func reading(of turn: TurnMetric, kind: HeroReading.Kind, value: Double, responseCount: Int?) -> HeroReading {
        HeroReading(
            kind: kind, value: value, model: turn.model, provider: turn.provider, effort: turn.reasoningEffort,
            chip: turn.isSubagentTurn ? "Subagent" : ModelCohort(turn).measurement.chipTitle,
            completedAt: turn.completedAt, responseCount: responseCount, cohort: ModelCohort(turn), client: turn.client
        )
    }
}
