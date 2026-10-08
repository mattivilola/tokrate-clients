// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { createPreviewBridge } from "./store/preview";
import { AppStore } from "./store/store";
import type { Bridge } from "./store/types";

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
