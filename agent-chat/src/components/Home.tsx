// Phone access: the home page. The open T3 threads by project, as Agent Home
// lists them on the Mac, plus New chat. A thread opens as its chat page.
// The list is re-read every few seconds while the page is on screen.

import { useEffect, useMemo, useRef, useState } from "react";
import { openSessionConnection } from "../connection";
import { appPath } from "../session";

export type T3ThreadState = "needs-input" | "running" | "unread" | "idle";

export interface HomeThread {
  id: string;
  title: string;
  projectId: string;
  projectName: string;
  rootThreadId: string | null;
  state: T3ThreadState;
  branch: string | null;
  updatedAt: string;
}

const REFRESH_MS = 5_000;

const HOME_TEXT = {
  title: "cmux",
  newChat: "New chat",
  connecting: "Connecting to your Mac…",
  offline: "Can't reach your Mac. Check that it's awake, cmux is open and Tailscale is on.",
  empty: "No open threads. Start one with New chat.",
  untitled: "Untitled thread",
  noProject: "Other",
  states: {
    "needs-input": "Needs you",
    running: "Working",
    unread: "New",
    idle: "",
  } satisfies Record<T3ThreadState, string>,
};

const STATE_RANK: Record<T3ThreadState, number> = { "needs-input": 0, running: 1, unread: 2, idle: 3 };

/** The most urgent of a task's states. */
function urgent(states: T3ThreadState[]): T3ThreadState {
  return states.reduce<T3ThreadState>((best, s) => (STATE_RANK[s] < STATE_RANK[best] ? s : best), "idle");
}

export interface HomeTask {
  root: HomeThread;
  children: HomeThread[];
  state: T3ThreadState;
}

export interface HomeProject {
  id: string;
  name: string;
  tasks: HomeTask[];
}

/** Threads grouped into tasks (a root and its sub-threads), tasks into projects;
 * both in the order the threads arrive, most recently changed first. */
export function groupThreads(threads: HomeThread[]): HomeProject[] {
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
  const projects = new Map<string, HomeProject>();
  for (const task of tasks.values()) {
    task.state = urgent([task.root.state, ...task.children.map((c) => c.state)]);
    const key = task.root.projectId;
    let project = projects.get(key);
    if (!project) {
      project = { id: key, name: task.root.projectName, tasks: [] };
      projects.set(key, project);
    }
    project.tasks.push(task);
  }
  return [...projects.values()];
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

function threadHref(id: string): string {
  return appPath(`/t3/${encodeURIComponent(id)}`);
}

function StateBadge({ state }: { state: T3ThreadState }) {
  if (state === "idle") return null;
  return <span className={`home-state home-state-${state}`}>{HOME_TEXT.states[state]}</span>;
}

function ThreadRow({ thread, child = false, state = thread.state }: { thread: HomeThread; child?: boolean; state?: T3ThreadState }) {
  const meta = [thread.branch, ago(thread.updatedAt)].filter(Boolean).join(" · ");
  return (
    <a className={`home-row${child ? " home-row-child" : ""}`} href={threadHref(thread.id)}>
      <span className={`home-dot home-dot-${state}`} aria-hidden />
      <span className="home-row-text">
        <span className="home-row-title">{thread.title || HOME_TEXT.untitled}</span>
        {meta ? <span className="home-row-meta">{meta}</span> : null}
      </span>
      <StateBadge state={state} />
    </a>
  );
}

export function Home() {
  const [threads, setThreads] = useState<HomeThread[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const socketRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    document.title = HOME_TEXT.title;
    const request = () => {
      const ws = socketRef.current;
      if (ws?.readyState === WebSocket.OPEN && document.visibilityState === "visible") ws.send(JSON.stringify({ op: "t3-threads" }));
    };
    const disconnect = openSessionConnection({
      createSocket: () => new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + appPath("/ws")),
      onSocket: (ws) => {
        socketRef.current = ws;
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
    const timer = setInterval(request, REFRESH_MS);
    const onVisible = () => request();
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("pageshow", onVisible);
    return () => {
      disconnect();
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("pageshow", onVisible);
    };
  }, []);

  const projects = useMemo(() => groupThreads(threads ?? []), [threads]);
  const counts = useMemo(() => {
    const c = { "needs-input": 0, running: 0 };
    for (const t of threads ?? []) if (t.state === "needs-input" || t.state === "running") c[t.state] += 1;
    return c;
  }, [threads]);

  return (
    <div className="home">
      <header className="home-header">
        <h1>{HOME_TEXT.title}</h1>
        <a className="home-new" href={appPath("/t3/new")}>{HOME_TEXT.newChat}</a>
      </header>
      {counts["needs-input"] || counts.running ? (
        <div className="home-summary">
          {counts["needs-input"] ? <span className="home-state home-state-needs-input">{HOME_TEXT.states["needs-input"]} {counts["needs-input"]}</span> : null}
          {counts.running ? <span className="home-state home-state-running">{HOME_TEXT.states.running} {counts.running}</span> : null}
        </div>
      ) : null}
      {!connected && threads === null ? <p className="home-note">{HOME_TEXT.connecting}</p> : null}
      {!connected && threads !== null ? <p className="home-note home-error">{HOME_TEXT.offline}</p> : null}
      {error ? <p className="home-note home-error">{error}</p> : null}
      {threads !== null && !threads.length && !error ? <p className="home-note">{HOME_TEXT.empty}</p> : null}
      {projects.map((project) => (
        <section key={project.id} className="home-project">
          <h2>{project.name || HOME_TEXT.noProject}</h2>
          {project.tasks.map((task) => (
            <div key={task.root.id} className="home-task">
              <ThreadRow thread={task.root} state={task.state} />
              {task.children.map((child) => <ThreadRow key={child.id} thread={child} child />)}
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}
