// Shared plumbing for images and framed pages in the transcript: sidecar
// URLs, the one media viewer, page bytes as blob URLs, and the single
// listeners every frame shares instead of one each.

/** A sidecar path (`/api/...`) under this page's token prefix. */
export function sidecarUrl(path: string): string {
  const base = typeof window === "undefined" ? "" : window.__AGENT_CHAT_BASE__ ?? "";
  return `${base && base !== "/" ? base.replace(/\/$/, "") : ""}${path}`;
}

/** Where a Markdown image loads from: web images as written, local files
 * through the sidecar. Relative paths resolve against the session's
 * directory; without one they can't be found and stay as written. (The
 * sanitizer drops `data:` and `blob:` sources before they get here.) */
export function markdownImageSrc(src: string, cwd: string | null): string {
  const raw = src.trim();
  if (/^(?:https?:)?\/\//i.test(raw)) return raw;
  let path: string | null = null;
  if (/^file:\/\//i.test(raw)) {
    try {
      path = decodeURIComponent(new URL(raw).pathname);
    } catch {
      return raw;
    }
  } else if (raw.startsWith("/") || raw.startsWith("~/")) {
    path = safeDecode(raw);
  } else if (cwd && !/^[a-z][a-z0-9+.-]*:/i.test(raw)) {
    path = `${cwd.replace(/\/+$/, "")}/${safeDecode(raw).replace(/^\.\//, "")}`;
  }
  return path ? sidecarUrl(`/api/local-image?path=${encodeURIComponent(path)}`) : raw;
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

// MARK: - Media viewer

export type ViewerMedia =
  | { kind: "image"; src: string; name: string }
  | { kind: "page"; path: string; title: string };

let viewerMedia: ViewerMedia | null = null;
const viewerListeners = new Set<() => void>();

export function openMediaViewer(media: ViewerMedia | null) {
  viewerMedia = media;
  for (const listener of viewerListeners) listener();
}

export function subscribeMediaViewer(listener: () => void): () => void {
  viewerListeners.add(listener);
  return () => viewerListeners.delete(listener);
}

export function currentViewerMedia(): ViewerMedia | null {
  return viewerMedia;
}

// MARK: - Page bytes

// A page is framed from a blob URL rather than its sidecar URL: a framed page
// can read its own address, and the sidecar's carries the access token. The
// blob is kept briefly after its last frame goes, so scrolling a turn out of
// the virtual list and back doesn't fetch it again.
const PAGE_RELEASE_DELAY_MS = 60_000;
const pages = new Map<string, { url: Promise<string>; refs: number; release?: ReturnType<typeof setTimeout> }>();

export function acquirePageUrl(path: string): Promise<string> {
  let entry = pages.get(path);
  if (!entry) {
    const url = fetch(sidecarUrl(path)).then(async (response) => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      // The blob keeps the sidecar's `text/html` type and stays in the browser, not the JS heap.
      return URL.createObjectURL(await response.blob());
    });
    entry = { url, refs: 0 };
    pages.set(path, entry);
    url.catch(() => { if (pages.get(path) === entry) pages.delete(path); });
  }
  if (entry.release) clearTimeout(entry.release);
  entry.release = undefined;
  entry.refs += 1;
  return entry.url;
}

export function releasePageUrl(path: string) {
  const entry = pages.get(path);
  if (!entry || --entry.refs > 0) return;
  entry.release = setTimeout(() => {
    if (pages.get(path) !== entry || entry.refs > 0) return;
    pages.delete(path);
    void entry.url.then((url) => URL.revokeObjectURL(url), () => {});
  }, PAGE_RELEASE_DELAY_MS);
}

// MARK: - Shared observers

// Every frame's messages arrive on `window`; one listener routes each to the
// frame whose window sent it.
const frameHandlers = new Map<Window, (data: unknown) => void>();
let frameListener: ((event: MessageEvent) => void) | null = null;

export function onFrameMessage(source: Window, handler: (data: unknown) => void): () => void {
  frameHandlers.set(source, handler);
  if (!frameListener) {
    frameListener = (event) => frameHandlers.get(event.source as Window)?.(event.data);
    window.addEventListener("message", frameListener);
  }
  return () => {
    if (frameHandlers.get(source) === handler) frameHandlers.delete(source);
    if (!frameHandlers.size && frameListener) {
      window.removeEventListener("message", frameListener);
      frameListener = null;
    }
  };
}

// Frames mount only once they come near the viewport; one observer per scroll
// container watches them all.
const NEAR_VIEWPORT_MARGIN = "1200px 0px";
// Keyed weakly by scroll container, so a replaced transcript takes its observer with it.
const nearObservers = new WeakMap<Element, IntersectionObserver>();
let viewportObserver: IntersectionObserver | null = null;
const nearCallbacks = new WeakMap<Element, () => void>();

export function whenNearViewport(element: Element, callback: () => void): () => void {
  if (typeof IntersectionObserver === "undefined") {
    callback();
    return () => {};
  }
  const root = element.closest("#messages, .gallery-transcript");
  let observer = root ? nearObservers.get(root) : viewportObserver ?? undefined;
  if (!observer) {
    observer = new IntersectionObserver((entries, self) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        self.unobserve(entry.target);
        nearCallbacks.get(entry.target)?.();
        nearCallbacks.delete(entry.target);
      }
    }, { root, rootMargin: NEAR_VIEWPORT_MARGIN });
    if (root) nearObservers.set(root, observer);
    else viewportObserver = observer;
  }
  nearCallbacks.set(element, callback);
  observer.observe(element);
  return () => {
    observer.unobserve(element);
    nearCallbacks.delete(element);
  };
}
