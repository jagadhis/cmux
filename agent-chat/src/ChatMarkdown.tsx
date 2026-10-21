import { createContext, memo, useContext, useEffect, useMemo, useState, type CSSProperties, type ReactNode } from "react";
import ReactMarkdown, { defaultUrlTransform, type Components } from "react-markdown";
import type { PluggableList } from "unified";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import type { HighlighterCore, LanguageRegistration, ShikiTransformer } from "shiki/core";
import { AlertIcon, Check, CopyIcon, FileIcon } from "./components/icons";
import { MarkdownImage } from "./components/Media";
import { useRepositorySlug } from "./context";
import { remarkGitHubReferences } from "./githubReferences";
import { agentChatText, type AgentChatTextKey } from "./i18n";
import {
  codeFence,
  COLLAPSE_LINE_THRESHOLD,
  COLLAPSED_VISIBLE_LINES,
  diffLineKind,
  LANGUAGE_LOADERS,
  parseDelimited,
} from "./markdownCode";
import { ALERT_KINDS, remarkAlerts, remarkCodeMeta } from "./markdownPlugins";
import { chatUrlTransform, openBesideChat, threadChatHref, threadLinkId } from "./threadLinks";

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
    const [core, engine] = await Promise.all([import("shiki/core"), import("shiki/engine/javascript")]);
    return core.createHighlighterCore({
      engine: engine.createJavaScriptRegexEngine(),
      themes: [core.createCssVariablesTheme({ name: themeName })],
      langs: [],
    });
  })();
  return highlighterPromise;
}

const loadedLanguages = new Map<string, Promise<boolean>>();

/// Loads a grammar the first time a block uses it. Resolves false when the
/// language is unknown or its grammar failed to load, so the block stays plain.
function ensureLanguage(h: HighlighterCore, lang: string): Promise<boolean> {
  const loader = LANGUAGE_LOADERS[lang];
  if (!loader) return Promise.resolve(false);
  let pending = loadedLanguages.get(lang);
  if (!pending) {
    pending = loader()
      .then((module) => h.loadLanguage(...normalizeLang(module.default)))
      .then(() => true, () => {
        loadedLanguages.delete(lang);
        return false;
      });
    loadedLanguages.set(lang, pending);
  }
  return pending;
}

/// Marks each line of a unified diff as added, removed or a hunk header.
function diffLineTransformer(code: string): ShikiTransformer {
  const lines = code.split("\n");
  return {
    line(node, line) {
      const kind = diffLineKind(lines[line - 1] ?? "");
      if (kind) this.addClassToHast(node, `diff-${kind}`);
    },
  };
}

export async function highlightCode(code: string, lang = "text"): Promise<string> {
  const key = `${lang}\0${code}`;
  const cached = cachedHtml(key);
  if (cached) return cached;
  try {
    const h = await highlighter();
    const loaded = lang !== "text" && await ensureLanguage(h, lang);
    const html = h.codeToHtml(code, {
      lang: loaded ? lang : "text",
      theme: themeName,
      transformers: lang === "diff" ? [diffLineTransformer(code)] : [],
    });
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

function fenceInfo(className: unknown): string {
  const match = typeof className === "string" ? /language-([^\s]+)/.exec(className) : null;
  return match?.[1] ?? "";
}

type CodeView = "preview" | "source";

/// Code that reads better rendered: Markdown files as a document, CSV and TSV as a table.
function hasPreview(lang: string): boolean {
  return lang === "markdown" || lang === "csv" || lang === "tsv";
}

function DelimitedTable({ code, delimiter }: { code: string; delimiter: string }) {
  const [head, ...rows] = parseDelimited(code, delimiter);
  if (!head) return null;
  // A column of numbers reads right-aligned, the way a spreadsheet shows it.
  const numeric = head.map((_, i) => rows.length > 0 && rows.every((row) => /^\s*[-+]?[\d,]*\.?\d+%?\s*$/.test(row[i] ?? "")));
  const align = (i: number) => numeric[i] ? "num" : undefined;
  return (
    <div className="markdown-table-wrap">
      <table>
        <thead><tr>{head.map((cell, i) => <th key={i} className={align(i)}>{cell}</th>)}</tr></thead>
        <tbody>{rows.map((row, r) => <tr key={r}>{head.map((_, i) => <td key={i} className={align(i)}>{row[i] ?? ""}</td>)}</tr>)}</tbody>
      </table>
    </div>
  );
}

function HighlightedCode({ code, lang, streaming }: { code: string; lang: string; streaming: boolean }) {
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
  return html ? <div className="code-body" dangerouslySetInnerHTML={{ __html: html }} /> : <div className="code-body"><pre><code>{code}</code></pre></div>;
}

export function MarkdownCodeBlock({
  code,
  lang = "text",
  path = null,
  streaming = false,
  collapsible = true,
}: {
  code: string;
  lang?: string;
  /// The file the block shows, when the agent named one.
  path?: string | null;
  streaming?: boolean;
  /// Whether a long block starts collapsed. File diffs in the changes list stay whole.
  collapsible?: boolean;
}) {
  const [view, setView] = useState<CodeView>("preview");
  const [expanded, setExpanded] = useState(false);
  const [copied, setCopied] = useState(false);
  const previewable = hasPreview(lang) && !streaming;
  const showingPreview = previewable && view === "preview";
  const lineCount = useMemo(() => code.split("\n").length, [code]);
  const collapsed = collapsible && !streaming && !showingPreview && !expanded && lineCount > COLLAPSE_LINE_THRESHOLD;
  const canCollapse = collapsible && !streaming && !showingPreview && lineCount > COLLAPSE_LINE_THRESHOLD;
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1400);
    return () => clearTimeout(timer);
  }, [copied]);
  const copy = () => {
    navigator.clipboard?.writeText(code).then(() => setCopied(true), () => {});
  };
  const style = { "--code-collapsed-lines": COLLAPSED_VISIBLE_LINES } as CSSProperties;
  return (
    <div
      className="markdown-code selectable"
      data-lang={lang}
      data-line-numbers={path && lang !== "diff" ? "true" : undefined}
      data-collapsed={collapsed ? "true" : undefined}
      style={style}
    >
      <div className="code-header">
        {path
          ? <span className="code-path" title={path}><FileIcon /><span className="code-path-text">{path}</span></span>
          : <span className="code-lang">{lang}</span>}
        <span className="code-actions">
          {previewable ? (
            <span className="code-view-toggle" role="group">
              {(["preview", "source"] as const).map((option) => (
                <button
                  key={option}
                  type="button"
                  aria-pressed={view === option}
                  onClick={() => setView(option)}
                >
                  {agentChatText(option === "preview" ? "codePreview" : "codeSource")}
                </button>
              ))}
            </span>
          ) : null}
          <button type="button" className="code-copy" aria-label={agentChatText("copyCode")} onClick={copy}>{copied ? <Check /> : <CopyIcon />}</button>
        </span>
      </div>
      {showingPreview
        ? lang === "markdown"
          ? <div className="markdown-doc"><ChatMarkdown text={code} /></div>
          : <DelimitedTable code={code} delimiter={lang === "tsv" ? "\t" : ","} />
        : <HighlightedCode code={code} lang={lang} streaming={streaming} />}
      {canCollapse ? (
        <button type="button" className="code-expand" aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
          {expanded ? agentChatText("codeShowLess") : agentChatText("codeShowAll").replace("{count}", () => String(lineCount))}
        </button>
      ) : null}
    </div>
  );
}

const schema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    code: [...(defaultSchema.attributes?.code ?? []), "className", "dataMeta"],
    blockquote: [...(defaultSchema.attributes?.blockquote ?? []), ["className", "markdown-alert", ...ALERT_KINDS.map((kind) => `markdown-alert-${kind}`)]],
  },
  // T3 agents link threads as t3-thread://v1/<id>; cmux opens them.
  // Replies embed local images as file:// URLs as well as plain paths.
  protocols: {
    ...defaultSchema.protocols,
    href: [...(defaultSchema.protocols?.href ?? []), "t3-thread"],
    src: [...(defaultSchema.protocols?.src ?? []), "file"],
  },
};

const REHYPE_PLUGINS: PluggableList = [[rehypeSanitize, schema]];

const urlTransform = (url: string, key: string) =>
  key === "src" && /^file:\/\//i.test(url) ? url : chatUrlTransform(url, defaultUrlTransform);

function chatBase(): string {
  const base = typeof window === "undefined" ? "" : window.__AGENT_CHAT_BASE__ ?? "";
  return base && base !== "/" ? base.replace(/\/$/, "") : "";
}

/// Loads the linked thread's chat; cmux opens it in its own task when it belongs to another.
function followThreadLink(threadId: string) {
  location.assign(threadChatHref(threadId, chatBase(), location.search));
}

// Whether the reply is still streaming, for code blocks. A context rather than
// a closure: new component functions would remount the whole reply (and
// reload its images) when streaming ends.
const StreamingContext = createContext(false);

function MarkdownPre({ children }: { children?: ReactNode }) {
  const streaming = useContext(StreamingContext);
  const child = Array.isArray(children) ? children[0] : children;
  const props = child && typeof child === "object" && "props" in child
    ? (child as { props?: { children?: ReactNode; className?: unknown; "data-meta"?: unknown } }).props
    : undefined;
  const code = textOf(props?.children).replace(/\n$/, "");
  const meta = typeof props?.["data-meta"] === "string" ? props["data-meta"] : null;
  const { lang, path } = codeFence(fenceInfo(props?.className), meta);
  return <MarkdownCodeBlock code={code} lang={lang} path={path} streaming={streaming} />;
}

const markdownComponents: Components = {
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
          if (openBesideChat(safeHref, chatBase())) event.preventDefault();
        }}
      >
        {children}
      </a>
    );
  },
  pre({ children }) {
    return <MarkdownPre>{children}</MarkdownPre>;
  },
  code({ children, className }) {
    if (className) return <code className={className}>{children}</code>;
    return <code>{children}</code>;
  },
  blockquote({ className, children }) {
    const kind = typeof className === "string" ? /markdown-alert-(\w+)/.exec(className)?.[1] : undefined;
    if (!kind) return <blockquote>{children}</blockquote>;
    const title = agentChatText(`alert${kind[0].toUpperCase()}${kind.slice(1)}` as AgentChatTextKey);
    return (
      <blockquote className={className}>
        <p className="markdown-alert-title"><AlertIcon kind={kind} />{title}</p>
        {children}
      </blockquote>
    );
  },
  table({ children }) {
    return <div className="markdown-table-wrap"><table>{children}</table></div>;
  },
  img({ src, alt, title }) {
    return <MarkdownImage src={typeof src === "string" ? src : undefined} alt={alt} title={title} />;
  },
};

export const ChatMarkdown = memo(function ChatMarkdown({ text, streaming = false }: { text: string; streaming?: boolean }) {
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
    () => [remarkGfm, remarkAlerts, remarkCodeMeta, [remarkGitHubReferences, { repositorySlug, streaming }], remarkBreaks],
    [repositorySlug, streaming],
  );
  return (
    <div className="markdown">
      <StreamingContext.Provider value={streaming}>
        <ReactMarkdown
          remarkPlugins={plugins}
          rehypePlugins={REHYPE_PLUGINS}
          urlTransform={urlTransform}
          components={markdownComponents}
        >
          {text}
        </ReactMarkdown>
      </StreamingContext.Provider>
    </div>
  );
});
