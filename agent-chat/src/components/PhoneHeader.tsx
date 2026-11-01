// Phone access: the bar above a chat or New chat. The way back to the thread
// list, what the thread is doing, the next thread that needs you, and Done,
// which settles the task in T3 and returns to the list with an Undo.

import { useState } from "react";
import { appPath, type SessionState } from "../session";
import { nextWaiting, settleThread, t3ThreadIdFromSessionId, threadCounts, threadHref, useT3Threads } from "../t3Threads";
import { Check } from "./icons";

const PHONE_HEADER_TEXT = {
  back: "Threads",
  backLabel: "Back to threads",
  newChat: "New chat",
  chat: "Chat",
  needsYou: "Needs you",
  working: "Working",
  connecting: "Connecting…",
  offline: "Not connected",
  idle: "Idle",
  next: "Next",
  nextLabel: (title: string) => `Next thread that needs you: ${title}`,
  done: "Done",
  doneLabel: "Mark this task done",
};

/** How often the header re-reads the thread list for Next and the back badge. */
const HEADER_REFRESH_MS = 10_000;

function chatStatus(s: SessionState): { text: string; tone: "needs-input" | "running" | "offline" | "idle" } {
  const session = s.session;
  if (!s.ready) return { text: PHONE_HEADER_TEXT.connecting, tone: "offline" };
  if (session?.t3Connection) return { text: PHONE_HEADER_TEXT.offline, tone: "offline" };
  if (session?.request || session?.attention) return { text: PHONE_HEADER_TEXT.needsYou, tone: "needs-input" };
  if (session?.status === "running") return { text: PHONE_HEADER_TEXT.working, tone: "running" };
  if (session?.source === "t3" && !session.t3Synced) return { text: PHONE_HEADER_TEXT.connecting, tone: "offline" };
  return { text: PHONE_HEADER_TEXT.idle, tone: "idle" };
}

export function PhoneHeader({ state, newChat }: { state: SessionState; newChat: boolean }) {
  const threadId = newChat ? null : t3ThreadIdFromSessionId(state.session?.id);
  const { threads } = useT3Threads(true, HEADER_REFRESH_MS);
  const [settling, setSettling] = useState(false);
  const list = threads ?? [];
  const current = threadId ? list.find((t) => t.id === threadId) : undefined;
  // New chat has its own task; Next is for moving between threads that wait on you.
  const next = newChat ? null : nextWaiting(list, threadId);
  // Other threads waiting on you, shown on the way back.
  const waitingElsewhere = threadCounts(list.filter((t) => t.id !== threadId)).needsInput;
  const status = newChat ? null : chatStatus(state);
  const title = newChat ? PHONE_HEADER_TEXT.newChat : state.session?.title || current?.title || PHONE_HEADER_TEXT.chat;
  const canSettle = Boolean(threadId) && state.ready && !state.session?.request && state.session?.status !== "running" && !settling;

  const done = () => {
    if (!threadId || !canSettle) return;
    const rootId = current?.rootThreadId ?? threadId;
    setSettling(true);
    settleThread(rootId)
      .then(() => {
        const params = new URLSearchParams({ done: rootId, title: current && current.rootThreadId ? "" : title });
        location.href = `${appPath("/home")}?${params}`;
      })
      .catch(() => setSettling(false));
  };

  return (
    <nav className="phone-bar">
      <a className="phone-back" href={appPath("/home")} aria-label={PHONE_HEADER_TEXT.backLabel}>
        <span className="phone-back-chevron" aria-hidden>‹</span>
        <span className="phone-back-text">{PHONE_HEADER_TEXT.back}</span>
        {waitingElsewhere ? <span className="phone-badge" aria-hidden>{waitingElsewhere}</span> : null}
      </a>
      <div className="phone-title">
        <span className="phone-title-text">{title}</span>
        {status ? (
          <span className={`phone-status phone-status-${status.tone}`}>
            <span className="phone-status-dot" aria-hidden />
            {status.text}
          </span>
        ) : null}
      </div>
      <div className="phone-actions">
        {next ? (
          <a className="phone-action" href={threadHref(next.id)} aria-label={PHONE_HEADER_TEXT.nextLabel(next.title)}>
            {PHONE_HEADER_TEXT.next} ›
          </a>
        ) : null}
        {canSettle || settling ? (
          <button type="button" className="phone-action phone-done" aria-label={PHONE_HEADER_TEXT.doneLabel} disabled={settling} onClick={done}>
            <Check />
            {PHONE_HEADER_TEXT.done}
          </button>
        ) : null}
      </div>
    </nav>
  );
}
