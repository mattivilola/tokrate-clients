import { renderToStaticMarkup } from "react-dom/server";
import { expect, it } from "vitest";
import { CODING_TOOLS, TOOL_BRAND_COLOURS, toolChipStyle } from "../metrics";
import { Segmented, ToolChip, ToolNameChip } from "./primitives";

it("keeps the complete coding-tool palette aligned, including dark inverses", () => {
  expect(TOOL_BRAND_COLOURS).toEqual({
    codex: { background: "#10A37F", text: "#FFFFFF" },
    "claude-code": { background: "#D97757", text: "#FFFFFF" },
    "grok-build": { background: "#000000", text: "#FFFFFF", darkBackground: "#FFFFFF", darkText: "#000000" },
    antigravity: { background: "#4285F4", text: "#FFFFFF" },
    opencode: { background: "#566770", text: "#FFFFFF", darkBackground: "#9DB3BB", darkText: "#0A1A20" },
    "kimi-code": { background: "#6C47FF", text: "#FFFFFF" },
    "t3-code": { background: "#319CFC", text: "#071B2E" },
  });
});

it("renders branded tool chips and coding-tool filters in both selection states", () => {
  const html = renderToStaticMarkup(
    <>
      <ToolChip tool="grok-build" />
      <ToolNameChip tool="opencode" />
      <Segmented
        label="Coding tool"
        className="tool-filter"
        value="t3-code"
        options={[
          { value: "codex", label: CODING_TOOLS.codex.title, toolStyle: toolChipStyle("codex") },
          { value: "t3-code", label: CODING_TOOLS["t3-code"].title, toolStyle: toolChipStyle("t3-code") },
        ]}
        onChange={() => undefined}
      />
    </>,
  );

  expect(html).toContain('class="tool-chip" data-tool="grok-build"');
  expect(html).toContain("--tool-bg:#000000;--tool-fg:#FFFFFF");
  expect(html).toContain('class="chip tool-name-chip" data-tool="opencode"');
  expect(html).toContain("--tool-bg-dark:#9DB3BB;--tool-fg-dark:#0A1A20");
  expect(html).toMatch(/aria-checked="false"[^>]*data-tool="codex"/);
  expect(html).toContain("--tool-bg:#10A37F;--tool-fg:#FFFFFF");
  expect(html).toMatch(/aria-checked="true"[^>]*data-tool="t3-code"/);
  expect(html).toContain("--tool-bg:#319CFC;--tool-fg:#071B2E");
});
