import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { htmlRenderArtifact, messageImages, T3Timeline, type T3Projection } from "../adapters/t3-timeline";
import { localImageResponse, t3AttachmentPath, t3AttachmentResponse } from "../media";
import { markdownImageSrc } from "../src/chatMedia";
import { ChatMarkdown } from "../src/ChatMarkdown";
import { SessionCwdContext } from "../src/context";
import {
  htmlRenderFrameHeight,
  htmlRenderOutlineBoxes,
  htmlRenderTheme,
  readHtmlRenderMessage,
} from "../src/htmlRender";
import { foldEvent, type Block } from "../src/session";
import { groupTurns } from "../src/turns";

const PAGE_ID = "thread-abc-dd14cbd1-2cde-4fef-83ba-5005e29b5f1e-html";
const IMAGE_ID = "f48dc2d0-b668-41e2-9ff4-f6b57471f10f-bcdba4a5-2e92-4118-af01-33983f15dcec";

/** An `html_render` result as T3 records it on the tool item. */
function htmlRenderOutput(ref: Record<string, unknown>) {
  const content = { htmlRender: ref, message: "Shown to the reader above your reply." };
  return { content: JSON.stringify(content), structuredContent: content };
}

function projection(overrides: Partial<T3Projection> = {}): T3Projection {
  return {
    thread: { id: "th", title: "Pages" },
    runs: [{ id: "r1", ordinal: 1, status: "running", userMessageId: "m1" }],
    messages: [{ id: "m1", role: "user", text: "Show me" }],
    turnItems: [],
    runtimeRequests: [],
    ...overrides,
  };
}

describe("T3 images and pages", () => {
  test("a prompt's pasted images come with the user message, even without text", () => {
    const step = new T3Timeline().step(projection({
      messages: [{
        id: "m1",
        role: "user",
        text: "",
        attachments: [
          { type: "image", id: IMAGE_ID, name: "Screenshot.png", mimeType: "image/png" },
          { type: "file", id: "x-11111111-1111-1111-1111-111111111111-pdf", name: "spec.pdf" },
        ],
      }],
    }));
    expect(step.events).toEqual([{ kind: "user", text: "", images: [{ url: `/api/t3/attachments/${IMAGE_ID}`, name: "Screenshot.png" }] }]);
  });

  test("a completed html_render call publishes its page once, after the tool ends", () => {
    const timeline = new T3Timeline();
    const running = { id: "t1", runId: "r1", ordinal: 1, status: "running", type: "dynamic_tool", toolName: "mcp__t3-code__html_render", input: { title: "Plan" } };
    expect(timeline.step(projection({ turnItems: [running] })).events.map((e) => e.kind)).toEqual(["user", "tool-start"]);
    const done = {
      ...running,
      status: "completed",
      output: htmlRenderOutput({ attachmentId: PAGE_ID, title: "Plan", height: 750, heights: [[728, 717], [320, 2653]] }),
    };
    const step = timeline.step(projection({ turnItems: [done] }));
    expect(step.events).toEqual([
      { kind: "tool-end", toolId: "t1", ok: true },
      {
        kind: "html-render",
        artifact: { id: PAGE_ID, url: `/api/t3/attachments/${PAGE_ID}`, title: "Plan", height: 750, heights: [[320, 2000], [728, 717]] },
      },
    ]);
    expect(timeline.step(projection({ turnItems: [done] })).events).toEqual([]);
  });

  test("a page whose output lands after the tool completed still shows, even once the run finished", () => {
    const timeline = new T3Timeline();
    const finished = [{ id: "r1", ordinal: 1, status: "completed", userMessageId: "m1" }];
    const early = { id: "t1", runId: "r1", ordinal: 1, status: "completed", type: "dynamic_tool", toolName: "mcp__t3-code__html_render", input: { title: "Plan" } };
    expect(timeline.step(projection({ runs: finished, turnItems: [early] })).events.map((e) => e.kind)).toEqual(["user", "tool-start", "tool-end", "done"]);
    const late = { ...early, output: htmlRenderOutput({ attachmentId: PAGE_ID, title: "Plan", height: 400 }) };
    expect(timeline.step(projection({ runs: finished, turnItems: [late] })).events.map((e) => e.kind)).toEqual(["html-render"]);
    expect(timeline.step(projection({ runs: finished, turnItems: [late] })).events).toEqual([]);
  });

  test("pages are read from the result text when there is no structured content", () => {
    const output = { content: JSON.stringify({ htmlRender: { attachmentId: PAGE_ID, title: "  ", height: 10 } }) };
    expect(htmlRenderArtifact({ id: "t", type: "dynamic_tool", toolName: "html_render", output })).toEqual({
      id: PAGE_ID, url: `/api/t3/attachments/${PAGE_ID}`, title: "HTML", height: 80,
    });
  });

  test("pages are read from T3's compacted output too, as its projection sends it", () => {
    const output = { htmlRender: { attachmentId: PAGE_ID, title: "Plan", height: 400 } };
    expect(htmlRenderArtifact({ id: "t", type: "dynamic_tool", toolName: "mcp__t3-code__html_render", output })?.id).toBe(PAGE_ID);
    expect(htmlRenderArtifact({ id: "t", type: "dynamic_tool", toolName: "html_render", output: { ...output, isError: true } })).toBeNull();
  });

  test("failed calls, other tools, and unsafe ids publish nothing", () => {
    const output = htmlRenderOutput({ attachmentId: PAGE_ID, title: "Plan", height: 400 });
    expect(htmlRenderArtifact({ id: "t", type: "dynamic_tool", toolName: "mcp__t3-code__html_render", output: { ...output, isError: true } })).toBeNull();
    expect(htmlRenderArtifact({ id: "t", type: "dynamic_tool", toolName: "mcp__other__render", output })).toBeNull();
    expect(htmlRenderArtifact({ id: "t", type: "dynamic_tool", toolName: "html_render", output: htmlRenderOutput({ attachmentId: "../../etc/passwd", title: "x", height: 400 }) })).toBeNull();
    expect(messageImages([{ type: "image", id: "../secret" }])).toEqual([]);
  });

  test("a page sits above the reply instead of folding into the turn's activity", () => {
    const events = [
      { kind: "user", text: "Show me" },
      { kind: "tool-start", toolId: "t1", name: "html_render" },
      { kind: "tool-end", toolId: "t1", ok: true },
      { kind: "html-render", artifact: { id: PAGE_ID, url: "/p", title: "Plan", height: 400 } },
      { kind: "delta", text: "Here it is." },
      { kind: "done" },
    ] as const;
    const blocks = events.reduce<Block[]>((acc, evt) => foldEvent(acc, evt), []);
    const [group] = groupTurns(blocks, "idle");
    expect(group?.activity.map((b) => b.kind)).toEqual(["tool"]);
    expect(group?.artifacts?.map((b) => b.artifact.title)).toEqual(["Plan"]);
    expect(group?.assistant?.text).toBe("Here it is.");
  });
});

describe("frame sizing", () => {
  const artifact = { height: 750, heights: [[320, 2653], [728, 717], [1144, 690]] as [number, number][] };

  test("the frame takes the measured height nearest its width, before the page loads", () => {
    expect(htmlRenderFrameHeight(artifact, 728)).toBe(717);
    // Between two measured widths, the taller of the two.
    expect(htmlRenderFrameHeight(artifact, 900)).toBe(717);
    // Narrow columns grow up to the cap, since the page measured shorter than asked at 728px.
    expect(htmlRenderFrameHeight(artifact, 320)).toBe(2000);
  });

  test("the page's reported height wins once it loads, within the cap", () => {
    expect(htmlRenderFrameHeight(artifact, 728, 731)).toBe(731);
    expect(htmlRenderFrameHeight({ height: 400 }, 728, 9000)).toBe(400);
    expect(htmlRenderFrameHeight({ height: 400, heights: [[728, 900]] }, 728, 9000)).toBe(400);
  });

  test("outline boxes scale from the 728px measurement", () => {
    const boxes = htmlRenderOutlineBoxes({ outline: "t0,0,100,4,2;m10,10,20,20,1", heights: [[364, 200], [728, 100]] }, 364);
    expect(boxes).toEqual([
      { kind: "text", x: 0, y: 0, width: 200, height: 32, lines: 2 },
      { kind: "media", x: 20, y: 80, width: 40, height: 160, lines: 1 },
    ]);
  });
});

describe("page messages and theme", () => {
  test("only the page messages the chat handles are read", () => {
    expect(readHtmlRenderMessage({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { height: 512 } })).toEqual({ kind: "size", height: 512 });
    expect(readHtmlRenderMessage({ jsonrpc: "2.0", id: 1, method: "ui/open-link", params: { url: "https://example.com" } })).toEqual({ kind: "link", id: 1, url: "https://example.com" });
    expect(readHtmlRenderMessage({ jsonrpc: "2.0", id: 1, method: "ui/open-link", params: { url: "javascript:alert(1)" } })).toBeNull();
    expect(readHtmlRenderMessage({ jsonrpc: "2.0", method: "t3/notifications/open-image", params: { src: "data:image/png;base64,AA", name: "" } })).toEqual({ kind: "image", src: "data:image/png;base64,AA", name: "Image" });
    expect(readHtmlRenderMessage({ jsonrpc: "2.0", method: "t3/notifications/open-image", params: { src: "file:///etc/passwd" } })).toBeNull();
    expect(readHtmlRenderMessage("hello")).toBeNull();
  });

  test("the page's theme follows the terminal colors", () => {
    const vars: Record<string, string> = { "--bg": "#101014", "--fg": "#e8e8ec", "--accent": "#7aa2f7", "--border": "color-mix(in srgb, #e8e8ec 15%, #101014)" };
    const theme = htmlRenderTheme((name) => vars[name] ?? "");
    expect(theme.appearance).toBe("dark");
    expect(theme.variables["--background"]).toBe("#101014");
    expect(theme.variables["--border"]).toBe(vars["--border"]);
    expect(theme.variables["--primary"]).toBe("#7aa2f7");
    expect(theme.variables["--primary-foreground"]).toBe("#000000");
    expect(htmlRenderTheme((name) => (name === "--bg" ? "#fafafa" : "")).appearance).toBe("light");
  });
});

describe("Markdown images", () => {
  test("local paths load through the sidecar; web images load as written", () => {
    expect(markdownImageSrc("https://example.com/a.png", "/repo")).toBe("https://example.com/a.png");
    expect(markdownImageSrc("/tmp/plot.png", null)).toBe(`/api/local-image?path=${encodeURIComponent("/tmp/plot.png")}`);
    expect(markdownImageSrc("file:///tmp/my%20plot.png", null)).toBe(`/api/local-image?path=${encodeURIComponent("/tmp/my plot.png")}`);
    expect(markdownImageSrc("./docs/shot.png", "/repo/")).toBe(`/api/local-image?path=${encodeURIComponent("/repo/docs/shot.png")}`);
    expect(markdownImageSrc("docs/shot.png", null)).toBe("docs/shot.png");
  });

  test("a reply's image renders as a lazy image, file URLs included", () => {
    const html = renderToStaticMarkup(
      React.createElement(SessionCwdContext.Provider, { value: "/repo" },
        React.createElement(ChatMarkdown, { text: "![plot](file:///tmp/plot.png) and ![shot](shot.png)" })),
    );
    expect(html).toContain(`src="/api/local-image?path=${encodeURIComponent("/tmp/plot.png")}"`);
    expect(html).toContain(`src="/api/local-image?path=${encodeURIComponent("/repo/shot.png")}"`);
    expect(html).toContain('loading="lazy"');
  });
});

describe("media routes", () => {
  const dir = mkdtempSync(join(tmpdir(), "chat-media-"));
  afterAll(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(join(dir, `${PAGE_ID}.html`), "<!doctype html><p>hi</p>");
  writeFileSync(join(dir, `${IMAGE_ID}.png`), "png");
  writeFileSync(join(dir, "notes.txt"), "secret");
  symlinkSync(join(dir, "notes.txt"), join(dir, "sneaky.png"));

  test("attachments resolve by id, with or without an extension suffix", () => {
    expect(t3AttachmentPath(PAGE_ID, dir)).toBe(join(dir, `${PAGE_ID}.html`));
    expect(t3AttachmentPath(IMAGE_ID, dir)).toBe(join(dir, `${IMAGE_ID}.png`));
    expect(t3AttachmentPath("notes", dir)).toBeNull();
    expect(t3AttachmentPath("../notes", dir)).toBeNull();
  });

  test("a page is cached for good and sandboxed even when opened directly", async () => {
    const response = t3AttachmentResponse(PAGE_ID, dir);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(response.headers.get("cache-control")).toContain("immutable");
    expect(response.headers.get("content-security-policy")).toStartWith("sandbox ");
    expect(response.headers.get("content-security-policy")).not.toContain("allow-same-origin");
    expect(await response.text()).toContain("<p>hi</p>");
  });

  test("local images are served by path and revalidate; other files are not", () => {
    const path = join(dir, `${IMAGE_ID}.png`);
    const first = localImageResponse(new Request("http://x/"), path);
    expect(first.status).toBe(200);
    expect(first.headers.get("content-type")).toBe("image/png");
    const etag = first.headers.get("etag")!;
    expect(localImageResponse(new Request("http://x/", { headers: { "if-none-match": etag } }), path).status).toBe(304);
    expect(localImageResponse(new Request("http://x/"), join(dir, "notes.txt")).status).toBe(404);
    expect(localImageResponse(new Request("http://x/"), join(dir, "sneaky.png")).status).toBe(404);
    expect(localImageResponse(new Request("http://x/"), "relative.png").status).toBe(404);
  });
});
