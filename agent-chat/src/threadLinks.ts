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
  return id && /^[0-9A-Fa-f-]{36}$/.test(id) ? id : null;
}
