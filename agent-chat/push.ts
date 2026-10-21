// Phone notifications: Web Push to the home-screen app.
//
// The phone's home-screen app (remote.ts) subscribes with the browser's own
// push service, which is Apple's for Safari on an iPhone. The sidecar watches
// the open T3 threads and, when one starts waiting on you or finishes, sends
// the phone a push through that service. The message is encrypted for the
// phone (RFC 8291), so Apple carries it without reading it, and the Mac signs
// each request with its own key (VAPID, RFC 8292). Nothing else is involved:
// no account, no relay, no third-party app.
//
// Keys and subscriptions live in ~/.config/cmux/agent-chat-push.json
// (mode 0600). Subscriptions belong to the phone token they were made under,
// so revoking the token (deleting agent-chat-remote.json) drops them too.

import { createECDH, createHash, createCipheriv, createHmac, createPrivateKey, randomBytes, sign } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { T3ThreadState, T3ThreadSummary } from "./adapters/t3-threads";

type Env = Record<string, string | undefined>;

export function defaultPushFile(env: Env = process.env): string {
  return env.CMUX_AGENT_CHAT_PUSH_FILE || join(env.HOME || homedir(), ".config", "cmux", "agent-chat-push.json");
}

// MARK: - Encryption (RFC 8291, aes128gcm)

function hmac(key: Buffer, data: Buffer): Buffer {
  return createHmac("sha256", key).update(data).digest();
}

/** HKDF with a single output block, all RFC 8291 needs. */
function hkdf(salt: Buffer, ikm: Buffer, info: Buffer, length: number): Buffer {
  return hmac(hmac(salt, ikm), Buffer.concat([info, Buffer.from([1])])).subarray(0, length);
}

const RECORD_SIZE = 4096;

/**
 * The encrypted body for one push. `salt` and `senderPrivateKey` are only
 * passed by tests; a real push uses fresh random ones every time.
 */
export function encryptPushPayload(input: {
  plaintext: Buffer;
  /** The subscription's `p256dh`: the phone's public key, 65 bytes. */
  receiverPublicKey: Buffer;
  /** The subscription's `auth` secret, 16 bytes. */
  authSecret: Buffer;
  salt?: Buffer;
  senderPrivateKey?: Buffer;
}): Buffer {
  const sender = createECDH("prime256v1");
  if (input.senderPrivateKey) sender.setPrivateKey(input.senderPrivateKey);
  else sender.generateKeys();
  const senderPublic = sender.getPublicKey();
  const salt = input.salt ?? randomBytes(16);
  const ecdhSecret = sender.computeSecret(input.receiverPublicKey);
  const keyInfo = Buffer.concat([Buffer.from("WebPush: info\0"), input.receiverPublicKey, senderPublic]);
  const ikm = hkdf(input.authSecret, ecdhSecret, keyInfo, 32);
  const cek = hkdf(salt, ikm, Buffer.from("Content-Encoding: aes128gcm\0"), 16);
  const nonce = hkdf(salt, ikm, Buffer.from("Content-Encoding: nonce\0"), 12);
  const cipher = createCipheriv("aes-128-gcm", cek, nonce);
  // One record; 0x02 marks it as the last.
  const body = Buffer.concat([cipher.update(Buffer.concat([input.plaintext, Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const header = Buffer.alloc(21);
  salt.copy(header, 0);
  header.writeUInt32BE(RECORD_SIZE, 16);
  header.writeUInt8(senderPublic.length, 20);
  return Buffer.concat([header, senderPublic, body]);
}

// MARK: - Signing (VAPID, RFC 8292)

export interface VapidKeys {
  /** Uncompressed P-256 public key, base64url: what the page hands `pushManager.subscribe`. */
  publicKey: string;
  /** The private scalar, base64url. */
  privateKey: string;
}

export function newVapidKeys(): VapidKeys {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  return { publicKey: ecdh.getPublicKey().toString("base64url"), privateKey: ecdh.getPrivateKey().toString("base64url") };
}

/** Where the push service may reach a person running this, as RFC 8292 asks. Apple refuses a push without one. */
const DEFAULT_CONTACT = "https://github.com/manaflow-ai/cmux";

/** The `Authorization` header for a push to `endpoint`, valid for 12 hours. */
export function vapidAuthorization(endpoint: string, keys: VapidKeys, contact = DEFAULT_CONTACT, now = Date.now()): string {
  const publicKey = Buffer.from(keys.publicKey, "base64url");
  const key = createPrivateKey({
    format: "jwk",
    key: {
      kty: "EC",
      crv: "P-256",
      d: keys.privateKey,
      x: publicKey.subarray(1, 33).toString("base64url"),
      y: publicKey.subarray(33, 65).toString("base64url"),
    },
  });
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${part({ typ: "JWT", alg: "ES256" })}.${part({
    aud: new URL(endpoint).origin,
    exp: Math.floor(now / 1000) + 12 * 3600,
    sub: contact,
  })}`;
  const signature = sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `vapid t=${unsigned}.${signature}, k=${keys.publicKey}`;
}

// MARK: - Subscriptions

export interface PushSubscriptionRecord {
  endpoint: string;
  keys: { p256dh: string; auth: string };
  createdAt: string;
}

/** The browsers' push services. A subscription anywhere else is refused, so
 * the sidecar never posts to an address a page made up. */
const PUSH_SERVICE_HOSTS = [".push.apple.com", "fcm.googleapis.com", "android.googleapis.com", ".push.services.mozilla.com", ".notify.windows.com"];

export function isPushEndpoint(endpoint: unknown): endpoint is string {
  if (typeof endpoint !== "string" || endpoint.length > 2048) return false;
  try {
    const url = new URL(endpoint);
    if (url.protocol !== "https:" || url.port || url.username || url.password) return false;
    const host = url.hostname.toLowerCase();
    return PUSH_SERVICE_HOSTS.some((h) => (h.startsWith(".") ? host.endsWith(h) : host === h));
  } catch {
    return false;
  }
}

/** A subscription as `PushSubscription.toJSON()` sends it, checked; null when it isn't one. */
export function parseSubscription(value: any, now = new Date()): PushSubscriptionRecord | null {
  if (!value || typeof value !== "object" || !isPushEndpoint(value.endpoint)) return null;
  const p256dh = typeof value.keys?.p256dh === "string" ? Buffer.from(value.keys.p256dh, "base64url") : null;
  const auth = typeof value.keys?.auth === "string" ? Buffer.from(value.keys.auth, "base64url") : null;
  if (!p256dh || p256dh.length !== 65 || p256dh[0] !== 4 || !auth || auth.length !== 16) return null;
  return { endpoint: value.endpoint, keys: { p256dh: p256dh.toString("base64url"), auth: auth.toString("base64url") }, createdAt: now.toISOString() };
}

/** Enough phones, tablets and reinstalls for one person. */
const MAX_SUBSCRIPTIONS = 20;

function tokenId(token: string): string {
  return createHash("sha256").update(token).digest("base64url").slice(0, 16);
}

/** The Mac's push key and the phones subscribed under the current phone token, saved to disk. */
export class PushStore {
  readonly keys: VapidKeys;
  private subscriptions: PushSubscriptionRecord[];
  private readonly tokenId: string;

  constructor(private readonly path: string, token: string) {
    this.tokenId = tokenId(token);
    let saved: any = null;
    if (existsSync(path)) {
      try {
        saved = JSON.parse(readFileSync(path, "utf8"));
      } catch {
        saved = null;
      }
    }
    const keys = saved?.vapid;
    const valid = typeof keys?.publicKey === "string" && typeof keys?.privateKey === "string"
      && Buffer.from(keys.publicKey, "base64url").length === 65 && Buffer.from(keys.privateKey, "base64url").length === 32;
    this.keys = valid ? { publicKey: keys.publicKey, privateKey: keys.privateKey } : newVapidKeys();
    const sameToken = saved?.tokenId === this.tokenId && Array.isArray(saved?.subscriptions);
    this.subscriptions = sameToken ? saved.subscriptions.filter((s: any) => parseSubscription(s)) : [];
    if (!valid || !sameToken) this.save();
  }

  list(): PushSubscriptionRecord[] {
    return [...this.subscriptions];
  }

  add(subscription: PushSubscriptionRecord): void {
    this.subscriptions = [...this.subscriptions.filter((s) => s.endpoint !== subscription.endpoint), subscription].slice(-MAX_SUBSCRIPTIONS);
    this.save();
  }

  remove(endpoint: string): boolean {
    const before = this.subscriptions.length;
    this.subscriptions = this.subscriptions.filter((s) => s.endpoint !== endpoint);
    if (this.subscriptions.length === before) return false;
    this.save();
    return true;
  }

  private save(): void {
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = `${this.path}.${process.pid}.tmp`;
    const body = { vapid: this.keys, tokenId: this.tokenId, subscriptions: this.subscriptions };
    writeFileSync(tmp, JSON.stringify(body, null, 2) + "\n", { mode: 0o600 });
    renameSync(tmp, this.path);
  }
}

// MARK: - Sending

/** What the service worker (public/sw.js) shows. */
export interface PushMessage {
  title: string;
  body: string;
  /** The thread a tap opens; none opens the home page. */
  threadId?: string;
  /** A newer message with the same tag replaces the older one. */
  tag?: string;
  /** The app icon's badge: threads waiting on you. */
  badge?: number;
}

export type PushResult = "sent" | "gone" | "failed";

/** Sends one message. "gone" means the phone unsubscribed or the app was removed, so drop it. */
export async function sendPush(
  subscription: PushSubscriptionRecord,
  message: PushMessage,
  keys: VapidKeys,
  fetchImpl: typeof fetch = fetch,
): Promise<PushResult> {
  const body = encryptPushPayload({
    plaintext: Buffer.from(JSON.stringify(message)),
    receiverPublicKey: Buffer.from(subscription.keys.p256dh, "base64url"),
    authSecret: Buffer.from(subscription.keys.auth, "base64url"),
  });
  try {
    const res = await fetchImpl(subscription.endpoint, {
      method: "POST",
      headers: {
        authorization: vapidAuthorization(subscription.endpoint, keys),
        "content-encoding": "aes128gcm",
        "content-type": "application/octet-stream",
        ttl: String(24 * 3600),
        urgency: "high",
        ...(message.tag ? { topic: createHash("sha256").update(message.tag).digest("base64url").slice(0, 32) } : {}),
      },
      body: new Uint8Array(body),
      signal: AbortSignal.timeout(10_000),
    });
    if (res.ok) return "sent";
    if (res.status === 404 || res.status === 410) return "gone";
    console.warn(`push to ${new URL(subscription.endpoint).host} refused: ${res.status} ${(await res.text().catch(() => "")).slice(0, 200)}`);
    return "failed";
  } catch (err) {
    console.warn(`push to ${new URL(subscription.endpoint).host} failed: ${String(err)}`);
    return "failed";
  }
}

/** Sends to every subscribed phone, dropping the ones that are gone. */
export async function broadcastPush(store: PushStore, message: PushMessage, fetchImpl: typeof fetch = fetch): Promise<void> {
  await Promise.all(store.list().map(async (subscription) => {
    if ((await sendPush(subscription, message, store.keys, fetchImpl)) === "gone") store.remove(subscription.endpoint);
  }));
}

// MARK: - What's worth a notification

const NOTICE_TEXT = {
  untitled: "Untitled thread",
  needsYou: "Needs you",
  done: "Done",
};

/**
 * The messages for what changed since the last look: a thread that starts
 * waiting on you, and a task's thread that finishes (sub-agents finishing is
 * noise). The first look only records where things stand.
 */
export function threadNotices(previous: Map<string, T3ThreadState> | null, threads: T3ThreadSummary[]): {
  notices: PushMessage[];
  states: Map<string, T3ThreadState>;
} {
  const states = new Map(threads.map((t) => [t.id, t.state]));
  if (!previous) return { notices: [], states };
  const badge = threads.filter((t) => t.state === "needs-input").length;
  const notices: PushMessage[] = [];
  for (const thread of threads) {
    const before = previous.get(thread.id);
    let label: string | null = null;
    if (thread.state === "needs-input" && before !== "needs-input") label = NOTICE_TEXT.needsYou;
    else if (thread.state === "unread" && before === "running" && !thread.rootThreadId) label = NOTICE_TEXT.done;
    if (!label) continue;
    notices.push({
      title: thread.title || NOTICE_TEXT.untitled,
      body: thread.projectName ? `${label} · ${thread.projectName}` : label,
      threadId: thread.id,
      tag: `thread-${thread.id}`,
      badge,
    });
  }
  return { notices, states };
}

/**
 * Re-reads the threads every few seconds while a phone is subscribed and
 * pushes what changed. Returns a stop function.
 */
export function startThreadNotifier(store: PushStore, readThreads: () => T3ThreadSummary[], intervalMs = 5_000): () => void {
  let previous: Map<string, T3ThreadState> | null = null;
  const tick = () => {
    if (!store.list().length) {
      previous = null;
      return;
    }
    let threads: T3ThreadSummary[];
    try {
      threads = readThreads();
    } catch {
      return; // T3 not running or mid-migration; try again next tick.
    }
    const { notices, states } = threadNotices(previous, threads);
    previous = states;
    for (const notice of notices) void broadcastPush(store, notice);
  };
  const timer = setInterval(tick, intervalMs);
  tick();
  return () => clearInterval(timer);
}
