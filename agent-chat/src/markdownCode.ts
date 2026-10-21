// What a fenced code block in a reply is: its language, and the file it shows
// when the agent named one. Agents name files three ways: ```ts:src/a.ts,
// ```src/a.ts, and ```ts title="src/a.ts" (also file= / filename=).

/// Grammars the highlighter can load, by shiki id. Each loads the first time a
/// block uses it, so a chat that only shows TypeScript never fetches the rest.
export const LANGUAGE_LOADERS: Record<string, () => Promise<{ default: unknown }>> = {
  ts: () => import("shiki/langs/ts.mjs"),
  tsx: () => import("shiki/langs/tsx.mjs"),
  js: () => import("shiki/langs/js.mjs"),
  jsx: () => import("shiki/langs/jsx.mjs"),
  json: () => import("shiki/langs/json.mjs"),
  bash: () => import("shiki/langs/bash.mjs"),
  shell: () => import("shiki/langs/shell.mjs"),
  powershell: () => import("shiki/langs/powershell.mjs"),
  python: () => import("shiki/langs/python.mjs"),
  swift: () => import("shiki/langs/swift.mjs"),
  "objective-c": () => import("shiki/langs/objective-c.mjs"),
  rust: () => import("shiki/langs/rust.mjs"),
  go: () => import("shiki/langs/go.mjs"),
  c: () => import("shiki/langs/c.mjs"),
  cpp: () => import("shiki/langs/cpp.mjs"),
  csharp: () => import("shiki/langs/csharp.mjs"),
  java: () => import("shiki/langs/java.mjs"),
  kotlin: () => import("shiki/langs/kotlin.mjs"),
  ruby: () => import("shiki/langs/ruby.mjs"),
  php: () => import("shiki/langs/php.mjs"),
  lua: () => import("shiki/langs/lua.mjs"),
  html: () => import("shiki/langs/html.mjs"),
  css: () => import("shiki/langs/css.mjs"),
  scss: () => import("shiki/langs/scss.mjs"),
  xml: () => import("shiki/langs/xml.mjs"),
  markdown: () => import("shiki/langs/markdown.mjs"),
  yaml: () => import("shiki/langs/yaml.mjs"),
  toml: () => import("shiki/langs/toml.mjs"),
  ini: () => import("shiki/langs/ini.mjs"),
  sql: () => import("shiki/langs/sql.mjs"),
  graphql: () => import("shiki/langs/graphql.mjs"),
  docker: () => import("shiki/langs/docker.mjs"),
  make: () => import("shiki/langs/make.mjs"),
  hcl: () => import("shiki/langs/hcl.mjs"),
  nix: () => import("shiki/langs/nix.mjs"),
  proto: () => import("shiki/langs/proto.mjs"),
  diff: () => import("shiki/langs/diff.mjs"),
  log: () => import("shiki/langs/log.mjs"),
};

/// Names agents write for a language that shiki knows under another id.
/// `csv` and `tsv` aren't highlighted; they render as a table.
const ALIASES: Record<string, string> = {
  typescript: "ts", mts: "ts", cts: "ts",
  javascript: "js", mjs: "js", cjs: "js",
  jsonc: "json", json5: "json",
  sh: "bash", zsh: "bash", console: "shell", shellscript: "shell", ps1: "powershell",
  py: "python", python3: "python",
  objc: "objective-c", m: "objective-c",
  rs: "rust", golang: "go",
  h: "c", hpp: "cpp", cc: "cpp", "c++": "cpp", cs: "csharp",
  kt: "kotlin", kts: "kotlin", rb: "ruby",
  htm: "html", svg: "xml", plist: "xml",
  md: "markdown", mdx: "markdown",
  yml: "yaml", cfg: "ini", conf: "ini", env: "ini", dotenv: "ini",
  gql: "graphql", dockerfile: "docker", makefile: "make", mk: "make",
  tf: "hcl", terraform: "hcl", protobuf: "proto", patch: "diff",
  txt: "text", plaintext: "text", plain: "text", output: "text",
};

const TABLE_LANGUAGES = new Set(["csv", "tsv"]);

/// The language id a fence's info string names, or "text" when none fits.
export function normalizeLanguage(raw: string | null | undefined): string {
  const name = (raw ?? "").trim().toLowerCase();
  if (!name) return "text";
  // Own keys only: a fence named `constructor` or `__proto__` isn't a language.
  const resolved = Object.hasOwn(ALIASES, name) ? ALIASES[name]! : name;
  if (resolved === "text" || TABLE_LANGUAGES.has(resolved) || Object.hasOwn(LANGUAGE_LOADERS, resolved)) return resolved;
  return "text";
}

const FILE_NAMES: Record<string, string> = {
  dockerfile: "docker", makefile: "make", gnumakefile: "make",
  ".env": "ini", ".gitignore": "ini", ".npmrc": "ini", ".editorconfig": "ini",
};

/// The language a file's name implies, or "text".
export function languageForPath(path: string): string {
  const name = path.split("/").pop()?.toLowerCase() ?? "";
  if (Object.hasOwn(FILE_NAMES, name)) return FILE_NAMES[name]!;
  const dot = name.lastIndexOf(".");
  return dot > 0 ? normalizeLanguage(name.slice(dot + 1)) : "text";
}

/// Whether an info string reads as a file path rather than a language name.
function looksLikePath(value: string): boolean {
  if (value.includes("/")) return true;
  const name = value.toLowerCase();
  return Object.hasOwn(FILE_NAMES, name) || /^[\w.-]+\.[A-Za-z0-9]+$/.test(value);
}

function metaPath(meta: string | null | undefined): string | null {
  const match = /(?:^|\s)(?:title|file|filename|path)=(?:"([^"]+)"|'([^']+)'|(\S+))/.exec(meta ?? "");
  return match ? (match[1] ?? match[2] ?? match[3] ?? null) : null;
}

export type CodeFence = { lang: string; path: string | null };

/// Reads a fence's info string (the word after ```) and meta (the rest of the line).
export function codeFence(info: string | null | undefined, meta?: string | null): CodeFence {
  const raw = (info ?? "").trim();
  const fromMeta = metaPath(meta);
  const colon = raw.indexOf(":");
  if (colon > 0 && !/^[a-z]+:\/\//i.test(raw)) {
    const path = raw.slice(colon + 1) || fromMeta;
    const lang = normalizeLanguage(raw.slice(0, colon));
    return { lang: lang === "text" && path ? languageForPath(path) : lang, path: path || null };
  }
  const lang = normalizeLanguage(raw);
  if (lang === "text" && raw && looksLikePath(raw)) return { lang: languageForPath(raw), path: raw };
  return { lang, path: fromMeta };
}

/// How a line of a unified diff reads, for coloring it.
export function diffLineKind(line: string): "add" | "remove" | "hunk" | null {
  if (line.startsWith("@@")) return "hunk";
  if (line.startsWith("+++") || line.startsWith("---")) return null;
  if (line.startsWith("+")) return "add";
  if (line.startsWith("-")) return "remove";
  return null;
}

/// Splits CSV or TSV into rows of fields, honoring double-quoted fields.
export function parseDelimited(text: string, delimiter: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"' && field === "") quoted = true;
    else if (ch === delimiter) { row.push(field); field = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(field); rows.push(row); row = []; field = "";
    } else field += ch;
  }
  if (field !== "" || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((cell) => cell.trim() !== ""));
}

/// Blocks longer than this many lines start collapsed once they finish streaming.
export const COLLAPSE_LINE_THRESHOLD = 40;
/// How many lines a collapsed block shows.
export const COLLAPSED_VISIBLE_LINES = 20;
