import { memo, useEffect, useMemo, useState, type ReactNode } from "react";
import ReactMarkdown, { defaultUrlTransform, type Components } from "react-markdown";
import type { PluggableList } from "unified";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import type { HighlighterCore, LanguageRegistration } from "shiki/core";
import { CopyIcon } from "./components/icons";
import { useRepositorySlug } from "./context";
import { remarkGitHubReferences } from "./githubReferences";
import { chatUrlTransform, chatWorkspaceId, isGitHubLink, threadChatHref, threadLinkId } from "./threadLinks";

const langs = ["ts", "tsx", "js", "json", "bash", "shell", "python", "swift", "rust", "go", "html", "css", "markdown", "yaml", "diff"];
const themeName = "agent-css-variables";
let highlighterPromise: Promise<HighlighterCore> | null = null;
let reportedHighlighterFailure = false;
const htmlCache = new Map<string, { html: string; bytes: number }>();
const HTML_CACHE_MAX_BYTES = 900_000;
let htmlCacheBytes = 0;

function cacheEntryBytes(key: string, html: string) {
  return new TextEncoder().encode(key).byteLength + new TextEncoder().encode(html).byteLength;
}

function cachedHtml(key: string): string | null {
  const hit = htmlCache.get(key);
  if (hit === undefined) return null;
  htmlCache.delete(key);
  htmlCache.set(key, hit);
  return hit.html;
}

function cacheHtml(key: string, html: string) {
  const existing = htmlCache.get(key);
  if (existing) htmlCacheBytes -= existing.bytes;
  const bytes = cacheEntryBytes(key, html);
  htmlCache.set(key, { html, bytes });
  htmlCacheBytes += bytes;
  while (htmlCacheBytes > HTML_CACHE_MAX_BYTES) {
    const oldest = htmlCache.keys().next().value;
    if (oldest === undefined) break;
    htmlCacheBytes -= htmlCache.get(oldest)?.bytes ?? 0;
    htmlCache.delete(oldest);
  }
}

export function htmlCacheSizeForTest(): number {
  return htmlCache.size;
}

export function htmlCacheBytesForTest(): number {
  return htmlCacheBytes;
}

export function clearHtmlCacheForTest() {
  htmlCache.clear();
  htmlCacheBytes = 0;
}

export function cacheHtmlForTest(key: string, html: string) {
  cacheHtml(key, html);
}

function normalizeLang(registration: unknown): LanguageRegistration[] {
  return (Array.isArray(registration) ? registration : [registration]) as LanguageRegistration[];
}

function highlighter() {
  highlighterPromise ??= (async () => {
    const [
      core,
      engine,
      ts,
      tsx,
      js,
      json,
      bash,
      shell,
      python,
      swift,
      rust,
      go,
      html,
      css,
      markdown,
      yaml,
      diff,
    ] = await Promise.all([
      import("shiki/core"),
      import("shiki/engine/javascript"),
      import("shiki/langs/ts.mjs"),
      import("shiki/langs/tsx.mjs"),
      import("shiki/langs/js.mjs"),
      import("shiki/langs/json.mjs"),
      import("shiki/langs/bash.mjs"),
      import("shiki/langs/shell.mjs"),
      import("shiki/langs/python.mjs"),
      import("shiki/langs/swift.mjs"),
      import("shiki/langs/rust.mjs"),
      import("shiki/langs/go.mjs"),
      import("shiki/langs/html.mjs"),
      import("shiki/langs/css.mjs"),
      import("shiki/langs/markdown.mjs"),
      import("shiki/langs/yaml.mjs"),
      import("shiki/langs/diff.mjs"),
    ]);
    const registrations = [ts, tsx, js, json, bash, shell, python, swift, rust, go, html, css, markdown, yaml, diff]
      .flatMap((m) => normalizeLang(m.default));
    return core.createHighlighterCore({
      engine: engine.createJavaScriptRegexEngine(),
      themes: [core.createCssVariablesTheme({ name: themeName })],
      langs: registrations,
    });
  })();
  return highlighterPromise;
}

export async function highlightCode(code: string, lang = "text"): Promise<string> {
  const key = `${lang}\0${code}`;
  const cached = cachedHtml(key);
  if (cached) return cached;
  try {
    const h = await highlighter();
    const html = h.codeToHtml(code, { lang: langs.includes(lang) ? lang : "text", theme: themeName });
    cacheHtml(key, html);
    return html;
  } catch (err) {
    if (!reportedHighlighterFailure) {
      reportedHighlighterFailure = true;
      console.error("[agent-chat] syntax highlighter failed; falling back to plain text", err);
    }
    throw err;
  }
}

function textOf(node: ReactNode): string {
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  if (node && typeof node === "object" && "props" in node) return textOf((node as { props?: { children?: ReactNode } }).props?.children);
  return "";
}

function languageOf(className: unknown): string {
  const match = typeof className === "string" ? /language-([^\s]+)/.exec(className) : null;
  const raw = (match?.[1] ?? "text").toLowerCase();
  if (raw === "sh" || raw === "zsh") return "bash";
  if (raw === "yml") return "yaml";
  if (raw === "typescript") return "ts";
  if (raw === "javascript") return "js";
  return langs.includes(raw) ? raw : "text";
}

export function MarkdownCodeBlock({ code, lang = "text", streaming = false }: { code: string; lang?: string; streaming?: boolean }) {
  const [html, setHtml] = useState<string | null>(() => streaming ? null : cachedHtml(`${lang}\0${code}`));
  useEffect(() => {
    let cancelled = false;
    const key = `${lang}\0${code}`;
    if (streaming) {
      setHtml(null);
      return () => { cancelled = true; };
    }
    const cached = cachedHtml(key);
    if (cached) {
      setHtml(cached);
      return;
    }
    setHtml(null);
    highlightCode(code, lang)
      .then((next) => {
        cacheHtml(key, next);
        if (!cancelled) setHtml(next);
      })
      .catch(() => {
        if (!cancelled) setHtml(null);
      });
    return () => { cancelled = true; };
  }, [code, lang, streaming]);
  const copy = () => navigator.clipboard?.writeText(code).catch(() => {});
  return (
    <div className="markdown-code selectable">
      <div className="code-header">
        <span className="code-lang">{lang}</span>
        <button type="button" className="code-copy" aria-label="Copy code" onClick={copy}><CopyIcon /></button>
      </div>
      {html ? <div dangerouslySetInnerHTML={{ __html: html }} /> : <pre><code>{code}</code></pre>}
    </div>
  );
}

const schema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    code: [...(defaultSchema.attributes?.code ?? []), "className"],
  },
  // T3 agents link threads as t3-thread://v1/<id>; cmux opens them.
  protocols: {
    ...defaultSchema.protocols,
    href: [...(defaultSchema.protocols?.href ?? []), "t3-thread"],
  },
};

const urlTransform = (url: string) => chatUrlTransform(url, defaultUrlTransform);

function chatBase(): string {
  const base = typeof window === "undefined" ? "" : window.__AGENT_CHAT_BASE__ ?? "";
  return base && base !== "/" ? base.replace(/\/$/, "") : "";
}

/// Loads the linked thread's chat; cmux opens it in its own task when it belongs to another.
function followThreadLink(threadId: string) {
  location.assign(threadChatHref(threadId, chatBase(), location.search));
}

/// Opens a GitHub link in a browser beside the chat, in the same cmux task.
/// Returns false when the chat isn't a cmux task, so the link opens as usual.
function openBesideChat(href: string): boolean {
  const workspaceId = typeof location === "undefined" ? null : chatWorkspaceId(location.search);
  if (!workspaceId || !isGitHubLink(href)) return false;
  void fetch(`${chatBase()}/api/open-link`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: href, workspaceId }),
  })
    .then((response) => { if (!response.ok) throw new Error(String(response.status)); })
    .catch(() => { window.open(href, "_blank", "noopener"); });
  return true;
}

function markdownComponents(streaming: boolean): Components {
  return {
  a({ href, children }) {
    const threadId = threadLinkId(href);
    if (threadId) {
      return (
        <a href={href} className="thread-link" title="Open thread" onClick={(event) => { event.preventDefault(); followThreadLink(threadId); }}>
          {children}
        </a>
      );
    }
    const safeHref = defaultUrlTransform(href ?? "");
    return (
      <a
        href={safeHref}
        target="_blank"
        rel="noopener noreferrer"
        onClick={(event) => {
          // A modified click keeps the browser's own behaviour.
          if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
          if (openBesideChat(safeHref)) event.preventDefault();
        }}
      >
        {children}
      </a>
    );
  },
  pre({ children }) {
    const child = Array.isArray(children) ? children[0] : children;
    const props = child && typeof child === "object" && "props" in child ? (child as { props?: { children?: ReactNode; className?: unknown } }).props : undefined;
    const code = textOf(props?.children).replace(/\n$/, "");
    const lang = languageOf(props?.className);
    return <MarkdownCodeBlock code={code} lang={lang} streaming={streaming} />;
  },
  code({ children, className }) {
    if (className) return <code className={className}>{children}</code>;
    return <code>{children}</code>;
  },
  table({ children }) {
    return <div className="markdown-table-wrap"><table>{children}</table></div>;
  },
  };
}

export const ChatMarkdown = memo(function ChatMarkdown({ text, streaming = false }: { text: string; streaming?: boolean }) {
  const components = useMemo(() => markdownComponents(streaming), [streaming]);
  const repositorySlug = useRepositorySlug();
  // Agents write `#847` and `a360a95` far more often than they write a URL, and
  // the terminal already makes both clickable. The reference becomes an
  // ordinary link node in the parsed document, so it gets the same styling and
  // the same click handling as any other link, and the parser is what decides
  // that a `#847` inside a code block is characters rather than a reference.
  //
  // It runs after remark-gfm so bare URLs are already links by then, and before
  // remark-breaks, which rewrites the text nodes this walks.
  const plugins = useMemo<PluggableList>(
    () => [remarkGfm, [remarkGitHubReferences, { repositorySlug, streaming }], remarkBreaks],
    [repositorySlug, streaming],
  );
  return (
    <ReactMarkdown
      remarkPlugins={plugins}
      rehypePlugins={[[rehypeSanitize, schema]]}
      urlTransform={urlTransform}
      components={components}
    >
      {text}
    </ReactMarkdown>
  );
});
