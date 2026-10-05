import { useMemo } from "react";
import { buildDashboard } from "./dashboard";
import { useStore, type AppStore } from "../store/store";

/** Derives the dashboard from the polled snapshot; recomputed only when its inputs change. */
export function useDashboard(store: AppStore) {
  const records = useStore(store, (s) => s.snapshot.records);
  const settings = useStore(store, (s) => s.snapshot.settings);
  const now = useStore(store, (s) => s.now);
  const toolFilter = useStore(store, (s) => s.ui.toolFilter);
  const providerFilter = useStore(store, (s) => s.ui.providerFilter);
  const sort = useStore(store, (s) => s.ui.sort);
  const live = useStore(store, (s) => s.snapshot.live);
  const active = useStore(store, (s) => s.snapshot.active);
  return useMemo(
    () =>
      buildDashboard({
        records,
        selection: settings.selection,
        days: settings.days,
        tool: toolFilter,
        provider: providerFilter,
        now,
        sort,
        live,
        active,
      }),
    [records, settings.selection, settings.days, toolFilter, providerFilter, now, sort, live, active],
  );
}
