// Images and framed pages in the transcript, shown as T3 Code shows them:
// pasted images as thumbnails on the prompt, Markdown images inline in a
// reply, `html_render` pages framed above the reply, and one viewer that
// opens any of them full size.
//
// Cost stays flat as a chat grows: images decode lazily off the main thread,
// a page's frame keeps the height T3 measured for it so nothing shifts while
// it loads, frames mount only near the viewport, and every frame shares one
// message listener and one intersection observer.

import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type MouseEvent } from "react";
import type { ChatImage, HtmlArtifact } from "../session";
import { useSessionCwd } from "../context";
import { agentChatText } from "../i18n";
import {
  acquirePageUrl,
  currentViewerMedia,
  markdownImageSrc,
  onFrameMessage,
  openMediaViewer,
  releasePageUrl,
  sidecarUrl,
  subscribeMediaViewer,
  whenNearViewport,
} from "../chatMedia";
import {
  documentHtmlRenderTheme,
  HTML_RENDER_COLUMN_WIDTH,
  HTML_RENDER_SANDBOX,
  htmlRenderFrameHeight,
  htmlRenderOutlineBoxes,
  htmlRenderThemeFragment,
  htmlRenderThemeMessage,
  readHtmlRenderMessage,
  type OutlineBox,
} from "../htmlRender";
import { currentThemeRevision, subscribeThemeChanges } from "../theme";
import { openChatLink } from "../threadLinks";
import { basename, CloseIcon, ExpandIcon } from "./icons";

// MARK: - Images

/** Images sent with a prompt, as thumbnails that open in the viewer. */
export const MessageImages = memo(function MessageImages({ images }: { images: ChatImage[] }) {
  return (
    <div className="msg-images">
      {images.map((image, index) => (
        <MessageImage key={`${index}:${image.url}`} image={image} />
      ))}
    </div>
  );
});

function MessageImage({ image }: { image: ChatImage }) {
  const [failed, setFailed] = useState(false);
  const src = sidecarUrl(image.url);
  if (failed) return <span className="msg-image missing" title={image.name}>{image.name}</span>;
  return (
    <button type="button" className="msg-image" title={image.name} onClick={() => openMediaViewer({ kind: "image", src, name: image.name })}>
      <img src={src} alt={image.name} loading="lazy" decoding="async" draggable={false} onError={() => setFailed(true)} />
    </button>
  );
}

/** An image in a reply. Local paths load through the sidecar. */
export function MarkdownImage({ src, alt, title }: { src?: string; alt?: string; title?: string }) {
  const cwd = useSessionCwd();
  const resolved = useMemo(() => (src ? markdownImageSrc(src, cwd) : ""), [src, cwd]);
  const [failedSrc, setFailedSrc] = useState<string | null>(null);
  const [loadedSrc, setLoadedSrc] = useState<string | null>(null);
  if (!resolved || failedSrc === resolved) {
    return <span className="chat-image-missing" title={src}>{alt || agentChatText("imageUnavailable")}</span>;
  }
  const name = alt || title || (src ? basename(src.split(/[?#]/)[0] ?? src) : "") || "Image";
  const open = (event: MouseEvent<HTMLImageElement>) => {
    // An image inside a link follows the link.
    if (event.currentTarget.closest("a[href]")) return;
    openMediaViewer({ kind: "image", src: resolved, name });
  };
  return (
    <img
      // Holds space until it loads, so a lazy image above what's being read doesn't push it down from nothing.
      className={loadedSrc === resolved ? "chat-image" : "chat-image loading"}
      src={resolved}
      alt={alt ?? ""}
      title={title}
      loading="lazy"
      decoding="async"
      onClick={open}
      onLoad={() => setLoadedSrc(resolved)}
      onError={() => setFailedSrc(resolved)}
    />
  );
}

// MARK: - Framed pages

function useThemeRevision(): number {
  return useSyncExternalStore(subscribeThemeChanges, currentThemeRevision, () => 0);
}

/** Routes a framed page's messages: its height, links it opens, images it shows. */
function useFrameMessages(frame: HTMLIFrameElement | null, onHeight?: (height: number) => void) {
  const heightRef = useRef(onHeight);
  heightRef.current = onHeight;
  useEffect(() => {
    const win = frame?.contentWindow;
    if (!win) return;
    return onFrameMessage(win, (data) => {
      const message = readHtmlRenderMessage(data);
      if (!message) return;
      if (message.kind === "size") heightRef.current?.(message.height);
      else if (message.kind === "link") {
        win.postMessage({ jsonrpc: "2.0", id: message.id, result: {} }, "*");
        openChatLink(message.url, sidecarUrl(""));
      } else openMediaViewer({ kind: "image", src: message.src, name: message.name });
    });
  }, [frame]);
}

/** Keeps a loaded page on the chat's theme as it changes. */
function useFrameTheme(frame: HTMLIFrameElement | null, loaded: boolean) {
  const revision = useThemeRevision();
  useEffect(() => {
    if (loaded) frame?.contentWindow?.postMessage(htmlRenderThemeMessage(documentHtmlRenderTheme()), "*");
  }, [frame, loaded, revision]);
}

/** The page's blob URL with the current theme in its fragment, once `enabled`. */
function usePageSrc(path: string, enabled: boolean): { src: string | null; failed: boolean } {
  const [state, setState] = useState<{ src: string | null; failed: boolean }>({ src: null, failed: false });
  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;
    acquirePageUrl(path).then(
      (url) => { if (!cancelled) setState({ src: url + htmlRenderThemeFragment(documentHtmlRenderTheme()), failed: false }); },
      () => { if (!cancelled) setState({ src: null, failed: true }); },
    );
    return () => {
      cancelled = true;
      releasePageUrl(path);
    };
  }, [enabled, path]);
  return state;
}

/** A page the agent published, framed above its reply at the height T3 measured. */
export const HtmlRenderFrame = memo(function HtmlRenderFrame({ artifact }: { artifact: HtmlArtifact }) {
  const boxRef = useRef<HTMLDivElement>(null);
  const [frame, setFrame] = useState<HTMLIFrameElement | null>(null);
  const [width, setWidth] = useState(HTML_RENDER_COLUMN_WIDTH);
  const [near, setNear] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [contentHeight, setContentHeight] = useState<number>();
  useLayoutEffect(() => {
    const box = boxRef.current;
    if (!box) return;
    setWidth(Math.round(box.clientWidth) || HTML_RENDER_COLUMN_WIDTH);
    const resize = new ResizeObserver(([entry]) => { if (entry) setWidth(Math.round(entry.contentRect.width)); });
    resize.observe(box);
    const stopWatching = whenNearViewport(box, () => setNear(true));
    return () => {
      resize.disconnect();
      stopWatching();
    };
  }, []);
  const { src, failed } = usePageSrc(artifact.url, near);
  useFrameMessages(frame, setContentHeight);
  useFrameTheme(frame, loaded);
  const height = htmlRenderFrameHeight(artifact, width, contentHeight);
  const ready = loaded && src !== null;
  return (
    <div className="html-render" ref={boxRef} style={{ height }}>
      {!ready && !failed ? <HtmlRenderSkeleton title={artifact.title} height={height} outline={htmlRenderOutlineBoxes(artifact, width)} /> : null}
      {src ? (
        <iframe
          ref={setFrame}
          className={"html-render-frame" + (ready ? " ready" : "")}
          src={src}
          title={artifact.title}
          sandbox={HTML_RENDER_SANDBOX}
          referrerPolicy="no-referrer"
          onLoad={() => setLoaded(true)}
        />
      ) : null}
      {failed ? <p className="html-render-failed">{agentChatText("pageUnavailable")}</p> : null}
      {ready ? (
        <button
          type="button"
          className="html-render-expand"
          aria-label={agentChatText("openFullScreen")}
          title={agentChatText("openFullScreen")}
          onClick={() => openMediaViewer({ kind: "page", path: artifact.url, title: artifact.title })}
        >
          <ExpandIcon />
        </button>
      ) : null}
    </div>
  );
});

function outlineBoxStyle(box: OutlineBox) {
  const style: Record<string, string | number> = { left: box.x, top: box.y, width: box.width, height: box.height };
  if (box.kind === "media") return style;
  // Text and tables draw as one bar per line.
  const step = box.height / box.lines;
  const bar = Math.min(box.kind === "table" ? 12 : 10, step * 0.6);
  const start = (step - bar) / 2;
  style.backgroundImage = `repeating-linear-gradient(to bottom, transparent 0 ${start}px, var(--html-render-skeleton) ${start}px ${start + bar}px, transparent ${start + bar}px ${step}px)`;
  return style;
}

const SKELETON_SECTION_HEIGHT = 264;

function HtmlRenderSkeleton({ title, height, outline }: { title: string; height: number; outline: OutlineBox[] }) {
  if (outline.length) {
    return (
      <div className="html-render-skeleton" role="status" aria-label={title}>
        {outline.map((box) => (
          <div key={`${box.kind}:${box.x}:${box.y}:${box.width}:${box.height}`} className={`html-render-skeleton-box ${box.kind}`} style={outlineBoxStyle(box)} />
        ))}
      </div>
    );
  }
  return (
    <div className="html-render-skeleton generic" role="status" aria-label={title}>
      {Array.from({ length: Math.max(1, Math.ceil(height / SKELETON_SECTION_HEIGHT)) }, (_, index) => (
        <div key={index} className="html-render-skeleton-section">
          <span className="bar title" />
          <span className="bar" />
          <span className="card" />
        </div>
      ))}
    </div>
  );
}

// MARK: - Viewer

/** The one full-size viewer for images and pages. Esc or a click outside closes it. */
export function MediaViewer() {
  const media = useSyncExternalStore(subscribeMediaViewer, currentViewerMedia, () => null);
  const closeRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!media) return;
    const previous = document.activeElement as HTMLElement | null;
    closeRef.current?.focus();
    // Capture, so Esc closes the viewer instead of reaching the chat's interrupt.
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopImmediatePropagation();
      openMediaViewer(null);
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => {
      window.removeEventListener("keydown", onKeyDown, true);
      previous?.focus?.();
    };
  }, [media]);
  if (!media) return null;
  const label = media.kind === "image" ? media.name : media.title;
  return (
    <div
      className={`media-viewer ${media.kind}`}
      role="dialog"
      aria-modal="true"
      aria-label={label}
      onClick={(event) => { if (event.target === event.currentTarget) openMediaViewer(null); }}
    >
      <div className="media-viewer-bar">
        <span className="media-viewer-title">{label}</span>
        <button ref={closeRef} type="button" className="media-viewer-close" aria-label={agentChatText("closeViewer")} title={agentChatText("closeViewer")} onClick={() => openMediaViewer(null)}>
          <CloseIcon />
        </button>
      </div>
      {media.kind === "image"
        ? <img className="media-viewer-image" src={media.src} alt={media.name} decoding="async" onClick={() => openMediaViewer(null)} />
        : <ViewerPage path={media.path} title={media.title} />}
    </div>
  );
}

function ViewerPage({ path, title }: { path: string; title: string }) {
  const [frame, setFrame] = useState<HTMLIFrameElement | null>(null);
  const [loaded, setLoaded] = useState(false);
  const { src, failed } = usePageSrc(path, true);
  useFrameMessages(frame);
  useFrameTheme(frame, loaded);
  if (failed) return <p className="html-render-failed">{agentChatText("pageUnavailable")}</p>;
  if (!src) return null;
  return (
    <iframe
      ref={setFrame}
      className="media-viewer-page"
      src={src}
      title={title}
      sandbox={HTML_RENDER_SANDBOX}
      referrerPolicy="no-referrer"
      onLoad={() => setLoaded(true)}
    />
  );
}
