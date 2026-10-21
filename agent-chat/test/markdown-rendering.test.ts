import { describe, expect, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ChatMarkdown, highlightCode, MarkdownCodeBlock } from "../src/ChatMarkdown";
import { codeFence, parseDelimited } from "../src/markdownCode";

function render(text: string, streaming = false): string {
  return renderToStaticMarkup(React.createElement(ChatMarkdown, { text, streaming }));
}

describe("code fence info", () => {
  test("object property names aren't languages", () => {
    for (const name of ["constructor", "__proto__", "toString", "hasOwnProperty"]) {
      expect(typeof codeFence(name).lang).toBe("string");
    }
    expect(codeFence("constructor").lang).toBe("text");
  });

  test("a language with a path after a colon names the file", () => {
    expect(codeFence("ts:src/projection.ts")).toEqual({ lang: "ts", path: "src/projection.ts" });
  });

  test("a bare file name as the info string infers the language", () => {
    expect(codeFence("src/App.tsx")).toEqual({ lang: "tsx", path: "src/App.tsx" });
    expect(codeFence("scripts/Makefile")).toEqual({ lang: "make", path: "scripts/Makefile" });
  });

  test("a title in the fence meta names the file", () => {
    expect(codeFence("md", 'title="docs/release.md"')).toEqual({ lang: "markdown", path: "docs/release.md" });
    expect(codeFence("python", "file=scripts/run.py")).toEqual({ lang: "python", path: "scripts/run.py" });
  });

  test("common aliases resolve to one language", () => {
    expect(codeFence("py").lang).toBe("python");
    expect(codeFence("sh").lang).toBe("bash");
    expect(codeFence("yml").lang).toBe("yaml");
    expect(codeFence("TypeScript").lang).toBe("ts");
    expect(codeFence("txt").lang).toBe("text");
    expect(codeFence("").lang).toBe("text");
    expect(codeFence("not-a-language").lang).toBe("text");
  });
});

describe("delimited text", () => {
  test("quoted fields keep their commas and escaped quotes", () => {
    expect(parseDelimited('name,note\nparser,"handles ""quotes"", commas"\n', ",")).toEqual([
      ["name", "note"],
      ["parser", 'handles "quotes", commas'],
    ]);
  });
});

describe("rendered replies", () => {
  test("a GitHub alert renders as a titled callout without its marker", () => {
    const html = render("> [!WARNING]\n> Back up the database first.");
    expect(html).toContain("markdown-alert markdown-alert-warning");
    expect(html).toContain('class="markdown-alert-title"');
    expect(html).toContain("Back up the database first.");
    expect(html).not.toContain("[!WARNING]");
  });

  test("an ordinary blockquote stays a plain quote", () => {
    const html = render("> just a quote");
    expect(html).toContain("<blockquote>");
    expect(html).not.toContain("markdown-alert");
  });

  test("task lists keep their task list classes", () => {
    const html = render("- [x] done\n- [ ] open");
    expect(html).toContain('class="contains-task-list"');
    expect(html).toContain('class="task-list-item"');
  });

  test("a fence that names a file shows the path in its header", () => {
    const html = render("```ts:src/projection.ts\nexport const a = 1;\n```");
    expect(html).toContain('class="code-path"');
    expect(html).toContain("src/projection.ts");
    expect(html).toContain('data-line-numbers="true"');
  });

  test("a Markdown file renders as a document with a source toggle", () => {
    const html = render("```markdown\n# Title\n\nSome **bold** text.\n```");
    expect(html).toContain('class="markdown-doc"');
    expect(html).toContain("<h1>Title</h1>");
    expect(html).toContain("<strong>bold</strong>");
    expect(html).toContain('aria-pressed="true"');
  });

  test("a Markdown file still streaming shows its source", () => {
    const html = render("```markdown\n# Title\n```", true);
    expect(html).not.toContain('class="markdown-doc"');
    expect(html).toContain("# Title");
  });

  test("a CSV block renders as a table", () => {
    const html = render("```csv\nfile,lines\nserver.ts,104\n```");
    expect(html).toContain("markdown-table-wrap");
    expect(html).toContain("<th>file</th>");
    expect(html).toContain("<td>server.ts</td>");
  });
});

describe("long code blocks", () => {
  const code = Array.from({ length: 60 }, (_, i) => `line ${i + 1}`).join("\n");

  test("collapse to a preview with a control to show every line", () => {
    const html = renderToStaticMarkup(React.createElement(MarkdownCodeBlock, { code, lang: "text" }));
    expect(html).toContain('data-collapsed="true"');
    expect(html).toContain("60");
  });

  test("stay open while streaming so new lines are visible", () => {
    const html = renderToStaticMarkup(React.createElement(MarkdownCodeBlock, { code, lang: "text", streaming: true }));
    expect(html).not.toContain('data-collapsed="true"');
  });
});

describe("highlighting", () => {
  test("diff lines are marked as added, removed or hunk headers", async () => {
    const html = await highlightCode("@@ -1,2 +1,2 @@\n-old\n+new\n same", "diff");
    expect(html).toContain("diff-hunk");
    expect(html).toContain("diff-remove");
    expect(html).toContain("diff-add");
  });

  test("languages beyond the starter set load on demand", async () => {
    const html = await highlightCode("SELECT id FROM threads;", "sql");
    expect(html).toContain("style=");
    expect(html).toContain("threads");
  });
});
