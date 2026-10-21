// Links in a T3 chat that cmux handles itself.
//
// T3 agents link threads as `t3-thread://v1/<thread id>` (T3's
// `formatThreadLink`). In cmux the chat follows such a link by loading that
// thread's chat with `via=link`; cmux sees the navigation and, when the thread
// belongs to another task, opens that task instead. GitHub links open in a
// browser beside the chat in the same cmux task, through the sidecar.

const THREAD_LINK_PREFIX = "t3-thread://v1/";

/// The thread a `t3-thread://v1/<id>` link names, or `null`.
export function threadLinkId(href: string | null | undefined): string | null {
  if (!href?.startsWith(THREAD_LINK_PREFIX)) return null;
  const encoded = href.slice(THREAD_LINK_PREFIX.length).split(/[?#]/)[0] ?? "";
  if (!encoded) return null;
  try {
    const id = decodeURIComponent(encoded);
    return id.trim() ? id : null;
  } catch {
    return null;
  }
}

/// Keeps thread links through react-markdown's URL filter, which drops unknown schemes.
export function chatUrlTransform(url: string, fallback: (url: string) => string): string {
  return threadLinkId(url) ? url : fallback(url);
}

/// The chat page for another thread: `<base>/t3/<id>`, keeping this page's
/// query (transparency, the cmux workspace) and marking it as a followed link.
/// The sidecar redirects to the session page and keeps the query, so cmux reads
/// the thread from `thread`, not from the path.
export function threadChatHref(threadId: string, base: string, search: string): string {
  const params = new URLSearchParams(search);
  params.set("via", "link");
  params.set("thread", threadId);
  return `${base}/t3/${encodeURIComponent(threadId)}?${params.toString()}`;
}

/// Whether a link points at github.com.
export function isGitHubLink(href: string | null | undefined): boolean {
  if (!href) return false;
  try {
    const url = new URL(href);
    return url.protocol === "https:" && (url.hostname === "github.com" || url.hostname === "www.github.com");
  } catch {
    return false;
  }
}

/// The cmux workspace a chat page belongs to, when cmux opened it as a task.
export function chatWorkspaceId(search: string): string | null {
  const id = new URLSearchParams(search).get("workspace");
  return isWorkspaceId(id) ? id : null;
}

/// Whether a value is a cmux workspace id (a UUID). The sidecar checks the same.
export function isWorkspaceId(id: unknown): id is string {
  return typeof id === "string" && /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/.test(id);
}

/// Opens a GitHub link in a browser beside the chat, in the same cmux task.
/// Returns false when the chat isn't a cmux task, so the link opens as usual.
export function openBesideChat(href: string, base: string): boolean {
  const workspaceId = typeof location === "undefined" ? null : chatWorkspaceId(location.search);
  if (!workspaceId || !isGitHubLink(href)) return false;
  void fetch(`${base}/api/open-link`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: href, workspaceId }),
  })
    .then((response) => { if (!response.ok) throw new Error(String(response.status)); })
    .catch(() => { window.open(href, "_blank", "noopener"); });
  return true;
}

/// Opens a link a framed page asked the chat to open, as a click on a link in a reply would.
export function openChatLink(href: string, base: string) {
  if (!openBesideChat(href, base)) window.open(href, "_blank", "noopener");
}
