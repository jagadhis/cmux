// Turns successive T3 Code thread projections into the chat's AgentEvents.
//
// T3 owns the conversation. Each time the thread changes, the adapter reads
// its projection and hands it here; this emits only what is new since the
// last projection: a run's user message, assistant and reasoning text as
// deltas, tool starts and ends, and a `done` when a run finishes. If an item
// that was already shown disappears (a rollback), it asks for a reset and
// the history is replayed from scratch.
//
// It also reports what the composer needs: the thread's model selection and
// the request T3 is waiting on (an approval, or questions with options).

import type { AgentEvent, SessionStatus } from "../types";

/** The subset of a T3 projection this module reads. Field names follow T3's contracts. */
export interface T3Projection {
  thread: { id: string; title: string; worktreePath?: string | null; modelSelection?: T3ModelSelection };
  runs: T3Run[];
  messages: { id: string; role: string; text: string }[];
  turnItems: T3TurnItem[];
  runtimeRequests: T3RuntimeRequest[];
}

/** T3's model selection: a provider instance, a model, and its option values. */
export interface T3ModelSelection {
  instanceId?: string;
  model?: string;
  options?: { id: string; value: string | boolean }[];
}

export interface T3Run {
  id: string;
  ordinal: number;
  status: string;
  userMessageId?: string | null;
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
  toolName?: string;
  summary?: string;
  /** `user_input_request` and `approval_request` items name their request. */
  requestId?: string;
  questions?: T3Question[];
  /** A `user_input_request`'s answers once given. */
  questionAnswer?: { answers?: Record<string, unknown> };
  prompt?: string;
}

export interface T3QuestionOption {
  label: string;
  description?: string;
  value?: string;
}

export interface T3Question {
  id: string;
  header: string;
  question: string;
  options: T3QuestionOption[];
  multiSelect?: boolean;
  allowCustomAnswer?: boolean;
  initialAnswer?: string;
}

export interface T3RuntimeRequest {
  id: string;
  kind: string;
  status: string;
  responseCapability?: { type: string };
  answers?: Record<string, unknown>;
}

/** A pending request the chat shows as an approval card. */
export interface T3PendingRequest {
  id: string;
  kind: string;
  title: string;
  detail?: string;
  /** Approval requests take a decision; questions take answers. */
  isApproval: boolean;
  /** For `user_input`: the questions, answered in order. */
  questions?: T3Question[];
  /** False when the agent can no longer take the answer here (answer it in T3). */
  answerable: boolean;
  /** Questions T3 lets the user skip without answering. */
  dismissible: boolean;
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
}

export class T3Timeline {
  private userShown = new Set<string>();
  private doneShown = new Set<string>();
  private items = new Map<string, ItemCursor>();
  private notified = new Set<string>();
  private answered = new Set<string>();

  /** Emits what changed since the last projection. */
  step(projection: T3Projection): T3Step {
    const runs = [...projection.runs].sort((a, b) => a.ordinal - b.ordinal).concat(foreignRuns(projection));
    const reset = this.needsReset(projection);
    if (reset) this.clear();

    const events: AgentEvent[] = [];
    const messages = new Map(projection.messages.map((m) => [m.id, m]));
    const itemsByRun = new Map<string, T3TurnItem[]>();
    for (const item of projection.turnItems) {
      const list = itemsByRun.get(item.runId) ?? [];
      list.push(item);
      itemsByRun.set(item.runId, list);
    }

    const requests = new Map(projection.runtimeRequests.map((r) => [r.id, r]));
    for (const run of runs) {
      if (run.status === "rolled_back") continue;
      if (!this.userShown.has(run.id)) {
        const text = run.userMessageId ? messages.get(run.userMessageId)?.text : undefined;
        if (text?.trim()) events.push({ kind: "user", text });
        this.userShown.add(run.id);
      }
      for (const item of (itemsByRun.get(run.id) ?? []).sort((a, b) => a.ordinal - b.ordinal)) {
        events.push(...this.itemEvents(item, requests));
      }
      if (FINISHED_RUN.has(run.status) && !this.doneShown.has(run.id)) {
        if (run.status === "failed") events.push({ kind: "error", message: "The run failed in T3." });
        events.push({ kind: "done" });
        this.doneShown.add(run.id);
      }
    }

    const activeRun = [...runs].reverse().find((run) => ACTIVE_RUN.has(run.status));
    return {
      events,
      reset,
      status: activeRun ? "running" : "idle",
      title: projection.thread.title,
      cwd: projection.thread.worktreePath ?? undefined,
      model: projection.thread.modelSelection?.model,
      modelSelection: projection.thread.modelSelection,
      request: pendingRequest(projection),
      activeRunId: activeRun?.id,
    };
  }

  private itemEvents(item: T3TurnItem, requests: Map<string, T3RuntimeRequest>): AgentEvent[] {
    const cursor = this.items.get(item.id) ?? { textLength: 0, started: false, ended: false };
    this.items.set(item.id, cursor);
    const events: AgentEvent[] = [];

    if (TEXT_ITEMS.has(item.type)) {
      const text = item.text ?? "";
      if (text.length > cursor.textLength) {
        const delta = text.slice(cursor.textLength);
        events.push(item.type === "reasoning" ? { kind: "thinking", text: delta } : { kind: "delta", text: delta });
        cursor.textLength = text.length;
      }
      return events;
    }

    if (TOOL_ITEMS.has(item.type)) {
      if (!cursor.started) {
        events.push({ kind: "tool-start", toolId: item.id, name: toolName(item), detail: toolDetail(item) });
        cursor.started = true;
      }
      if (FINISHED_ITEM.has(item.status) && !cursor.ended) {
        events.push({ kind: "tool-end", toolId: item.id, ok: item.status === "completed" });
        cursor.ended = true;
      }
      return events;
    }

    if (item.type === "user_input_request" && !this.answered.has(item.id)) {
      // T3 records the answers on the item; older threads only on the request.
      const request = item.requestId ? requests.get(item.requestId) : undefined;
      const answers = item.questionAnswer?.answers ?? (request?.status === "resolved" ? request.answers : undefined);
      if (answers) {
        // The user's answer reads as their reply, between the question and what the agent did with it.
        const lines = answerLines(item.questions ?? [], answers);
        if (lines.length) events.push({ kind: "user", text: lines.join("\n") });
        this.answered.add(item.id);
      }
      return events;
    }

    if (item.type === "notification" && item.summary && !this.notified.has(item.id)) {
      events.push({ kind: "status", text: item.summary });
      this.notified.add(item.id);
    }
    return events;
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
  }
}

/** Sub-threads have no runs of their own: their items carry the parent
 * thread's run ids. Group those into stand-in runs, in item order, that
 * count as finished once every item has. */
function foreignRuns(projection: T3Projection): T3Run[] {
  const known = new Set(projection.runs.map((r) => r.id));
  const groups = new Map<string, T3TurnItem[]>();
  for (const item of [...projection.turnItems].sort((a, b) => a.ordinal - b.ordinal)) {
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
