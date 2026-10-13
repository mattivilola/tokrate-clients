// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { createPreviewBridge } from "./store/preview";
import { AppStore } from "./store/store";
import type { Bridge, CommunityErrorAlert, ProviderErrorGroup, Snapshot } from "./store/types";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;

beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  // React reports a caught render error to the console; the tests expect it.
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  act(() => root.unmount());
  host.remove();
  vi.restoreAllMocks();
});

/** The preview with sharing on, whose community board is replaced by `board`. */
function storeWithBoard(board: unknown): AppStore {
  const preview = createPreviewBridge({ scenario: "sharing", view: "home" });
  const bridge: Bridge = {
    ...preview,
    snapshot: async (since) => ({ ...(await preview.snapshot(since)), board: board as never }),
  };
  return new AppStore(bridge, {});
}

async function show(store: AppStore) {
  await act(async () => {
    root.render(<App store={store} kind="flyout" />);
    await store.refresh();
  });
}

describe("a render error in data views", () => {
  it("shows the unavailable notice in place of the community card and keeps the shell", async () => {
    // A board whose cohort list holds null cannot be drawn.
    const store = storeWithBoard({ cohorts: [null], window: "24h" });
    await show(store);
    expect(host.textContent).toContain("Community data unavailable");
    // The header, the footer and the way to settings are still there.
    expect(host.querySelector("header")).not.toBeNull();
    expect(host.querySelector("footer")).not.toBeNull();
    expect(host.querySelector('[aria-label="Open settings"]')).not.toBeNull();
  });

  it("leaves the sharing switch available in settings", async () => {
    const store = storeWithBoard({ cohorts: [null] });
    await show(store);
    await act(async () => store.openSettings());
    const toggle = host.querySelector('button[role="switch"][aria-label="Share with community"]');
    expect(toggle).not.toBeNull();
    expect(toggle?.getAttribute("aria-checked")).toBe("true");
  });

  it("tries the community card again when a good board arrives", async () => {
    let board: unknown = { cohorts: [null] };
    const preview = createPreviewBridge({ scenario: "sharing", view: "home" });
    const bridge: Bridge = {
      ...preview,
      snapshot: async (since) => ({
        ...(await preview.snapshot(since)),
        board: board as never,
        revision: board === null ? 1 : 2,
      }),
    };
    const store = new AppStore(bridge, {});
    await show(store);
    expect(host.textContent).toContain("Community data unavailable");
    board = (await preview.snapshot(null)).board;
    await act(async () => {
      await store.refresh();
    });
    expect(host.textContent).not.toContain("Community data unavailable");
    expect(host.querySelector('section[aria-label="Community"]')).not.toBeNull();
  });
});

describe("Kimi Code", () => {
  it("is listed as a source in settings", async () => {
    const store = new AppStore(createPreviewBridge({ scenario: "default", view: "home" }), {});
    await show(store);
    await act(async () => store.openSettings());
    const names = [...host.querySelectorAll(".source-name")].map((n) => n.textContent ?? "");
    expect(names.some((name) => name.startsWith("Kimi Code"))).toBe(true);
    expect(host.querySelector('[aria-label="Choose Kimi Code folder"]')).not.toBeNull();
    expect(host.textContent).toContain("M Moonshot AI");
    expect(host.textContent).toContain("KC Kimi Code");
  });

  it("shows the Moonshot AI badge, the tool and the provider route in the picker", async () => {
    const store = new AppStore(createPreviewBridge({ scenario: "default", view: "home" }), {});
    await show(store);
    await act(async () => store.selectCohort("auto:kimi-code"));
    const trigger = host.querySelector<HTMLButtonElement>(".picker-trigger")!;
    expect(trigger.getAttribute("aria-label")).toContain("Auto in Kimi Code · k2d8-preview");
    const badge = trigger.querySelector(".provider-badge");
    expect(badge?.classList.contains("badge-moonshot")).toBe(true);
    expect(badge?.getAttribute("aria-label")).toBe("Moonshot AI");
    expect(badge?.textContent).toContain("M");
    await act(async () => trigger.click());
    const options = [...host.querySelectorAll('[role="option"]')].map((o) => o.textContent ?? "");
    expect(options.some((text) => text.includes("Kimi Code"))).toBe(true);
    const routes = [...host.querySelectorAll<HTMLOptionElement>(".picker-provider option")];
    expect(routes.find((o) => o.value === "moonshot")?.textContent).toBe("Moonshot AI");
  });
});

describe("ErrorBoundary", () => {
  function Throws(): never {
    throw new Error("boom");
  }

  it("keeps its siblings and offers a retry that works once the cause is gone", () => {
    let broken = true;
    function Part() {
      if (broken) return <Throws />;
      return <p>fine</p>;
    }
    act(() =>
      root.render(
        <div>
          <p>sibling</p>
          <ErrorBoundary
            fallback={(retry) => (
              <button type="button" onClick={retry}>
                retry
              </button>
            )}
          >
            <Part />
          </ErrorBoundary>
        </div>,
      ),
    );
    expect(host.textContent).toContain("sibling");
    expect(host.textContent).toContain("retry");
    broken = false;
    act(() => host.querySelector("button")!.click());
    expect(host.textContent).toContain("fine");
  });
});

describe("provider errors line", () => {
  const storeWithErrors = (providerErrors: ProviderErrorGroup[] | undefined) => {
    const preview = createPreviewBridge({ scenario: "sharing", view: "home" });
    const bridge: Bridge = {
      ...preview,
      snapshot: async (since) => ({ ...(await preview.snapshot(since)), providerErrors }),
    };
    return new AppStore(bridge, {});
  };
  const failure = (over: Partial<ProviderErrorGroup>): ProviderErrorGroup => ({
    client: "codex",
    model: "gpt-5.5",
    kind: "overloaded",
    count: 2,
    latestAt: new Date(Date.now() - 5 * 60_000).toISOString(),
    ...over,
  });

  it("shows the passive line on the dashboard", async () => {
    await show(storeWithErrors([failure({}), failure({ model: "gpt-5.4-mini", count: 1 })]));
    const line = host.querySelector(".provider-errors");
    expect(line?.textContent).toContain(
      "You hit “model at capacity” 2 times on gpt-5.5 in the last 24 hours, most recently 5 min ago.",
    );
    expect(line?.textContent).toContain("Also: gpt-5.4-mini (1)");
  });

  it("is hidden without a failure in the last 24 hours", async () => {
    await show(storeWithErrors([]));
    expect(host.querySelector(".provider-errors")).toBeNull();
    act(() => root.unmount());
    root = createRoot(host);
    await show(
      storeWithErrors([failure({ latestAt: new Date(Date.now() - 25 * 3_600_000).toISOString() })]),
    );
    expect(host.querySelector(".provider-errors")).toBeNull();
  });
});

describe("community error alerts", () => {
  /** The preview with `over` laid on every snapshot; `current` can change between polls. */
  function storeWith(current: () => Partial<Snapshot>, scenario: "sharing" | "default" = "sharing") {
    const preview = createPreviewBridge({ scenario, view: "home" });
    const bridge: Bridge = {
      ...preview,
      snapshot: async (since) => ({ ...(await preview.snapshot(since)), ...current() }),
    };
    return { preview, store: new AppStore(bridge, {}) };
  }
  const alertFor = (model: string, over: Partial<CommunityErrorAlert> = {}): CommunityErrorAlert => ({
    model,
    provider: "anthropic",
    clients: ["claude-code"],
    failingContributors: 4,
    overloaded: 6,
    serverError: 0,
    firstFailureAt: new Date(Date.now() - 40 * 60_000).toISOString(),
    lastFailureAt: new Date(Date.now() - 3 * 60_000).toISOString(),
    ...over,
  });
  const failure = (over: Partial<ProviderErrorGroup>): ProviderErrorGroup => ({
    client: "claude-code",
    model: "gpt-5.5",
    kind: "overloaded",
    count: 2,
    latestAt: new Date(Date.now() - 5 * 60_000).toISOString(),
    ...over,
  });
  const notes = () => [...host.querySelectorAll(".provider-errors")].map((n) => n.textContent ?? "");
  /** A model the preview history holds, so alerts about it concern the user. */
  async function usedModel(): Promise<string> {
    const preview = createPreviewBridge({ scenario: "sharing", view: "home" });
    const model = (await preview.snapshot(null)).records.find((r) => r.model)?.model;
    if (!model) throw new Error("preview history has no model");
    return model;
  }

  it("shows the reporting line for a model used in the last 7 days, without a local line", async () => {
    const model = await usedModel();
    const { store } = storeWith(() => ({
      board: { cohorts: [], errors: { alerts: [alertFor(model)] } },
      providerErrors: [],
    }));
    await show(store);
    expect(notes()).toEqual([
      `Tokrate contributors are reporting provider errors on ${model}: 6 overloaded / at capacity from 4 contributors in the last hour, latest 3 min ago.`,
    ]);
    expect(host.textContent).not.toContain("Turn on sharing");
  });

  it("shows it under the local line, and not just you when the user failed in the last hour", async () => {
    const model = await usedModel();
    const { store } = storeWith(() => ({
      board: { cohorts: [], errors: { alerts: [alertFor(model), alertFor("unused-model")] } },
      providerErrors: [failure({ model })],
    }));
    await show(store);
    const lines = notes();
    expect(lines).toHaveLength(2);
    expect(lines[0]).toContain(`times on ${model} in the last 24 hours`);
    expect(lines[1]).toBe(
      `It’s not just you: 3 other contributors hit provider errors on ${model} in the last hour.`,
    );
  });

  it("leaves out alerts about models the user does not use", async () => {
    const { store } = storeWith(() => ({
      board: { cohorts: [], errors: { alerts: [alertFor("unused-model")] } },
      providerErrors: [],
    }));
    await show(store);
    expect(host.querySelector(".provider-errors")).toBeNull();
  });

  it("shows the sharing hint after the local line while sharing is off, and no alert", async () => {
    const model = await usedModel();
    const { store } = storeWith(
      () => ({
        board: { cohorts: [], errors: { alerts: [alertFor(model)] } },
        providerErrors: [failure({ model })],
      }),
      "default",
    );
    await show(store);
    expect(store.getState().snapshot.settings.sharing).toBe(false);
    const lines = notes();
    expect(lines).toHaveLength(2);
    expect(lines[0]).toContain("in the last 24 hours");
    expect(lines[1]).toBe("Turn on sharing to see whether other contributors hit the same errors.");
    expect(host.textContent).not.toContain("Tokrate contributors are reporting");
  });

  it("has no hint without a local line", async () => {
    const { store } = storeWith(() => ({ providerErrors: [] }), "default");
    await show(store);
    expect(host.querySelector(".provider-errors")).toBeNull();
  });

  it("says contributors no longer report errors after the alert clears", async () => {
    const model = await usedModel();
    let alerts: CommunityErrorAlert[] = [alertFor(model)];
    const { store } = storeWith(() => ({
      board: { cohorts: [], errors: { alerts } },
      providerErrors: [],
    }));
    await show(store);
    expect(notes()[0]).toContain("Tokrate contributors are reporting");
    alerts = [];
    await act(async () => {
      // The board changed: a new revision makes the poll take it.
      await store.refresh();
    });
    expect(notes()).toEqual([`${model}: contributors no longer report provider errors (cleared just now).`]);
    expect(host.querySelector(".provider-errors-quiet")).not.toBeNull();
  });
});
