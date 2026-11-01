// Phone access: the open T3 threads, shared by the home page and a chat's
// header. Sorting them into what needs you, what's working and what finished
// is pure, so it's tested without a page.

import { useEffect, useRef, useState } from "react";
import { openSessionConnection } from "./connection";
import { appPath } from "./session";

export type T3ThreadState = "needs-input" | "running" | "unread" | "idle";

export interface HomeThread {
  id: string;
  title: string;
  projectId: string;
  projectName: string;
  rootThreadId: string | null;
  state: T3ThreadState;
  /** What the thread waits on you for, while it needs input. */
  waitingFor?: string | null;
  branch: string | null;
  updatedAt: string;
}

export interface HomeTask {
  root: HomeThread;
  children: HomeThread[];
  /** The most urgent state of the root and its sub-threads. */
  state: T3ThreadState;
}

export interface HomeSection {
  state: T3ThreadState;
  tasks: HomeTask[];
}

const STATE_RANK: Record<T3ThreadState, number> = { "needs-input": 0, running: 1, unread: 2, idle: 3 };
export const SECTION_ORDER: T3ThreadState[] = ["needs-input", "running", "unread", "idle"];

/** The most urgent of a task's states. */
export function urgent(states: T3ThreadState[]): T3ThreadState {
  return states.reduce<T3ThreadState>((best, s) => (STATE_RANK[s] < STATE_RANK[best] ? s : best), "idle");
}

/** Threads grouped into tasks (a root and its sub-threads), in the order the
 * threads arrive, most recently changed first. */
export function groupTasks(threads: HomeThread[]): HomeTask[] {
  const byId = new Map(threads.map((t) => [t.id, t]));
  const tasks = new Map<string, HomeTask>();
  for (const thread of threads) {
    const rootId = thread.rootThreadId && byId.has(thread.rootThreadId) ? thread.rootThreadId : thread.id;
    let task = tasks.get(rootId);
    if (!task) {
      task = { root: byId.get(rootId)!, children: [], state: "idle" };
      tasks.set(rootId, task);
    }
    if (thread.id !== rootId) task.children.push(thread);
  }
  for (const task of tasks.values()) task.state = urgent([task.root.state, ...task.children.map((c) => c.state)]);
  return [...tasks.values()];
}

function matches(thread: HomeThread, words: string[]): boolean {
  const text = `${thread.title} ${thread.projectName} ${thread.branch ?? ""}`.toLowerCase();
  return words.every((word) => text.includes(word));
}

/** Tasks by what they need from you: waiting on you, working, finished since
 * you last looked, then the rest. A search keeps tasks with any matching thread. */
export function homeSections(threads: HomeThread[], query = ""): HomeSection[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const tasks = groupTasks(threads).filter((task) => !words.length || [task.root, ...task.children].some((t) => matches(t, words)));
  return SECTION_ORDER
    .map((state) => ({ state, tasks: tasks.filter((task) => task.state === state) }))
    .filter((section) => section.tasks.length > 0);
}

/** How many threads wait on you and how many work. */
export function threadCounts(threads: HomeThread[]): { needsInput: number; running: number } {
  let needsInput = 0;
  let running = 0;
  for (const t of threads) {
    if (t.state === "needs-input") needsInput += 1;
    else if (t.state === "running") running += 1;
  }
  return { needsInput, running };
}

/** Another thread waiting on you, to go to after this one: the next one in
 * the list after the current thread, wrapping around. */
export function nextWaiting(threads: HomeThread[], currentId: string | null): HomeThread | null {
  const waiting = threads.filter((t) => t.state === "needs-input");
  if (!waiting.length) return null;
  const at = waiting.findIndex((t) => t.id === currentId);
  if (at < 0) return waiting[0];
  return waiting.length > 1 ? waiting[(at + 1) % waiting.length] : null;
}

/** "now", "5m", "3h", "2d". */
export function ago(iso: string, now = Date.now()): string {
  const then = Date.parse(iso);
  if (isNaN(then)) return "";
  const minutes = Math.max(0, Math.round((now - then) / 60_000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.round(hours / 24)}d`;
}

export function threadHref(id: string): string {
  return appPath(`/t3/${encodeURIComponent(id)}`);
}

/** The T3 thread a chat page shows: its session id carries the thread id
 * base64url-encoded after "t3-" (server.ts `t3SessionId`). */
export function t3ThreadIdFromSessionId(sessionId: string | null | undefined): string | null {
  if (!sessionId?.startsWith("t3-")) return null;
  try {
    const b64 = sessionId.slice(3).replace(/-/g, "+").replace(/_/g, "/");
    const bytes = Uint8Array.from(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)), (c) => c.charCodeAt(0));
    return new TextDecoder().decode(bytes) || null;
  } catch {
    return null;
  }
}

/** Marks a task done in T3 (settled, as Agent Home's Verified does), or undoes it. */
export async function settleThread(threadId: string, undo = false): Promise<void> {
  const res = await fetch(appPath(`/api/t3/threads/${encodeURIComponent(threadId)}/${undo ? "unsettle" : "settle"}`), { method: "POST" });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error || `T3 refused (${res.status})`);
  }
}

const REFRESH_MS = 5_000;

export interface T3ThreadList {
  threads: HomeThread[] | null;
  error: string | null;
  connected: boolean;
  refresh(): void;
}

/** The open T3 threads, re-read every few seconds while the page is on screen. */
export function useT3Threads(enabled = true, refreshMs = REFRESH_MS): T3ThreadList {
  const [threads, setThreads] = useState<HomeThread[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const requestRef = useRef<() => void>(() => {});

  useEffect(() => {
    if (!enabled) return;
    let socket: WebSocket | null = null;
    const request = () => {
      if (socket?.readyState === WebSocket.OPEN && document.visibilityState === "visible") socket.send(JSON.stringify({ op: "t3-threads" }));
    };
    requestRef.current = request;
    const disconnect = openSessionConnection({
      createSocket: () => new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + appPath("/ws")),
      onSocket: (ws) => {
        socket = ws;
        if (!ws) setConnected(false);
      },
      onOpen: () => {
        setConnected(true);
        request();
      },
      onMessage: (event) => {
        let msg: any;
        try { msg = JSON.parse(String(event.data)); } catch { return; }
        if (msg?.kind !== "t3-threads") return;
        setThreads(Array.isArray(msg.threads) ? msg.threads : []);
        setError(typeof msg.error === "string" ? msg.error : null);
      },
    });
    const timer = setInterval(request, refreshMs);
    document.addEventListener("visibilitychange", request);
    window.addEventListener("pageshow", request);
    return () => {
      requestRef.current = () => {};
      disconnect();
      clearInterval(timer);
      document.removeEventListener("visibilitychange", request);
      window.removeEventListener("pageshow", request);
    };
  }, [enabled, refreshMs]);

  return { threads, error, connected, refresh: () => requestRef.current() };
}
