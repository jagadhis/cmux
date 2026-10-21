// Turns successive T3 Code thread projections into the chat's AgentEvents.
//
// T3 owns the conversation. Each time the thread changes, the adapter reads
// its projection and hands it here; this emits only what is new since the
// last projection: a run's user message, assistant and reasoning text as
// deltas, tool starts and ends, and a `done` when a run finishes. If an item
// that was already shown disappears (a rollback), it asks for a reset and
// the history is replayed from scratch.
//
// It also reports what the composer needs: the thread's model selection, the
// request T3 is waiting on (an approval, or questions with options), and the
// work still going after the turn ended (T3's background-work banner).

import type { T3BackgroundKind, T3BackgroundWork, T3ModelSelection, T3PendingRequest, T3Question } from "../t3-contract";
import type { AgentEvent, ChatImage, HtmlArtifact, SessionStatus } from "../types";

export type { T3BackgroundKind, T3BackgroundWork, T3ModelSelection, T3PendingRequest, T3Question, T3QuestionOption } from "../t3-contract";

/** The subset of a T3 projection this module reads. Field names follow T3's contracts. */
export interface T3Projection {
  thread: {
    id: string;
    title: string;
    worktreePath?: string | null;
    modelSelection?: T3ModelSelection;
    activeProviderThreadId?: string | null;
    pullRequests?: T3PullRequestLink[];
  };
  runs: T3Run[];
  messages: { id: string; role: string; text: string; attachments?: T3Attachment[] }[];
  turnItems: T3TurnItem[];
  runtimeRequests: T3RuntimeRequest[];
  providerThreads?: { id: string; pendingBackgroundTasks?: T3BackgroundTask[] }[];
}

/** A file sent with a message; images show in the chat. */
export interface T3Attachment {
  type: string;
  id: string;
  name?: string;
  mimeType?: string;
}

/** A pull request linked to the thread; `watch` is set while T3 watches it. */
export interface T3PullRequestLink {
  host: string;
  repository: string;
  number: number;
  source?: string;
  watch?: unknown;
}

/** Work a provider reports still running after its turn. */
export interface T3BackgroundTask {
  taskId: string;
  kind: string;
  description?: string;
  childThreadId?: string;
}

/** How Stop ends background work: interrupt the run that owns it, or unwatch pull requests. */
export interface T3BackgroundStop {
  runId?: string;
  pullRequests: { host: string; repository: string; number: number }[];
}

export interface T3Run {
  id: string;
  ordinal: number;
  status: string;
  userMessageId?: string | null;
  queueHeld?: boolean;
}

export interface T3TurnItem {
  id: string;
  runId: string;
  ordinal: number;
  status: string;
  type: string;
  title?: string | null;
  text?: string;
  input?: unknown;
  /** A tool's result; an `html_render` call's carries the published page. */
  output?: unknown;
  toolName?: string;
  summary?: string;
  /** `user_input_request` and `approval_request` items name their request. */
  requestId?: string;
  questions?: T3Question[];
  /** A `user_input_request`'s answers once given. */
  questionAnswer?: { answers?: Record<string, unknown> };
  prompt?: string;
  nativeItemRef?: { nativeId?: string | null } | null;
  childThreadId?: string | null;
}

export interface T3RuntimeRequest {
  id: string;
  kind: string;
  status: string;
  responseCapability?: { type: string };
  answers?: Record<string, unknown>;
}

export interface T3Step {
  events: AgentEvent[];
  /** Replay history from scratch before emitting `events`. */
  reset: boolean;
  status: SessionStatus;
  title: string;
  cwd?: string;
  model?: string;
  modelSelection?: T3ModelSelection;
  request: T3PendingRequest | null;
  /** The active run, for interrupts and steering. */
  activeRunId?: string;
  /** Work still going once the turn is idle, or null. */
  background: T3BackgroundWork | null;
  /** Set while there is background work to stop. */
  backgroundStop?: T3BackgroundStop;
}

const ACTIVE_RUN = new Set(["preparing", "queued", "starting", "running", "waiting"]);
const FINISHED_RUN = new Set(["completed", "interrupted", "failed", "cancelled", "rolled_back"]);
const FINISHED_ITEM = new Set(["completed", "failed", "cancelled", "interrupted"]);
const TEXT_ITEMS = new Set(["assistant_message", "reasoning"]);
const TOOL_ITEMS = new Set(["command_execution", "dynamic_tool", "subagent", "file_change", "web_search", "mcp_tool_call"]);

interface ItemCursor {
  textLength: number;
  started: boolean;
  ended: boolean;
  rendered?: boolean;
}

export class T3Timeline {
  private userShown = new Set<string>();
  private doneShown = new Set<string>();
  private items = new Map<string, ItemCursor>();
  private notified = new Set<string>();
  private answered = new Set<string>();
  /** Finished runs with nothing left to emit, and how many items they had then. */
  private settled = new Map<string, number>();
  /** The text item the last emitted event streamed, while nothing else came after it. */
  private lastText: { itemId: string; kind: "delta" | "thinking" } | null = null;

  /** Emits what changed since the last projection. */
  step(projection: T3Projection): T3Step {
    // Items sorted once; each run's list keeps that order.
    const turnItems = [...projection.turnItems].sort((a, b) => a.ordinal - b.ordinal);
    const runs = [...projection.runs].sort((a, b) => a.ordinal - b.ordinal).concat(foreignRuns(projection, turnItems));
    const reset = this.needsReset(projection);
    if (reset) this.clear();

    const events: AgentEvent[] = [];
    const messages = new Map(projection.messages.map((m) => [m.id, m]));
    const itemsByRun = new Map<string, T3TurnItem[]>();
    for (const item of turnItems) {
      const list = itemsByRun.get(item.runId) ?? [];
      list.push(item);
      itemsByRun.set(item.runId, list);
    }

    const requests = new Map(projection.runtimeRequests.map((r) => [r.id, r]));
    for (const run of runs) {
      if (run.status === "rolled_back") continue;
      const items = itemsByRun.get(run.id) ?? [];
      if (this.settled.get(run.id) === items.length) continue;
      this.settled.delete(run.id);
      if (!this.userShown.has(run.id)) {
        const message = run.userMessageId ? messages.get(run.userMessageId) : undefined;
        const text = message?.text ?? "";
        const images = messageImages(message?.attachments);
        if (images.length) this.push(events, { kind: "user", text, images });
        else if (text.trim()) this.push(events, { kind: "user", text });
        this.userShown.add(run.id);
      }
      for (const item of items) this.itemEvents(events, item, requests);
      if (FINISHED_RUN.has(run.status) && !this.doneShown.has(run.id)) {
        if (run.status === "failed") this.push(events, { kind: "error", message: "The run failed in T3." });
        this.push(events, { kind: "done" });
        this.doneShown.add(run.id);
      }
      if (FINISHED_RUN.has(run.status) && items.every((item) => this.itemSettled(item))) this.settled.set(run.id, items.length);
    }

    const activeRun = [...runs].reverse().find((run) => ACTIVE_RUN.has(run.status));
    const pending = pendingBackgroundWork(projection);
    // Like T3: subagents and monitors still out hold the thread idle rather than working.
    const held = pending.tasks.some((t) => t.kind !== "command") && pending.latestRun?.status !== "failed";
    const status: SessionStatus = activeRun && !held ? "running" : "idle";
    const background = status === "idle" ? presentBackgroundWork(pending.tasks) : null;
    return {
      events,
      reset,
      status,
      title: projection.thread.title,
      cwd: projection.thread.worktreePath ?? undefined,
      model: projection.thread.modelSelection?.model,
      modelSelection: projection.thread.modelSelection,
      request: pendingRequest(projection),
      activeRunId: activeRun?.id,
      background,
      ...(background ? { backgroundStop: pending.stop } : {}),
    };
  }

  private push(events: AgentEvent[], evt: AgentEvent, textItemId?: string) {
    events.push(evt);
    // A tool ending doesn't close the open text block on the page, so text after it still needs its paragraph break.
    if (evt.kind === "tool-end") return;
    this.lastText = textItemId && (evt.kind === "delta" || evt.kind === "thinking") ? { itemId: textItemId, kind: evt.kind } : null;
  }

  private itemEvents(events: AgentEvent[], item: T3TurnItem, requests: Map<string, T3RuntimeRequest>) {
    const cursor = this.items.get(item.id) ?? { textLength: 0, started: false, ended: false };
    this.items.set(item.id, cursor);

    if (TEXT_ITEMS.has(item.type)) {
      const text = item.text ?? "";
      if (text.length > cursor.textLength) {
        const kind = item.type === "reasoning" ? "thinking" : "delta";
        let delta = text.slice(cursor.textLength);
        // Two messages in a row would fold into one block and run together
        // ("…done.Next…"): the second starts a new paragraph.
        if (this.lastText && this.lastText.kind === kind && this.lastText.itemId !== item.id) delta = `\n\n${delta}`;
        this.push(events, { kind, text: delta }, item.id);
        cursor.textLength = text.length;
      }
      return;
    }

    if (TOOL_ITEMS.has(item.type)) {
      if (!cursor.started) {
        this.push(events, { kind: "tool-start", toolId: item.id, name: toolName(item), detail: toolDetail(item) });
        cursor.started = true;
      }
      if (FINISHED_ITEM.has(item.status) && !cursor.ended) {
        this.push(events, { kind: "tool-end", toolId: item.id, ok: item.status === "completed" });
        cursor.ended = true;
      }
      if (item.status === "completed" && !cursor.rendered) {
        const artifact = htmlRenderArtifact(item);
        if (artifact) this.push(events, { kind: "html-render", artifact });
        // An html_render page whose output hasn't arrived yet is looked for again next step.
        if (artifact || !isHtmlRenderTool(item)) cursor.rendered = true;
      }
      return;
    }

    if (item.type === "user_input_request" && !this.answered.has(item.id)) {
      // T3 records the answers on the item; older threads only on the request.
      const request = item.requestId ? requests.get(item.requestId) : undefined;
      const answers = item.questionAnswer?.answers ?? (request?.status === "resolved" ? request.answers : undefined);
      if (answers) {
        // The user's answer reads as their reply, between the question and what the agent did with it.
        const lines = answerLines(item.questions ?? [], answers);
        if (lines.length) this.push(events, { kind: "user", text: lines.join("\n") });
        this.answered.add(item.id);
      }
      return;
    }

    if (item.type === "notification" && item.summary && !this.notified.has(item.id)) {
      this.push(events, { kind: "status", text: item.summary });
      this.notified.add(item.id);
    }
  }

  /** Whether an item has emitted all it ever will, so its finished run can be skipped. */
  private itemSettled(item: T3TurnItem): boolean {
    if (TEXT_ITEMS.has(item.type)) return FINISHED_ITEM.has(item.status);
    if (TOOL_ITEMS.has(item.type)) {
      if (item.status === "completed" && isHtmlRenderTool(item)) return this.items.get(item.id)?.rendered === true;
      return FINISHED_ITEM.has(item.status);
    }
    if (item.type === "user_input_request") return this.answered.has(item.id);
    if (item.type === "notification") return this.notified.has(item.id) || FINISHED_ITEM.has(item.status);
    return true;
  }

  /** A rollback or a rewritten history: something already shown is gone or got shorter. */
  private needsReset(projection: T3Projection): boolean {
    if (this.items.size === 0 && this.userShown.size === 0) return false;
    const runIds = new Set(projection.runs.filter((r) => r.status !== "rolled_back").map((r) => r.id));
    for (const runId of this.userShown) if (!runIds.has(runId)) return true;
    const items = new Map(projection.turnItems.map((i) => [i.id, i]));
    for (const [id, cursor] of this.items) {
      const item = items.get(id);
      if (!item) return true;
      if (TEXT_ITEMS.has(item.type) && (item.text ?? "").length < cursor.textLength) return true;
    }
    return false;
  }

  private clear() {
    this.userShown.clear();
    this.doneShown.clear();
    this.items.clear();
    this.notified.clear();
    this.answered.clear();
    this.settled.clear();
    this.lastText = null;
  }
}

/** Sub-threads have no runs of their own: their items carry the parent
 * thread's run ids. Group those into stand-in runs, in item order, that
 * count as finished once every item has. `turnItems` is sorted by ordinal. */
function foreignRuns(projection: T3Projection, turnItems: T3TurnItem[]): T3Run[] {
  const known = new Set(projection.runs.map((r) => r.id));
  const groups = new Map<string, T3TurnItem[]>();
  for (const item of turnItems) {
    if (known.has(item.runId)) continue;
    const list = groups.get(item.runId) ?? [];
    list.push(item);
    groups.set(item.runId, list);
  }
  const offset = projection.runs.reduce((max, r) => Math.max(max, r.ordinal), 0) + 1;
  return [...groups.entries()].map(([id, items], index) => ({
    id,
    ordinal: offset + index,
    status: items.every((i) => FINISHED_ITEM.has(i.status) || TEXT_ITEMS.has(i.type) && i.status !== "running")
      ? "completed"
      : "running",
    userMessageId: null,
  }));
}

// MARK: - Background work
// Mirrors T3's derivePendingBackgroundWork (packages/shared) and
// presentPendingBackgroundWork (packages/client-runtime).

const BACKGROUND_ITEMS = new Set(["command_execution", "dynamic_tool", "subagent"]);
const ACTIVE_ITEM = new Set(["pending", "running", "waiting"]);
const SETTLED_FOR_BACKGROUND = new Set(["cancelled", "completed", "failed", "interrupted", "waiting"]);
const BACKGROUND_KINDS: Record<T3BackgroundKind, { order: number; singular: string; plural: string }> = {
  subagent: { order: 0, singular: "subagent", plural: "subagents" },
  command: { order: 1, singular: "command", plural: "commands" },
  monitor: { order: 2, singular: "monitor", plural: "monitors" },
  background_task: { order: 3, singular: "background task", plural: "background tasks" },
};

interface PendingWork {
  tasks: (T3BackgroundTask & { kind: T3BackgroundKind })[];
  latestRun?: T3Run;
  stop: T3BackgroundStop;
}

function backgroundKind(kind: string): T3BackgroundKind {
  return kind in BACKGROUND_KINDS ? (kind as T3BackgroundKind) : "background_task";
}

function pendingBackgroundWork(projection: T3Projection): PendingWork {
  const runs = projection.runs;
  let latestRun: T3Run | undefined;
  for (const run of runs) {
    if (run.status === "queued" && run.queueHeld) continue;
    if (!latestRun || run.ordinal > latestRun.ordinal) latestRun = run;
  }
  const watches = (projection.thread.pullRequests ?? [])
    .filter((link) => link.watch !== undefined && link.watch !== null && link.source !== "stack-dismissed");
  const watchTasks = watches.map((link) => ({
    taskId: `pull-request-watch:${link.host}/${link.repository}#${link.number}`,
    description: `Watching pull request #${link.number}`,
    kind: "monitor" as const,
  }));
  const unwatch = watches.map(({ host, repository, number }) => ({ host, repository, number }));
  const none: PendingWork = { tasks: [], latestRun, stop: { pullRequests: [] } };

  if (runs.some((run) => run.status === "preparing" || run.status === "starting" || run.status === "running")) return none;
  if (!latestRun) return { tasks: watchTasks, stop: { pullRequests: unwatch } };
  if (!SETTLED_FOR_BACKGROUND.has(latestRun.status)) return none;

  const byId = new Map<string, PendingWork["tasks"][number]>();
  const activeProviderThreadId = projection.thread.activeProviderThreadId;
  for (const providerThread of projection.providerThreads ?? []) {
    if (activeProviderThreadId && providerThread.id !== activeProviderThreadId) continue;
    for (const task of providerThread.pendingBackgroundTasks ?? []) {
      if (!task.taskId || byId.has(task.taskId)) continue;
      const description = task.description?.trim();
      byId.set(task.taskId, {
        taskId: task.taskId,
        kind: backgroundKind(task.kind),
        ...(description ? { description } : {}),
        ...(task.kind === "subagent" && task.childThreadId ? { childThreadId: task.childThreadId } : {}),
      });
    }
  }
  const rolledBack = new Set(runs.filter((run) => run.status === "rolled_back").map((run) => run.id));
  for (const item of projection.turnItems) {
    if (!BACKGROUND_ITEMS.has(item.type) || !ACTIVE_ITEM.has(item.status) || rolledBack.has(item.runId)) continue;
    if (item.type === "dynamic_tool" && (item.input as { persistent?: unknown } | null)?.persistent === true) continue;
    const taskId = item.nativeItemRef?.nativeId || item.id;
    if (byId.has(taskId)) continue;
    const description = backgroundItemDescription(item);
    byId.set(taskId, {
      taskId,
      kind: item.type === "subagent" ? "subagent" : item.type === "command_execution" ? "command" : "background_task",
      ...(description ? { description } : {}),
      ...(item.type === "subagent" && item.childThreadId ? { childThreadId: item.childThreadId } : {}),
    });
  }
  const runTasks = byId.size > 0;
  for (const task of watchTasks) byId.set(task.taskId, task);
  return {
    tasks: [...byId.values()],
    latestRun,
    // T3's Stop interrupts the latest run when it owns work; otherwise it unwatches.
    stop: runTasks ? { runId: latestRun.id, pullRequests: [] } : { pullRequests: unwatch },
  };
}

function backgroundItemDescription(item: T3TurnItem): string | undefined {
  if (item.title?.trim()) return item.title.trim();
  if (item.type === "command_execution" && typeof item.input === "string") return item.input.trim() || undefined;
  if (item.type === "dynamic_tool" && item.toolName?.trim()) return item.toolName.trim();
  if (item.type === "subagent" && item.prompt?.trim()) return item.prompt.trim();
  return undefined;
}

/** T3's subagent titles drop a "Subagent:" prefix and name path-like titles by their last part. */
function subagentLabel(title: string): string {
  const display = title.replace(/^Subagent:\s*/i, "");
  const path = /^\/root\/(?:[^/]+\/)*([^/]+)\/?$/u.exec(display);
  if (!path) return display;
  const name = path[1]!.replace(/[_\s]+/gu, " ").trim();
  return name.replace(/(^|\s)\S/gu, (letter) => letter.toUpperCase()) || display;
}

function joinWithAnd(parts: string[]): string {
  return parts.length <= 1 ? parts.join("") : `${parts.slice(0, -1).join(", ")} and ${parts.at(-1)}`;
}

function presentBackgroundWork(tasks: PendingWork["tasks"]): T3BackgroundWork | null {
  if (!tasks.length) return null;
  const waiting = tasks.some((task) => task.kind !== "command");
  const items = tasks
    .map((task) => {
      const description = task.description?.trim();
      const label = (task.kind === "subagent" && description ? subagentLabel(description).trim() : description) || "";
      return {
        taskId: task.taskId,
        kind: task.kind,
        label: label ? firstLine(label) : BACKGROUND_KINDS[task.kind].singular,
        ...(task.kind === "subagent" && task.childThreadId ? { childThreadId: task.childThreadId } : {}),
      };
    })
    .sort((a, b) => BACKGROUND_KINDS[a.kind].order - BACKGROUND_KINDS[b.kind].order);
  const [only] = items;
  if (items.length === 1 && only) {
    const noun = BACKGROUND_KINDS[only.kind].singular;
    const named = only.label !== noun;
    const title = waiting
      ? named ? `${only.kind === "monitor" ? "" : `Waiting on ${noun} `}${only.label}` : `Waiting on a ${noun}`
      : named ? `Running: ${only.label}` : `Running a ${noun}`;
    return { title, items, waiting };
  }
  const counts = new Map<T3BackgroundKind, number>();
  for (const item of items) counts.set(item.kind, (counts.get(item.kind) ?? 0) + 1);
  const groups = [...counts].map(([kind, count]) => `${count} ${count === 1 ? BACKGROUND_KINDS[kind].singular : BACKGROUND_KINDS[kind].plural}`);
  return { title: `${waiting ? "Waiting on" : "Running"} ${joinWithAnd(groups)}`, items, waiting };
}

// MARK: - Images and pages

const T3_ATTACHMENT_ID = /^[a-z0-9_-]{1,256}$/i;

function attachmentUrl(id: string): string {
  return `/api/t3/attachments/${encodeURIComponent(id)}`;
}

/** The images among a message's attachments. */
export function messageImages(attachments: T3Attachment[] | undefined): ChatImage[] {
  return (attachments ?? [])
    .filter((a) => a.type === "image" && typeof a.id === "string" && T3_ATTACHMENT_ID.test(a.id))
    .map((a) => ({ url: attachmentUrl(a.id), name: a.name?.trim() || "Image" }));
}

const HTML_RENDER_MIN_HEIGHT = 80;
const HTML_RENDER_MAX_HEIGHT = 2000;
const OUTLINE = /^[tmg]\d{1,4},\d{1,4},[1-9]\d{0,3},[1-9]\d{0,3},[1-9]\d{0,2}(?:;[tmg]\d{1,4},\d{1,4},[1-9]\d{0,3},[1-9]\d{0,3},[1-9]\d{0,2}){0,47}$/;

function clampHeight(height: number): number {
  return Math.min(HTML_RENDER_MAX_HEIGHT, Math.max(HTML_RENDER_MIN_HEIGHT, Math.round(height)));
}

/** The `htmlRender` reference in a tool result: compacted (`{ htmlRender }`), in
 * `structuredContent` or `content`, as JSON text, or in a text content block. */
function htmlRenderReference(value: unknown, depth: number): Record<string, unknown> | null {
  if (depth > 4 || value === null || value === undefined) return null;
  if (typeof value === "string") {
    if (value.length > 16_384) return null;
    try { return htmlRenderReference(JSON.parse(value), depth + 1); } catch { return null; }
  }
  if (Array.isArray(value)) {
    for (const block of value.slice(0, 32)) {
      const text = (block as { text?: unknown } | null)?.text;
      const ref = htmlRenderReference(typeof text === "object" && text !== null ? (text as { text?: unknown }).text ?? text : text, depth + 1);
      if (ref) return ref;
    }
    return null;
  }
  if (typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  if (record.isError === true || record.is_error === true || (record.error !== undefined && record.error !== null)) return null;
  if (record.htmlRender && typeof record.htmlRender === "object") return record.htmlRender as Record<string, unknown>;
  return htmlRenderReference(record.structuredContent ?? record.content, depth + 1);
}

/** The page a completed `html_render` call published, read as T3's `readHtmlRenderReference` reads it. */
function isHtmlRenderTool(item: Pick<T3TurnItem, "type" | "toolName">): boolean {
  return item.type === "dynamic_tool" && /(?:^|__)html_render$/.test(item.toolName ?? "");
}

export function htmlRenderArtifact(item: Pick<T3TurnItem, "id" | "type" | "toolName" | "output">): HtmlArtifact | null {
  if (!isHtmlRenderTool(item)) return null;
  const ref = htmlRenderReference(item.output, 0);
  if (!ref) return null;
  const { attachmentId, title, height, heights, outline } = ref;
  if (typeof attachmentId !== "string" || !T3_ATTACHMENT_ID.test(attachmentId)) return null;
  if (typeof height !== "number" || !Number.isFinite(height)) return null;
  const measured = Array.isArray(heights) && heights.length > 0 && heights.length <= 24
    && heights.every((h) => Array.isArray(h) && h.length === 2 && Number.isInteger(h[0]) && h[0] >= 1 && h[0] <= 10_000 && typeof h[1] === "number" && Number.isFinite(h[1]))
    ? (heights as [number, number][]).map(([w, h]) => [w, clampHeight(h)] as [number, number]).sort((a, b) => a[0] - b[0])
    : undefined;
  return {
    id: attachmentId,
    url: attachmentUrl(attachmentId),
    title: (typeof title === "string" ? title.trim().slice(0, 200) : "") || "HTML",
    height: clampHeight(height),
    ...(measured ? { heights: measured } : {}),
    ...(measured && typeof outline === "string" && OUTLINE.test(outline) ? { outline } : {}),
  };
}

function toolName(item: T3TurnItem): string {
  switch (item.type) {
    case "command_execution": return "Bash";
    case "subagent": return "Agent";
    case "file_change": return "Edit";
    case "web_search": return "WebSearch";
    default: return item.toolName || item.title || "Tool";
  }
}

function toolDetail(item: T3TurnItem): string | undefined {
  if (typeof item.input === "string") return firstLine(item.input);
  if (item.input && typeof item.input === "object") {
    const input = item.input as Record<string, unknown>;
    for (const key of ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"]) {
      const value = input[key];
      if (typeof value === "string" && value.trim()) return firstLine(value);
    }
  }
  return item.title ?? undefined;
}

function firstLine(text: string): string {
  const line = text.split("\n").find((l) => l.trim()) ?? text;
  return line.length > 160 ? `${line.slice(0, 159)}…` : line;
}

const REQUEST_TITLES: Record<string, string> = {
  command: "Wants to run a command",
  "file-change": "Wants to change files",
  "file-read": "Wants to read files",
  permission: "Needs permission",
  "mcp-elicitation": "Needs your input",
  dynamic_tool_call: "Wants to use a tool",
  user_input: "Asked you a question",
  auth_refresh: "Needs you to sign in again",
};

function pendingRequest(projection: T3Projection): T3PendingRequest | null {
  const request = [...projection.runtimeRequests].reverse().find((r) => r.status === "pending");
  if (!request) return null;
  const capability = request.responseCapability?.type ?? "live";
  const title = REQUEST_TITLES[request.kind] ?? "Needs your input";
  const requestItem = [...projection.turnItems].reverse().find((i) => i.requestId === request.id);

  if (request.kind === "user_input") {
    const questions = requestItem?.type === "user_input_request" ? requestItem.questions ?? [] : [];
    return {
      id: request.id,
      kind: request.kind,
      title,
      isApproval: false,
      questions: questions.map((q) => ({ ...q, multiSelect: q.multiSelect ?? false })),
      answerable: questions.length > 0 && capability !== "not_resumable",
      dismissible: capability === "message",
    };
  }

  // Like T3, sign-ins and dynamic tool calls aren't decided with allow/deny.
  const isApproval = !["auth_refresh", "dynamic_tool_call", "mcp-elicitation"].includes(request.kind);
  // The tool the agent is waiting on is the latest unfinished tool item.
  const waitingItem = [...projection.turnItems]
    .filter((i) => TOOL_ITEMS.has(i.type) && !FINISHED_ITEM.has(i.status))
    .sort((a, b) => b.ordinal - a.ordinal)[0];
  const prompt = requestItem?.type === "approval_request" ? requestItem.prompt?.trim() : undefined;
  return {
    id: request.id,
    kind: request.kind,
    title,
    detail: waitingItem ? toolDetail(waitingItem) : prompt ? firstLine(prompt) : undefined,
    isApproval,
    answerable: isApproval && capability === "live",
    dismissible: false,
  };
}

/** "Header: answer" lines for a resolved question, using option labels. */
export function answerLines(questions: T3Question[], answers: Record<string, unknown>): string[] {
  const lines: string[] = [];
  for (const question of questions) {
    const raw = answers[question.id];
    const values = (Array.isArray(raw) ? raw : [raw]).filter((v): v is string => typeof v === "string" && v.trim() !== "");
    if (!values.length) continue;
    const labels = values.map((v) => question.options.find((o) => (o.value ?? o.label) === v)?.label ?? v);
    lines.push(`${question.header}: ${labels.join(", ")}`);
  }
  return lines;
}
