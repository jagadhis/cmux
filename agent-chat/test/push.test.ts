import { describe, expect, test } from "bun:test";
import { createECDH, createPublicKey, verify } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { handleRemoteFetchForTest } from "../server";
import {
  broadcastPush,
  encryptPushPayload,
  isPushEndpoint,
  parseSubscription,
  PushStore,
  sendPush,
  threadNotices,
  vapidAuthorization,
} from "../push";
import { notificationStatus } from "../src/phoneNotifications";
import type { T3ThreadSummary } from "../adapters/t3-threads";

const b64 = (s: string) => Buffer.from(s.replace(/\s+/g, ""), "base64url");
const TOKEN = "a".repeat(43);
const HOST = "my-mac.tail1234.ts.net";
const ENDPOINT = "https://web.push.apple.com/QGhLZ5Y-abc";

function withStore<T>(fn: (store: PushStore, file: string) => T | Promise<T>, token = TOKEN): Promise<T> {
  const dir = mkdtempSync(join(tmpdir(), "agent-chat-push-"));
  const file = join(dir, "nested", "agent-chat-push.json");
  return Promise.resolve(fn(new PushStore(file, token), file)).finally(() => rmSync(dir, { recursive: true, force: true }));
}

function phoneKeys() {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  return { p256dh: ecdh.getPublicKey().toString("base64url"), auth: Buffer.alloc(16, 7).toString("base64url") };
}

describe("push encryption", () => {
  test("matches RFC 8291's worked example", () => {
    const body = encryptPushPayload({
      plaintext: b64("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"),
      receiverPublicKey: b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV- JvLexhqUzORcx aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"),
      authSecret: b64("BTBZMqHH6r4Tts7J_aSIgg"),
      salt: b64("DGv6ra1nlYgDCS1FRnbzlw"),
      senderPrivateKey: b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"),
    });
    const header = b64("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z 9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml mlMoZIIgDll6e3vCYLocInmYWAmS6Tlz AC8wEqKK6PBru3jl7A8");
    const ciphertext = b64("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrd irN6GcG7sFz1y1sqLgVi1VhjVkHsUoEs bI_0LpXMuGvnzQ");
    expect(body.toString("base64url")).toBe(Buffer.concat([header, ciphertext]).toString("base64url"));
  });

  test("a real push uses a fresh key and salt each time", () => {
    const keys = phoneKeys();
    const input = { plaintext: Buffer.from("hi"), receiverPublicKey: b64(keys.p256dh), authSecret: b64(keys.auth) };
    expect(encryptPushPayload(input).equals(encryptPushPayload(input))).toBe(false);
  });
});

describe("VAPID", () => {
  test("a signed token for the push service's origin, with a contact", () => withStore((store) => {
    const now = Date.parse("2026-10-21T12:00:00Z");
    const header = vapidAuthorization(ENDPOINT, store.keys, "https://example.com", now);
    const match = header.match(/^vapid t=([^.]+)\.([^.]+)\.([^,]+), k=(.+)$/);
    expect(match).not.toBeNull();
    const [, head, claims, signature, k] = match!;
    expect(k).toBe(store.keys.publicKey);
    expect(JSON.parse(b64(head).toString())).toEqual({ typ: "JWT", alg: "ES256" });
    expect(JSON.parse(b64(claims).toString())).toEqual({ aud: "https://web.push.apple.com", exp: now / 1000 + 12 * 3600, sub: "https://example.com" });
    const pub = b64(store.keys.publicKey);
    const key = createPublicKey({ format: "jwk", key: { kty: "EC", crv: "P-256", x: pub.subarray(1, 33).toString("base64url"), y: pub.subarray(33).toString("base64url") } });
    expect(verify("sha256", Buffer.from(`${head}.${claims}`), { key, dsaEncoding: "ieee-p1363" }, b64(signature))).toBe(true);
  }));
});

describe("subscriptions", () => {
  test("only the browsers' push services", () => {
    expect(isPushEndpoint(ENDPOINT)).toBe(true);
    expect(isPushEndpoint("https://fcm.googleapis.com/fcm/send/x")).toBe(true);
    expect(isPushEndpoint("http://web.push.apple.com/x")).toBe(false);
    expect(isPushEndpoint("https://web.push.apple.com.evil.example.com/x")).toBe(false);
    expect(isPushEndpoint("https://web.push.apple.com:8443/x")).toBe(false);
    expect(isPushEndpoint("https://127.0.0.1/x")).toBe(false);
    expect(isPushEndpoint(42)).toBe(false);
  });

  test("keys must be a P-256 point and a 16-byte secret", () => {
    const keys = phoneKeys();
    expect(parseSubscription({ endpoint: ENDPOINT, keys })?.keys).toEqual(keys);
    expect(parseSubscription({ endpoint: ENDPOINT, keys: { ...keys, auth: "short" } })).toBeNull();
    expect(parseSubscription({ endpoint: ENDPOINT, keys: { ...keys, p256dh: Buffer.alloc(65).toString("base64url") } })).toBeNull();
    expect(parseSubscription({ endpoint: "https://evil.example.com/x", keys })).toBeNull();
  });

  test("saved privately, kept across restarts, dropped with the phone token", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-chat-push-"));
    try {
      const file = join(dir, "agent-chat-push.json");
      const first = new PushStore(file, TOKEN);
      first.add(parseSubscription({ endpoint: ENDPOINT, keys: phoneKeys() })!);
      expect(statSync(file).mode & 0o777).toBe(0o600);
      const again = new PushStore(file, TOKEN);
      expect(again.keys).toEqual(first.keys);
      expect(again.list().map((s) => s.endpoint)).toEqual([ENDPOINT]);
      const revoked = new PushStore(file, "b".repeat(43));
      expect(revoked.keys).toEqual(first.keys);
      expect(revoked.list()).toEqual([]);
      expect(JSON.parse(readFileSync(file, "utf8")).subscriptions).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("subscribing again replaces, not duplicates", () => withStore((store) => {
    store.add(parseSubscription({ endpoint: ENDPOINT, keys: phoneKeys() })!);
    store.add(parseSubscription({ endpoint: ENDPOINT, keys: phoneKeys() })!);
    expect(store.list()).toHaveLength(1);
    expect(store.remove(ENDPOINT)).toBe(true);
    expect(store.remove(ENDPOINT)).toBe(false);
  }));
});

describe("sending", () => {
  test("an encrypted, signed POST to the endpoint; a gone phone is dropped", () => withStore(async (store) => {
    store.add(parseSubscription({ endpoint: ENDPOINT, keys: phoneKeys() })!);
    store.add(parseSubscription({ endpoint: "https://web.push.apple.com/other", keys: phoneKeys() })!);
    const calls: { url: string; init: RequestInit }[] = [];
    const fakeFetch = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response(null, { status: url === ENDPOINT ? 410 : 201 });
    }) as unknown as typeof fetch;
    await broadcastPush(store, { title: "Fix tests", body: "Needs you · cmux", threadId: "t1", tag: "thread-t1" }, fakeFetch);
    expect(calls.map((c) => c.url).sort()).toEqual([ENDPOINT, "https://web.push.apple.com/other"].sort());
    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers["content-encoding"]).toBe("aes128gcm");
    expect(headers.authorization).toStartWith("vapid t=");
    expect(headers.urgency).toBe("high");
    expect(headers.topic).toMatch(/^[A-Za-z0-9_-]{1,32}$/);
    // The body is ciphertext, so the push service never sees the thread's title.
    expect(Buffer.from(calls[0].init.body as Uint8Array).includes(Buffer.from("Fix tests"))).toBe(false);
    expect(store.list().map((s) => s.endpoint)).toEqual(["https://web.push.apple.com/other"]);
  }));

  test("a refused push is reported, not thrown", () => withStore(async (store) => {
    const subscription = parseSubscription({ endpoint: ENDPOINT, keys: phoneKeys() })!;
    const refused = (async () => new Response("BadJwtToken", { status: 403 })) as unknown as typeof fetch;
    const offline = (async () => { throw new Error("offline"); }) as unknown as typeof fetch;
    expect(await sendPush(subscription, { title: "x", body: "" }, store.keys, refused)).toBe("failed");
    expect(await sendPush(subscription, { title: "x", body: "" }, store.keys, offline)).toBe("failed");
  }));
});

describe("what's worth a notification", () => {
  const thread = (id: string, state: T3ThreadSummary["state"], extra: Partial<T3ThreadSummary> = {}): T3ThreadSummary => ({
    id, title: id, projectId: "p1", projectName: "cmux", rootThreadId: null, state, branch: null, updatedAt: "", ...extra,
  } as T3ThreadSummary);

  test("the first look only records", () => {
    const { notices, states } = threadNotices(null, [thread("a", "needs-input")]);
    expect(notices).toEqual([]);
    expect(states.get("a")).toBe("needs-input");
  });

  test("a thread that starts waiting on you, or a task that finishes", () => {
    const previous = new Map([["asks", "running"], ["done", "running"], ["still", "needs-input"], ["sub", "running"], ["seen", "running"]] as const);
    const { notices } = threadNotices(new Map(previous), [
      thread("asks", "needs-input"),
      thread("done", "unread"),
      thread("still", "needs-input"),
      thread("sub", "unread", { rootThreadId: "done" }),
      thread("seen", "idle"),
      thread("new", "needs-input", { title: "" }),
    ]);
    expect(notices.map((n) => [n.threadId, n.title, n.body])).toEqual([
      ["asks", "asks", "Needs you · cmux"],
      ["done", "done", "Done · cmux"],
      ["new", "Untitled thread", "Needs you · cmux"],
    ]);
    expect(notices.every((n) => n.badge === 3 && n.tag === `thread-${n.threadId}`)).toBe(true);
  });

  test("a sub-agent that needs you still says so", () => {
    const { notices } = threadNotices(new Map([["sub", "running"]]), [thread("sub", "needs-input", { rootThreadId: "root" })]);
    expect(notices.map((n) => n.threadId)).toEqual(["sub"]);
  });
});

describe("the phone's notification control", () => {
  const env = { hasServiceWorker: true, hasPushManager: true, standalone: true, permission: "default" as NotificationPermission, subscribed: false };

  test("iPhone Safari outside a home-screen app is told to install it", () => {
    expect(notificationStatus({ ...env, hasPushManager: false, permission: null, standalone: false })).toBe("install");
    expect(notificationStatus({ ...env, hasPushManager: false, permission: null, standalone: undefined })).toBe("unsupported");
  });

  test("off, on, or blocked in Settings", () => {
    expect(notificationStatus(env)).toBe("off");
    expect(notificationStatus({ ...env, permission: "granted", subscribed: true })).toBe("on");
    expect(notificationStatus({ ...env, permission: "default", subscribed: true })).toBe("off");
    expect(notificationStatus({ ...env, permission: "denied" })).toBe("blocked");
  });
});

describe("phone listener push routes", () => {
  const req = (path: string, init: RequestInit & { headers?: Record<string, string> } = {}) =>
    new Request(`http://127.0.0.1:7740/${TOKEN}${path}`, { ...init, headers: { host: HOST, ...init.headers } });

  test("the service worker, under the token", () => withStore(async (store) => {
    const res = await handleRemoteFetchForTest(req("/sw.js"), TOKEN, [], store);
    expect(res?.status).toBe(200);
    expect(res?.headers.get("content-type")).toStartWith("text/javascript");
    expect(await res!.text()).toContain('addEventListener("push"');
    expect((await handleRemoteFetchForTest(new Request("http://127.0.0.1:7740/sw.js", { headers: { host: HOST } }), TOKEN, [], store))?.status).toBe(404);
  }));

  test("the Mac's public key", () => withStore(async (store) => {
    const res = await handleRemoteFetchForTest(req("/api/push"), TOKEN, [], store);
    expect(await res!.json()).toEqual({ publicKey: store.keys.publicKey });
  }));

  test("subscribe and unsubscribe", () => withStore(async (store) => {
    const post = (path: string, body: unknown, origin = `https://${HOST}`) =>
      handleRemoteFetchForTest(req(path, { method: "POST", body: JSON.stringify(body), headers: { origin, "content-type": "application/json" } }), TOKEN, [], store);
    const subscription = { endpoint: ENDPOINT, keys: phoneKeys() };
    expect((await post("/api/push/subscribe", subscription, "https://evil.example.com"))?.status).toBe(403);
    expect((await post("/api/push/subscribe", { ...subscription, endpoint: "https://evil.example.com/x" }))?.status).toBe(400);
    expect(store.list()).toEqual([]);
    expect((await post("/api/push/subscribe", subscription))?.status).toBe(200);
    expect(store.list().map((s) => s.endpoint)).toEqual([ENDPOINT]);
    expect((await post("/api/push/unsubscribe", { endpoint: ENDPOINT }))?.status).toBe(200);
    expect(store.list()).toEqual([]);
  }));

  test("without notifications set up there are no push routes", async () => {
    const res = await handleRemoteFetchForTest(req("/api/push"), TOKEN);
    expect(res?.headers.get("content-type")).toStartWith("text/html");
  });
});
