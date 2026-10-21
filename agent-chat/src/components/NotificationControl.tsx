// Phone access: turns this phone's notifications on and off (phoneNotifications.ts),
// and keeps the app icon's badge at the number of threads waiting on you.

import { useEffect, useRef, useState } from "react";
import { disablePhoneNotifications, enablePhoneNotifications, preparePhoneNotifications, setAppBadge, type PhoneNotificationStatus } from "../phoneNotifications";

const NOTIFY_TEXT = {
  off: "Turn on notifications",
  on: "Notifications on",
  working: "Turning on…",
  install: "For notifications, add this page to your Home Screen (Share → Add to Home Screen) and open it from there.",
  blocked: "Notifications are off for cmux. Turn them on in Settings → Notifications → cmux.",
  failed: "Couldn't turn on notifications",
};

/** `waiting`: threads that need you, or null before the list has loaded. */
export function NotificationControl({ waiting }: { waiting: number | null }) {
  const [status, setStatus] = useState<PhoneNotificationStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const setup = useRef<{ registration: ServiceWorkerRegistration | null; publicKey: string | null }>({ registration: null, publicKey: null });

  useEffect(() => {
    let live = true;
    preparePhoneNotifications()
      .then((ready) => {
        if (!live) return;
        setup.current = ready;
        setStatus(ready.status);
      })
      .catch(() => live && setStatus("unsupported"));
    return () => { live = false; };
  }, []);

  useEffect(() => {
    if (waiting !== null) setAppBadge(waiting);
  }, [waiting]);

  if (status === null || status === "unsupported") return null;
  if (status === "install" || status === "blocked") return <p className="home-note home-notify-note">{NOTIFY_TEXT[status]}</p>;

  const toggle = async () => {
    const { registration, publicKey } = setup.current;
    if (!registration || !publicKey || busy) return;
    setBusy(true);
    setError(null);
    try {
      setStatus(status === "on" ? await disablePhoneNotifications(registration) : await enablePhoneNotifications(registration, publicKey));
    } catch (err) {
      setError(`${NOTIFY_TEXT.failed}: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <button type="button" className={`home-notify${status === "on" ? " home-notify-on" : ""}`} aria-pressed={status === "on"} disabled={busy} onClick={toggle}>
        {busy ? NOTIFY_TEXT.working : NOTIFY_TEXT[status]}
      </button>
      {error ? <p className="home-note home-error">{error}</p> : null}
    </>
  );
}
