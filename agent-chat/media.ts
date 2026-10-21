// Images and HTML pages the chat shows inline: T3 Code attachments (pasted
// images, `html_render` pages) and local image files a reply embeds with
// Markdown (`![plot](/tmp/plot.png)`).
//
// Both are served under the sidecar's token prefix. T3 attachments never
// change bytes for an id, so they are cached for good; local files can be
// rewritten, so they revalidate by size and modification time.
//
// Agent-authored HTML must never run with the sidecar's origin: every HTML or
// SVG response carries a CSP `sandbox`, so even a direct navigation to it gets
// an opaque origin and can't call the sidecar's API.

import { realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { extname, isAbsolute, join, normalize } from "node:path";
import { HTML_RENDER_SANDBOX } from "./src/htmlRender";

export const T3_ATTACHMENTS_DIR = join(process.env.T3CODE_HOME || join(homedir(), ".t3"), "userdata", "attachments");

const IMAGE_TYPES: Record<string, string> = {
  ".avif": "image/avif",
  ".bmp": "image/bmp",
  ".gif": "image/gif",
  ".heic": "image/heic",
  ".heif": "image/heif",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".tif": "image/tiff",
  ".tiff": "image/tiff",
  ".webp": "image/webp",
};


/** Local images larger than this aren't served; a reply never needs one. */
const MAX_LOCAL_IMAGE_BYTES = 64 * 1024 * 1024;

// T3's attachment ids: a thread segment, a UUID, and an optional extension suffix.
const T3_ATTACHMENT_ID = /^[a-z0-9_]+(?:-[a-z0-9_]+)*-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?:-([a-z0-9]{1,10}))?$/i;

export function isT3AttachmentId(id: string): boolean {
  return id.length <= 256 && T3_ATTACHMENT_ID.test(id);
}

/** The file a T3 attachment id names, as T3's `resolveAttachmentPathById` finds it. */
export function t3AttachmentPath(id: string, dir = T3_ATTACHMENTS_DIR): string | null {
  const match = isT3AttachmentId(id) ? T3_ATTACHMENT_ID.exec(id) : null;
  if (!match) return null;
  const suffix = match[1]?.toLowerCase();
  const candidates = suffix ? [`.${suffix}`] : [...Object.keys(IMAGE_TYPES), ".bin"];
  for (const extension of candidates) {
    const path = join(dir, `${id}${extension}`);
    if (isFile(path)) return path;
  }
  return null;
}

function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function contentType(path: string): string | null {
  const extension = extname(path).toLowerCase();
  if (extension === ".html" || extension === ".htm") return "text/html; charset=utf-8";
  return IMAGE_TYPES[extension] ?? null;
}

function securityHeaders(type: string): Record<string, string> {
  const headers: Record<string, string> = {
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  };
  if (type.startsWith("text/html")) headers["content-security-policy"] = `sandbox ${HTML_RENDER_SANDBOX}`;
  // An SVG opened on its own is a document that could run script.
  if (type === "image/svg+xml") headers["content-security-policy"] = "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:";
  return headers;
}

/** A T3 attachment: an image or an `html_render` page. Ids never change bytes. */
export function t3AttachmentResponse(id: string, dir = T3_ATTACHMENTS_DIR): Response {
  const path = t3AttachmentPath(id, dir);
  const type = path ? contentType(path) : null;
  if (!path || !type) return new Response("not found", { status: 404 });
  return new Response(Bun.file(path), {
    headers: {
      "content-type": type,
      "cache-control": "private, max-age=31536000, immutable",
      ...securityHeaders(type),
    },
  });
}

/** An image file on this machine, by absolute path. Only image types are served. */
export function localImageResponse(req: Request, rawPath: string | null): Response {
  if (rawPath?.startsWith("~/")) rawPath = join(homedir(), rawPath.slice(2));
  if (!rawPath || !isAbsolute(rawPath) || rawPath.includes("\0")) return new Response("not found", { status: 404 });
  let path: string;
  try {
    // The real file must be an image too, so a `.png` link can't stand in for another file.
    path = realpathSync(normalize(rawPath));
  } catch {
    return new Response("not found", { status: 404 });
  }
  const type = IMAGE_TYPES[extname(path).toLowerCase()];
  if (!type || IMAGE_TYPES[extname(rawPath).toLowerCase()] === undefined) return new Response("not found", { status: 404 });
  let stat;
  try {
    stat = statSync(path);
  } catch {
    return new Response("not found", { status: 404 });
  }
  if (!stat.isFile() || stat.size > MAX_LOCAL_IMAGE_BYTES) return new Response("not found", { status: 404 });
  const etag = `W/"${stat.size.toString(36)}-${Math.floor(stat.mtimeMs).toString(36)}"`;
  const headers = { etag, "cache-control": "private, no-cache", ...securityHeaders(type) };
  if (req.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers });
  return new Response(Bun.file(path), { headers: { "content-type": type, ...headers } });
}
