// Phone notifications: the home-screen app's service worker (see push.ts).
// It's served from /<token>/sw.js, so its scope is the phone app and a tap
// opens pages under the same token. Safari ends a subscription that receives
// pushes without showing them, so every push shows a notification.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let message = {};
  try {
    message = event.data ? event.data.json() : {};
  } catch {
    message = {};
  }
  const shown = self.registration.showNotification(message.title || "cmux", {
    body: message.body || "",
    tag: message.tag || undefined,
    icon: "apple-touch-icon.png",
    data: { threadId: message.threadId || null },
  });
  const badge = typeof message.badge === "number" && "setAppBadge" in self.navigator
    ? (message.badge > 0 ? self.navigator.setAppBadge(message.badge) : self.navigator.clearAppBadge()).catch(() => {})
    : null;
  event.waitUntil(Promise.all([shown, badge]));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const threadId = event.notification.data?.threadId;
  const target = new URL(threadId ? `t3/${encodeURIComponent(threadId)}` : "home", self.registration.scope).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const open = windows.find((client) => "focus" in client);
    if (open) {
      await open.focus();
      if (open.url !== target && "navigate" in open) await open.navigate(target).catch(() => {});
      return;
    }
    await self.clients.openWindow(target);
  })());
});
