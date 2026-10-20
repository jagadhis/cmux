import { describe, expect, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ChatMarkdown } from "../src/ChatMarkdown";
import { chatWorkspaceId, isGitHubLink, threadChatHref, threadLinkId } from "../src/threadLinks";
import { openLinkTarget } from "../server";

describe("thread links", () => {
  test("reads the thread id from T3's link format", () => {
    expect(threadLinkId("t3-thread://v1/mcp%3A07488e7c-cd79")).toBe("mcp:07488e7c-cd79");
    expect(threadLinkId("t3-thread://v1/abc?x=1")).toBe("abc");
    expect(threadLinkId("t3-thread://v1/")).toBeNull();
    expect(threadLinkId("t3-thread://v1/%E0%A4")).toBeNull();
    expect(threadLinkId("https://github.com")).toBeNull();
  });

  test("the chat for a linked thread keeps the page's query and marks the link", () => {
    const workspace = "6F2A3B1C-1D2E-4F5A-8B9C-0D1E2F3A4B5C";
    expect(threadChatHref("mcp:abc", "/tok", `?transparent=1&workspace=${workspace}`))
      .toBe(`/tok/t3/mcp%3Aabc?transparent=1&workspace=${workspace}&via=link&thread=mcp%3Aabc`);
  });

  test("a thread link in a message survives sanitizing as a cmux thread link", () => {
    const html = renderToStaticMarkup(React.createElement(ChatMarkdown, { text: "Continued in [Part 2](t3-thread://v1/mcp%3Aabc)." }));
    expect(html).toContain('href="t3-thread://v1/mcp%3Aabc"');
    expect(html).toContain('class="thread-link"');
    // Other schemes are still dropped.
    const unsafe = renderToStaticMarkup(React.createElement(ChatMarkdown, { text: "[x](javascript:alert(1))" }));
    expect(unsafe).not.toContain("javascript:");
  });
});

describe("GitHub links beside the chat", () => {
  test("only github.com links count", () => {
    expect(isGitHubLink("https://github.com/jagadhis/oorva-app/pull/188")).toBe(true);
    expect(isGitHubLink("https://gist.github.com/x")).toBe(false);
    expect(isGitHubLink("https://github.com.evil.example/x")).toBe(false);
    expect(isGitHubLink("not a url")).toBe(false);
    // The sidecar only opens https links, so http ones open as usual.
    expect(isGitHubLink("http://github.com/a/b")).toBe(false);
  });

  test("the workspace comes from the chat URL and must be a UUID", () => {
    expect(chatWorkspaceId("?workspace=6F2A3B1C-1D2E-4F5A-8B9C-0D1E2F3A4B5C")).toBe("6F2A3B1C-1D2E-4F5A-8B9C-0D1E2F3A4B5C");
    expect(chatWorkspaceId("?workspace=../../x")).toBeNull();
    expect(chatWorkspaceId("")).toBeNull();
  });

  test("the sidecar opens only https github.com URLs in a named workspace", () => {
    const workspace = "6F2A3B1C-1D2E-4F5A-8B9C-0D1E2F3A4B5C";
    expect(openLinkTarget("https://github.com/a/b/pull/1", workspace)).toEqual({ url: "https://github.com/a/b/pull/1", workspaceId: workspace });
    expect(openLinkTarget("http://github.com/a/b", workspace)).toBeNull();
    expect(openLinkTarget("file:///etc/passwd", workspace)).toBeNull();
    expect(openLinkTarget("https://example.com", workspace)).toBeNull();
    expect(openLinkTarget("https://github.com/a/b", "not-a-uuid")).toBeNull();
    expect(openLinkTarget(42, workspace)).toBeNull();
  });
});
