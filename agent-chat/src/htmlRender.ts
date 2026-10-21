// What the chat needs to show a T3 `html_render` page the way T3 does: the
// frame's height before the page loads, the skeleton drawn from the page's
// outline, the theme handed to the page, and the page's messages.
//
// Mirrors T3's packages/shared/src/htmlRender.ts. The page itself carries
// T3's bootstrap script (T3 injects it when the page is published), which
// reads the theme from the URL fragment, follows `host-context-changed`
// messages, and reports its height, link clicks, and image clicks.

import type { HtmlArtifact } from "../types";

/** What a framed page may do. Never `allow-same-origin`: the page runs with an opaque origin. */
export const HTML_RENDER_SANDBOX = "allow-scripts allow-forms allow-popups allow-downloads";

export const HTML_RENDER_MIN_HEIGHT = 80;
export const HTML_RENDER_MAX_HEIGHT = 2000;
/** The column width T3 measures pages and outlines at. */
export const HTML_RENDER_COLUMN_WIDTH = 728;

function clampHeight(height: number): number {
  return Math.min(HTML_RENDER_MAX_HEIGHT, Math.max(HTML_RENDER_MIN_HEIGHT, Math.round(height)));
}

// The taller of the heights measured at the nearest widths on each side. A
// breakpoint between two measured widths can make the page as tall as either.
function measuredHeight(heights: [number, number][], width: number): number {
  const above = heights.findIndex(([measuredWidth]) => measuredWidth >= width);
  const high = above === -1 ? heights.length - 1 : above;
  const low = heights[high]![0] === width ? high : Math.max(0, high - 1);
  return Math.max(heights[low]![1], heights[high]![1]);
}

/** The frame's height at `width`. A page even a few pixels taller than its
 * frame would scroll inside it and take the reader's scroll, so the frame fits
 * the page, up to the height the agent asked for when the page measured taller. */
export function htmlRenderFrameHeight(artifact: Pick<HtmlArtifact, "height" | "heights">, width: number, contentHeight?: number): number {
  const heights = artifact.heights;
  if (!heights?.length) return clampHeight(Math.min(artifact.height, contentHeight ?? artifact.height));
  const cap = measuredHeight(heights, HTML_RENDER_COLUMN_WIDTH) > artifact.height ? artifact.height : HTML_RENDER_MAX_HEIGHT;
  return clampHeight(Math.min(cap, contentHeight ?? measuredHeight(heights, width)));
}

export interface OutlineBox {
  kind: "text" | "media" | "table";
  x: number;
  y: number;
  width: number;
  height: number;
  lines: number;
}

const OUTLINE_KINDS = { t: "text", m: "media", g: "table" } as const;
const OUTLINE_UNIT = 4;

/** The page's outline boxes, scaled from T3's 728px measurement to `width`. */
export function htmlRenderOutlineBoxes(artifact: Pick<HtmlArtifact, "outline" | "heights">, width: number): OutlineBox[] {
  const heights = artifact.heights;
  if (!artifact.outline || !heights?.length) return [];
  const scaleX = width / HTML_RENDER_COLUMN_WIDTH;
  const scaleY = measuredHeight(heights, width) / measuredHeight(heights, HTML_RENDER_COLUMN_WIDTH);
  return artifact.outline.split(";").map((entry) => {
    const [x = 0, y = 0, w = 0, h = 0, lines = 1] = entry.slice(1).split(",").map(Number);
    return {
      kind: OUTLINE_KINDS[entry[0] as keyof typeof OUTLINE_KINDS] ?? "text",
      x: x * OUTLINE_UNIT * scaleX,
      y: y * OUTLINE_UNIT * scaleY,
      width: w * OUTLINE_UNIT * scaleX,
      height: h * OUTLINE_UNIT * scaleY,
      lines,
    };
  });
}

// MARK: - Theme

export interface HtmlRenderTheme {
  appearance: "dark" | "light";
  variables: Record<string, string>;
}

/** T3's theme variable names, each read from the chat's own variable. */
const THEME_SOURCES: [string, string][] = [
  ["--background", "--bg"],
  ["--foreground", "--fg"],
  ["--muted", "--bg-raised"],
  ["--muted-foreground", "--text-dim"],
  ["--card", "--bg-raised"],
  ["--card-foreground", "--fg"],
  ["--popover", "--bg-input"],
  ["--popover-foreground", "--fg"],
  ["--secondary", "--bg-input"],
  ["--secondary-foreground", "--fg"],
  ["--border", "--border"],
  ["--input", "--bg-input"],
  ["--ring", "--accent"],
  ["--primary", "--accent"],
  ["--accent", "--accent"],
  ["--destructive", "--red"],
  ["--destructive-foreground", "--red"],
  ["--warning", "--amber"],
  ["--warning-foreground", "--amber"],
  ["--success", "--green"],
  ["--success-foreground", "--green"],
  ["--info", "--ansi-blue"],
  ["--info-foreground", "--ansi-bright-blue"],
  ["--code-background", "--bg-code"],
  ["--code-foreground", "--fg"],
  ["--chart-1", "--accent"],
  ["--chart-2", "--ansi-cyan"],
  ["--chart-3", "--ansi-yellow"],
  ["--chart-4", "--ansi-magenta"],
  ["--chart-5", "--ansi-red"],
  ["--chart-6", "--ansi-green"],
  ["--font-sans", "--font-sans"],
  ["--font-mono", "--font-mono"],
];

function hexLuminance(hex: string): number | null {
  const m = /^#([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const n = parseInt(m[1]!, 16);
  const channel = (c: number) => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel((n >> 16) & 255) + 0.7152 * channel((n >> 8) & 255) + 0.0722 * channel(n & 255);
}

/** The theme a page gets, built from the chat's resolved terminal colors. */
export function htmlRenderTheme(read: (name: string) => string): HtmlRenderTheme {
  const variables: Record<string, string> = {};
  for (const [name, source] of THEME_SOURCES) {
    const value = read(source).trim();
    if (value) variables[name] = value;
  }
  const bg = read("--bg").trim();
  const accent = read("--accent").trim();
  // The server's light/dark decision; luminance only for a page served without it.
  const scheme = read("--color-scheme").trim();
  const appearance = scheme === "light" || scheme === "dark" ? scheme : (hexLuminance(bg) ?? 0) > 0.4 ? "light" : "dark";
  // Text on a solid accent: black or white, whichever contrasts more (they tie at 0.179).
  const onAccent = (hexLuminance(accent) ?? 0) > 0.179 ? "#000000" : "#ffffff";
  const surface = (color: string) => `color-mix(in srgb, ${color} 14%, ${bg || "transparent"})`;
  Object.assign(variables, {
    "--primary-foreground": onAccent,
    "--accent-foreground": onAccent,
    ...(accent ? { "--accent-surface": surface(accent) } : {}),
    "--accent-surface-foreground": variables["--foreground"] ?? "",
    ...(variables["--destructive"] ? { "--destructive-surface": surface(variables["--destructive"]) } : {}),
    ...(variables["--warning"] ? { "--warning-surface": surface(variables["--warning"]) } : {}),
    "--radius": "0.625rem",
  });
  return { appearance, variables };
}

/** The theme from this document's variables, as the chat currently paints. */
export function documentHtmlRenderTheme(): HtmlRenderTheme {
  const style = getComputedStyle(document.documentElement);
  return htmlRenderTheme((name) => style.getPropertyValue(name));
}

/** The URL fragment the page's bootstrap reads its first theme from, so it paints themed. */
export function htmlRenderThemeFragment(theme: HtmlRenderTheme): string {
  return `#t3-theme=${encodeURIComponent(JSON.stringify(theme))}`;
}

/** Sent to a loaded page when the chat's theme changes. */
export function htmlRenderThemeMessage(theme: HtmlRenderTheme) {
  return {
    jsonrpc: "2.0",
    method: "ui/notifications/host-context-changed",
    params: { theme: theme.appearance, styles: { variables: theme.variables } },
  } as const;
}

// MARK: - Messages from the page

export type HtmlRenderMessage =
  | { kind: "size"; height: number }
  | { kind: "link"; id: string | number; url: string }
  | { kind: "image"; src: string; name: string };

/** A message a framed page sent, if it is one the chat handles. */
export function readHtmlRenderMessage(data: unknown): HtmlRenderMessage | null {
  if (typeof data !== "object" || data === null) return null;
  const { jsonrpc, id, method, params } = data as Record<string, unknown>;
  if (jsonrpc !== "2.0" || typeof params !== "object" || params === null) return null;
  const p = params as Record<string, unknown>;
  if (method === "ui/notifications/size-changed") {
    return typeof p.height === "number" && Number.isFinite(p.height) && p.height > 0 ? { kind: "size", height: p.height } : null;
  }
  if (method === "ui/open-link") {
    if (typeof id !== "string" && typeof id !== "number") return null;
    return typeof p.url === "string" && /^https?:\/\//i.test(p.url) ? { kind: "link", id, url: p.url } : null;
  }
  if (method === "t3/notifications/open-image") {
    if (typeof p.src !== "string" || !/^(?:https?:\/\/|data:image\/)/i.test(p.src)) return null;
    const name = typeof p.name === "string" ? p.name.trim().slice(0, 200) : "";
    return { kind: "image", src: p.src, name: name || "Image" };
  }
  return null;
}
