import { createElement, StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { isTauri } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { App, type WindowKind } from "./App";
import { createPreviewBridge, previewParams } from "./store/preview";
import { AppStore } from "./store/store";
import { tauriBridge } from "./store/tauri-bridge";
import "./style.css";

// Native: the window label picks the surface (main = tray flyout, history = full history).
// Browser preview: synthetic data; dev builds honour ?scenario= and ?view= (see store/preview.ts).
const native = isTauri();
const params = previewParams(window.location.search);
const kind: WindowKind = native
  ? getCurrentWindow().label === "history"
    ? "history"
    : "flyout"
  : params.view === "history"
    ? "history"
    : "flyout";
const store = new AppStore(native ? tauriBridge : createPreviewBridge(params), {
  initialView: !native && params.view === "settings" ? "settings" : "home",
  reportFilters: kind === "flyout",
});
createRoot(document.getElementById("app")!).render(
  createElement(StrictMode, null, createElement(App, { store, kind })),
);
