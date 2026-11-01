// Phone access: the home page. The open T3 threads sorted by what they need
// from you (waiting on you, working, ready to review, the rest), a search,
// and New chat at thumb reach. A thread opens as its chat; Done settles a
// task in T3, as Agent Home's Verified does on the Mac, with an Undo.

import { useEffect, useMemo, useState } from "react";
import { appPath } from "../session";
import {
  ago,
  homeSections,
  settleThread,
  threadCounts,
  threadHref,
  useT3Threads,
  type HomeTask,
  type HomeThread,
  type T3ThreadState,
} from "../t3Threads";
import { Check } from "./icons";
import { NotificationControl } from "./NotificationControl";

export { ago } from "../t3Threads";

const HOME_TEXT = {
  title: "cmux",
  newChat: "New chat",
  search: "Search threads",
  connecting: "Connecting to your Mac…",
  offline: "Can't reach your Mac. Check that it's awake, cmux is open and Tailscale is on.",
  empty: "No open threads. Start one with New chat.",
  noMatches: "No threads match.",
  untitled: "Untitled thread",
  done: "Done",
  doneLabel: (title: string) => `Mark "${title}" done`,
  markedDone: "Marked done",
  undo: "Undo",
  showEarlier: (n: number) => `Show ${n} earlier ${n === 1 ? "thread" : "threads"}`,
  hideEarlier: "Hide earlier threads",
  moreSubthreads: (n: number) => `${n} more ${n === 1 ? "sub-thread" : "sub-threads"}`,
  fewerSubthreads: "Fewer sub-threads",
  sections: {
    "needs-input": "Needs you",
    running: "Working",
    unread: "Ready to review",
    idle: "Earlier",
  } satisfies Record<T3ThreadState, string>,
  states: {
    "needs-input": "Needs you",
    running: "Working",
    unread: "New",
    idle: "",
  } satisfies Record<T3ThreadState, string>,
};

/** How long a task marked done stays hidden while T3 catches up. */
const DONE_HIDE_MS = 10_000;
const TOAST_MS = 6_000;

interface DoneToast { id: string; title: string; error?: string }

function rowMeta(thread: HomeThread, showProject: boolean): string {
  return [showProject ? thread.projectName : null, thread.branch, ago(thread.updatedAt)].filter(Boolean).join(" · ");
}

function ThreadRow({ thread, state, showProject, child = false, onDone }: {
  thread: HomeThread;
  state: T3ThreadState;
  showProject: boolean;
  child?: boolean;
  onDone?: () => void;
}) {
  const title = thread.title || HOME_TEXT.untitled;
  const waiting = thread.state === "needs-input" ? thread.waitingFor : null;
  return (
    <div className={`home-row${child ? " home-row-child" : ""}`}>
      <a className="home-row-link" href={threadHref(thread.id)}>
        <span className={`home-dot home-dot-${state}`} aria-hidden />
        <span className="home-row-text">
          <span className="home-row-title">{title}</span>
          {waiting ? <span className="home-row-waiting">{waiting}</span> : null}
          <span className="home-row-meta">
            {child && thread.state !== "idle" ? <span className={`home-row-state home-row-state-${thread.state}`}>{HOME_TEXT.states[thread.state]}</span> : null}
            {rowMeta(thread, showProject)}
          </span>
        </span>
        <span className="home-row-chevron" aria-hidden>›</span>
      </a>
      {onDone ? (
        <button type="button" className="home-done" aria-label={HOME_TEXT.doneLabel(title)} onClick={onDone}>
          <Check />
          <span>{HOME_TEXT.done}</span>
        </button>
      ) : null}
    </div>
  );
}

function TaskCard({ task, onDone }: { task: HomeTask; onDone?: (task: HomeTask) => void }) {
  const [expanded, setExpanded] = useState(false);
  // Sub-threads that want attention always show; quiet ones fold away.
  const loud = task.children.filter((c) => c.state !== "idle");
  const quiet = task.children.filter((c) => c.state === "idle");
  const children = expanded ? task.children : loud;
  return (
    <div className="home-task">
      <ThreadRow
        thread={task.root}
        state={task.state}
        showProject
        onDone={onDone && (task.state === "unread" || task.state === "idle") ? () => onDone(task) : undefined}
      />
      {children.map((child) => <ThreadRow key={child.id} thread={child} state={child.state} showProject={false} child />)}
      {quiet.length ? (
        <button type="button" className="home-more" onClick={() => setExpanded(!expanded)}>
          {expanded ? HOME_TEXT.fewerSubthreads : HOME_TEXT.moreSubthreads(quiet.length)}
        </button>
      ) : null}
    </div>
  );
}

export function Home() {
  const { threads, error, connected, refresh } = useT3Threads();
  const [query, setQuery] = useState("");
  const [showEarlier, setShowEarlier] = useState(false);
  const [hidden, setHidden] = useState<Record<string, number>>({});
  const [toast, setToast] = useState<DoneToast | null>(null);

  useEffect(() => { document.title = HOME_TEXT.title; }, []);

  // A chat's Done comes back here with ?done=<thread id> for the Undo.
  useEffect(() => {
    const params = new URLSearchParams(location.search);
    const id = params.get("done");
    if (!id) return;
    setHidden((h) => ({ ...h, [id]: Date.now() }));
    setToast({ id, title: params.get("title") ?? "" });
    history.replaceState(null, "", location.pathname);
  }, []);

  useEffect(() => {
    if (!toast) return;
    const timer = setTimeout(() => setToast(null), TOAST_MS);
    return () => clearTimeout(timer);
  }, [toast]);

  const visible = useMemo(() => {
    const now = Date.now();
    return (threads ?? []).filter((t) => {
      const at = hidden[t.rootThreadId ?? t.id] ?? hidden[t.id];
      return at === undefined || now - at > DONE_HIDE_MS;
    });
  }, [hidden, threads]);
  const sections = useMemo(() => homeSections(visible, query), [query, visible]);
  const counts = useMemo(() => threadCounts(visible), [visible]);
  const searching = query.trim().length > 0;

  const markDone = (task: HomeTask) => {
    const id = task.root.id;
    setHidden((h) => ({ ...h, [id]: Date.now() }));
    setToast({ id, title: task.root.title });
    settleThread(id)
      .then(refresh)
      .catch((err: Error) => {
        setHidden((h) => { const { [id]: _, ...rest } = h; return rest; });
        setToast({ id, title: task.root.title, error: err.message });
      });
  };
  const undoDone = (id: string) => {
    setToast(null);
    setHidden((h) => { const { [id]: _, ...rest } = h; return rest; });
    settleThread(id, true).then(refresh).catch(() => {});
  };

  return (
    <div className="home">
      <header className="home-header">
        <div className="home-title-row">
          <h1>{HOME_TEXT.title}</h1>
          <span className={`home-conn${connected ? " on" : ""}`} aria-hidden />
          <span className="home-header-spacer" />
          {counts.needsInput ? <span className="home-state home-state-needs-input">{HOME_TEXT.states["needs-input"]} {counts.needsInput}</span> : null}
          {counts.running ? <span className="home-state home-state-running">{HOME_TEXT.states.running} {counts.running}</span> : null}
        </div>
        <input
          className="home-search"
          type="search"
          inputMode="search"
          enterKeyHint="search"
          placeholder={HOME_TEXT.search}
          aria-label={HOME_TEXT.search}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </header>
      <NotificationControl waiting={threads ? threadCounts(threads).needsInput : null} />
      {!connected && threads === null ? <p className="home-note">{HOME_TEXT.connecting}</p> : null}
      {!connected && threads !== null ? <p className="home-note home-error">{HOME_TEXT.offline}</p> : null}
      {error ? <p className="home-note home-error">{error}</p> : null}
      {threads !== null && !visible.length && !error ? <p className="home-note">{HOME_TEXT.empty}</p> : null}
      {visible.length && searching && !sections.length ? <p className="home-note">{HOME_TEXT.noMatches}</p> : null}
      {sections.map((section) => {
        // The rest fold behind a button so what needs you stays on the first screen.
        const folded = section.state === "idle" && !searching && !showEarlier;
        return (
          <section key={section.state} className={`home-section home-section-${section.state}`}>
            <h2>
              <span>{HOME_TEXT.sections[section.state]}</span>
              <span className="home-section-count">{section.tasks.length}</span>
            </h2>
            {folded ? null : section.tasks.map((task) => <TaskCard key={task.root.id} task={task} onDone={markDone} />)}
            {section.state === "idle" && !searching ? (
              <button type="button" className="home-earlier" onClick={() => setShowEarlier(!showEarlier)}>
                {showEarlier ? HOME_TEXT.hideEarlier : HOME_TEXT.showEarlier(section.tasks.length)}
              </button>
            ) : null}
          </section>
        );
      })}
      <a className="home-fab" href={appPath("/t3/new")}>
        <span aria-hidden>+</span>
        {HOME_TEXT.newChat}
      </a>
      {toast ? (
        <div className={`home-toast${toast.error ? " home-toast-error" : ""}`} role="status">
          <span className="home-toast-text">{toast.error ?? `${HOME_TEXT.markedDone}${toast.title ? `: ${toast.title}` : ""}`}</span>
          {toast.error ? null : <button type="button" onClick={() => undoDone(toast.id)}>{HOME_TEXT.undo}</button>}
        </div>
      ) : null}
    </div>
  );
}
