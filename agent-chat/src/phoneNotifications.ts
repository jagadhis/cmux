// Phone notifications, the page's side: registers the service worker
// (public/sw.js) and subscribes this phone with the sidecar (push.ts).

import { appPath } from "./session";

/**
 * - `unsupported`: this browser has no Web Push; the control is hidden.
 * - `install`: Safari on an iPhone, which only gives push to a home-screen app.
 * - `off` / `on`: whether this phone is subscribed.
 * - `blocked`: notifications were turned off for the app in Settings.
 */
export type PhoneNotificationStatus = "unsupported" | "install" | "off" | "on" | "blocked";

export interface PushEnvironment {
  hasServiceWorker: boolean;
  hasPushManager: boolean;
  /** `navigator.standalone`: false in iPhone Safari, true in a home-screen app, absent elsewhere. */
  standalone: boolean | undefined;
  permission: NotificationPermission | null;
  subscribed: boolean;
}

export function notificationStatus(env: PushEnvironment): PhoneNotificationStatus {
  if (!env.hasServiceWorker || !env.hasPushManager || env.permission === null) {
    return env.standalone === false ? "install" : "unsupported";
  }
  if (env.permission === "denied") return "blocked";
  return env.subscribed && env.permission === "granted" ? "on" : "off";
}

function pushSupported(): boolean {
  return typeof navigator !== "undefined" && "serviceWorker" in navigator && typeof window !== "undefined" && "PushManager" in window && "Notification" in window;
}

async function post(path: string, body: unknown): Promise<void> {
  const res = await fetch(appPath(path), { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  if (!res.ok) {
    const error = await res.json().then((b) => b?.error).catch(() => null);
    throw new Error(typeof error === "string" ? error : `The Mac answered ${res.status}`);
  }
}

/** Registers the worker and reports where this phone stands. A subscription
 * the phone still has is sent again, so the Mac keeps it after a reset. */
export async function preparePhoneNotifications(): Promise<{ status: PhoneNotificationStatus; registration: ServiceWorkerRegistration | null; publicKey: string | null }> {
  const standalone = (navigator as Navigator & { standalone?: boolean }).standalone;
  if (!pushSupported()) {
    return { status: notificationStatus({ hasServiceWorker: false, hasPushManager: false, standalone, permission: null, subscribed: false }), registration: null, publicKey: null };
  }
  const [registration, publicKey] = await Promise.all([
    navigator.serviceWorker.register(appPath("/sw.js")),
    fetch(appPath("/api/push")).then((r) => (r.ok ? r.json() : null)).then((b) => (typeof b?.publicKey === "string" ? b.publicKey : null)).catch(() => null),
  ]);
  if (!publicKey) return { status: "unsupported", registration, publicKey: null };
  const subscription = await registration.pushManager.getSubscription();
  if (subscription && Notification.permission === "granted") await post("/api/push/subscribe", subscription.toJSON()).catch(() => {});
  return {
    status: notificationStatus({ hasServiceWorker: true, hasPushManager: true, standalone, permission: Notification.permission, subscribed: !!subscription }),
    registration,
    publicKey,
  };
}

/** Asks for permission and subscribes. Call it straight from a tap: Safari only asks then. */
export async function enablePhoneNotifications(registration: ServiceWorkerRegistration, publicKey: string): Promise<PhoneNotificationStatus> {
  const key = Uint8Array.from(atob(publicKey.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  let subscription: PushSubscription;
  try {
    subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  } catch (err) {
    if (Notification.permission === "denied") return "blocked";
    throw err;
  }
  try {
    await post("/api/push/subscribe", { ...subscription.toJSON(), welcome: true });
  } catch (err) {
    // The Mac couldn't reach this phone, so don't leave it half on.
    await subscription.unsubscribe().catch(() => {});
    throw err;
  }
  return "on";
}

export async function disablePhoneNotifications(registration: ServiceWorkerRegistration): Promise<PhoneNotificationStatus> {
  const subscription = await registration.pushManager.getSubscription();
  if (subscription) {
    await post("/api/push/unsubscribe", { endpoint: subscription.endpoint }).catch(() => {});
    await subscription.unsubscribe();
  }
  return "off";
}

/** The app icon's badge: threads waiting on you. */
export function setAppBadge(count: number): void {
  const nav = navigator as Navigator & { setAppBadge?: (n: number) => Promise<void>; clearAppBadge?: () => Promise<void> };
  (count > 0 ? nav.setAppBadge?.(count) : nav.clearAppBadge?.())?.catch(() => {});
}
