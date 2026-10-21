// Chat source for T3 Code threads (cmux Agent Home).
//
// T3 Code runs the agent; this view is another T3 client. It connects to the
// local T3 server over T3's own WebSocket RPC, using the protocol modules
// from a local T3 Code checkout (`CMUX_T3CODE_DIR`, default ~/projects/t3code)
// so the wire format always matches. The bearer token comes from the macOS
// Keychain item `cmux-agent-home-t3-token`, issued once with
// `t3 auth session issue --scope orchestration:read --scope orchestration:operate`.
//
// Sends, stops, approvals, answers and model changes are T3 commands, so they
// show up in T3 too, and changes made in T3 show up here.
//
// The thread arrives over `orchestration.subscribeThread`: a snapshot, then
// events that `T3ThreadMirror` applies with T3's own reducer. Every 120 ms at
// most, `T3Timeline` turns the projection into chat events.

import { homedir } from "node:os";
import { join } from "node:path";
import type { Adapter, AgentEvent, SessionCtx } from "../types";
import type { T3Answers, T3Decision, T3LaunchDefaults, T3ModelOption, T3ModelProvider, T3Project } from "../t3-contract";
import { T3ThreadMirror, type T3ProjectionReducer, type T3StreamItem } from "./t3-stream";
import { T3Timeline, type T3BackgroundStop, type T3BackgroundWork, type T3ModelSelection, type T3PendingRequest, type T3Projection, type T3Step } from "./t3-timeline";

const T3CODE_DIR = process.env.CMUX_T3CODE_DIR || join(homedir(), "projects", "t3code");
const RUNTIME_FILE = join(process.env.T3CODE_HOME || join(homedir(), ".t3"), "userdata", "server-runtime.json");
const KEYCHAIN_SERVICE = process.env.CMUX_T3_TOKEN_SERVICE || "cmux-agent-home-t3-token";
const REFRESH_DEBOUNCE_MS = 120;
const RETRY_MIN_MS = 1_000;
const RETRY_MAX_MS = 30_000;
/** More fresh snapshots than this in a minute means the reducer can't follow the thread: re-read it instead. */
const MAX_RESYNCS_PER_MINUTE = 3;

/** Callbacks the server gives each T3 session. */
export interface T3SessionHooks {
  onTitle(title: string): void;
  onCwd(cwd: string): void;
  onRequest(request: T3PendingRequest | null): void;
  onModel(selection: T3ModelSelection | null): void;
  onBackground(work: T3BackgroundWork | null): void;
  /** Null once the thread is read and current; otherwise why it can't be (T3 isn't running, the token was refused). */
  onConnection(problem: string | null): void;
  /** A command the user sent failed. */
  onError(message: string): void;
}

interface T3State {
  threadId: string;
  timeline: T3Timeline;
  mirror?: T3ThreadMirror;
  activeRunId?: string;
  request: T3PendingRequest | null;
  modelSelection: T3ModelSelection | null;
  background: T3BackgroundWork | null;
  backgroundStop?: T3BackgroundStop;
  hooks: T3SessionHooks;
  subscription?: { interrupt(): void; resync?: boolean };
  stepTimer?: ReturnType<typeof setTimeout>;
  stepping?: boolean;
  stepAgain?: boolean;
  /** Re-read the thread over RPC on the next step (no reducer). */
  readNext?: boolean;
  /** Set after the first step: later ones emit only what changed. */
  synced?: boolean;
  /** When recent fresh snapshots were asked for. */
  resyncs: number[];
  /** The wait before the next try after a failure; doubles up to 30 s. */
  retryDelay?: number;
  disposed?: boolean;
}

// MARK: - Connection

interface EffectModules {
  Effect: any;
  Layer: any;
  Stream: any;
  Fiber: any;
  RpcClient: any;
  RpcSerialization: any;
  Socket: any;
  Schedule: any;
  WsRpcGroup: any;
}

let modulesPromise: Promise<EffectModules> | undefined;
function effectModules(): Promise<EffectModules> {
  modulesPromise ??= (async () => {
    const base = join(T3CODE_DIR, "packages", "client-runtime", "src", "rpc") + "/";
    const load = (m: string) => import(Bun.resolveSync(m, base));
    const [Effect, Layer, Stream, Fiber, RpcClient, RpcSerialization, Socket, Schedule, contracts] = await Promise.all([
      load("effect/Effect"), load("effect/Layer"), load("effect/Stream"), load("effect/Fiber"),
      load("effect/rpc/RpcClient"), load("effect/rpc/RpcSerialization"), load("effect/socket/Socket"),
      load("effect/Schedule"),
      import(join(T3CODE_DIR, "packages", "contracts", "src", "index.ts")),
    ]);
    return { Effect, Layer, Stream, Fiber, RpcClient, RpcSerialization, Socket, Schedule, WsRpcGroup: contracts.WsRpcGroup };
  })();
  return modulesPromise;
}

let reducerPromise: Promise<T3ProjectionReducer | null> | undefined;
/** T3's projection reducer, from the same checkout as the protocol; null when that checkout has none. */
function projectionReducer(): Promise<T3ProjectionReducer | null> {
  reducerPromise ??= import(join(T3CODE_DIR, "packages", "client-runtime", "src", "state", "orchestrationV2Projection.ts"))
    .then((m) => typeof m.applyOrchestrationV2ProjectionEvent === "function" ? m.applyOrchestrationV2ProjectionEvent as T3ProjectionReducer : null)
    .catch((err) => {
      console.error("[agent-chat] T3's projection reducer didn't load; threads are re-read on every change", err);
      return null;
    });
  return reducerPromise;
}

let cachedToken: string | undefined;
/** The Keychain token. Reading it spawns `security`, so it's read once and again only when T3 refuses it. */
function readToken(options: { fresh?: boolean } = {}): string {
  if (cachedToken && !options.fresh) return cachedToken;
  const result = Bun.spawnSync(["security", "find-generic-password", "-a", process.env.USER ?? "", "-s", KEYCHAIN_SERVICE, "-w"]);
  const token = result.stdout.toString().trim();
  if (!token) {
    cachedToken = undefined;
    throw new Error(
      `No T3 token in the Keychain (${KEYCHAIN_SERVICE}). Issue one with: t3 auth session issue --scope orchestration:read --scope orchestration:operate --label "cmux Agent Home" --token-only`,
    );
  }
  cachedToken = token;
  return token;
}

interface Connection {
  client: any;
  holder: any;
  closed: boolean;
  /** The Keychain token this connection signed in with. */
  token: string;
}

let connectionPromise: Promise<Connection> | undefined;

/** The shared connection to the running T3 server.
 *
 * The socket URL carries a one-time ticket, so a dropped socket (T3 restarted,
 * say after an update) can't reconnect on its own: the RPC client would retry
 * the spent ticket forever. Instead it gives up after a few tries and the
 * connection is dropped (``dropConnection``), so the next call signs in again
 * with a fresh ticket and re-reads where T3 is listening. */
function connection(): Promise<Connection> {
  if (connectionPromise) return connectionPromise;
  const pending = (async (): Promise<Connection> => {
    const m = await effectModules();
    const runtime = JSON.parse(await Bun.file(RUNTIME_FILE).text()) as { origin: string };
    const requestTicket = (token: string) => fetch(new URL("/api/auth/websocket-ticket", runtime.origin), {
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
    });
    let token = readToken();
    let ticketResponse = await requestTicket(token);
    if (ticketResponse.status === 401 || ticketResponse.status === 403) {
      // The user may have issued a new token since it was read.
      const fresh = readToken({ fresh: true });
      if (fresh !== token) {
        token = fresh;
        ticketResponse = await requestTicket(token);
      }
    }
    if (!ticketResponse.ok) throw new Error(`T3 refused the cmux token (HTTP ${ticketResponse.status}).`);
    const { ticket } = (await ticketResponse.json()) as { ticket: string };
    const wsUrl = new URL("/ws", runtime.origin);
    wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
    wsUrl.searchParams.set("orchestrationProtocol", "2");
    wsUrl.searchParams.set("wsTicket", ticket);

    const protocol = m.RpcClient.makeProtocolSocket({ retryPolicy: m.Schedule.recurs(2) });
    const layer = m.Layer.effect(m.RpcClient.Protocol, protocol).pipe(
      m.Layer.provide(m.Layer.mergeAll(
        m.Socket.layerWebSocket(wsUrl.toString()).pipe(m.Layer.provide(m.Socket.layerWebSocketConstructorGlobal)),
        m.RpcSerialization.layerJson,
      )),
    );
    let resolveClient!: (client: any) => void;
    let rejectClient!: (error: unknown) => void;
    const ready = new Promise<any>((resolve, reject) => { resolveClient = resolve; rejectClient = reject; });
    const conn: Connection = { client: undefined, holder: undefined, closed: false, token };
    // The client lives as long as this fiber; its scope holds the socket open.
    conn.holder = m.Effect.runFork(m.Effect.scoped(m.Effect.gen(function* () {
      const client = yield* m.RpcClient.make(m.WsRpcGroup);
      resolveClient(client);
      yield* m.Effect.never;
    })).pipe(m.Effect.provide(layer)));
    conn.holder.addObserver?.((exit: unknown) => {
      conn.closed = true;
      if (connectionPromise === pending) connectionPromise = undefined;
      rejectClient(new Error(`T3 connection closed: ${String(exit).slice(0, 200)}`));
    });
    conn.client = await ready;
    // T3 is back: chats waiting out a long backoff resubscribe now.
    wakeWaitingSessions();
    return conn;
  })();
  connectionPromise = pending;
  pending.catch(() => { if (connectionPromise === pending) connectionPromise = undefined; });
  return pending;
}

/** Forgets a broken connection so the next call opens a new one. */
function dropConnection(conn: Connection) {
  if (conn.closed) return;
  conn.closed = true;
  void effectModules().then((m) => m.Effect.runFork(m.Fiber.interrupt(conn.holder)));
  void connectionPromise?.then((current) => { if (current === conn) connectionPromise = undefined; }).catch(() => {});
}

/** Whether an RPC failure came from the socket rather than from T3 answering. */
export function isConnectionFailure(err: unknown): boolean {
  const text = `${(err as { _tag?: string })?._tag ?? ""} ${err instanceof Error ? err.message : String(err)}`;
  return /socket|rpcclient|clientprotocol|ping timeout|websocket|econnrefused|connection (closed|refused)/i.test(text);
}

/** Runs an RPC. A read that fails on a broken connection is retried once on a new one. */
async function run<T>(make: (client: any) => any, options: { retry: boolean } = { retry: true }): Promise<T> {
  const [m, conn] = await Promise.all([effectModules(), connection()]);
  try {
    return await m.Effect.runPromise(make(conn.client));
  } catch (err) {
    if (!isConnectionFailure(err)) throw err;
    dropConnection(conn);
    if (!options.retry) throw new Error("Lost the connection to T3. Try again.");
    const fresh = await connection();
    return m.Effect.runPromise(make(fresh.client));
  }
}

async function dispatch(command: Record<string, unknown>) {
  // Commands aren't retried: one that reached T3 before the socket broke would run twice.
  await run((client) => client["orchestration.dispatchCommand"]({ commandId: crypto.randomUUID(), ...command }), { retry: false });
}

// MARK: - Session wiring

function state(sess: SessionCtx): T3State | undefined {
  return sess.internal.t3 as T3State | undefined;
}

/** Starts mirroring a T3 thread into a chat session. */
export function attachT3Thread(sess: SessionCtx, threadId: string, hooks: T3SessionHooks) {
  const s: T3State = { threadId, timeline: new T3Timeline(), request: null, modelSelection: null, background: null, hooks, resyncs: [] };
  sess.internal.t3 = s;
  void subscribe(sess, s);
}

/** Follows the thread's stream. After a dropped stream it resumes after the last
 * sequence seen, so T3 replays only what was missed. */
async function subscribe(sess: SessionCtx, s: T3State) {
  try {
    const [m, conn, reducer] = await Promise.all([effectModules(), connection(), projectionReducer()]);
    if (s.disposed) return;
    s.mirror ??= new T3ThreadMirror(reducer);
    const sequence = s.mirror.sequence;
    // A long thread comes as its recent window, as `getThreadProjection` reads it.
    // `synchronized` follows the snapshot or the replay of what was missed.
    const input = {
      threadId: s.threadId,
      acceptBoundedSnapshot: true,
      requestCompletionMarker: true,
      ...(sequence !== undefined ? { afterSequence: sequence } : {}),
    };
    const fiber = m.Effect.runFork(m.Stream.runForEach(
      conn.client["orchestration.subscribeThread"](input),
      (item: T3StreamItem) => m.Effect.sync(() => onStreamItem(sess, s, item)),
    ));
    const subscription: NonNullable<T3State["subscription"]> = { interrupt: () => m.Effect.runFork(m.Fiber.interrupt(fiber)) };
    s.subscription = subscription;
    fiber.addObserver?.((exit: unknown) => {
      if (s.disposed || s.subscription !== subscription) return;
      s.subscription = undefined;
      if (subscription.resync) {
        void subscribe(sess, s);
        return;
      }
      // One thread's stream failing (a deleted or broken thread) leaves the shared socket
      // alone: dropping it would end every other chat's stream too.
      const failure = (exit as { _tag?: string; cause?: unknown } | undefined)?._tag === "Failure" ? (exit as { cause?: unknown }).cause : undefined;
      if (failure !== undefined && !isConnectionFailure(new Error(Bun.inspect(failure)))) {
        lostConnection(sess, s, "T3 couldn't stream this thread. Retrying…");
        return;
      }
      // The stream ended (T3 restarted or the socket dropped): sign in again and resubscribe.
      dropConnection(conn);
      lostConnection(sess, s, "Lost the connection to T3. Reconnecting…");
    });
  } catch (err) {
    if (s.disposed) return;
    lostConnection(sess, s, err instanceof Error ? err.message : String(err));
  }
}

function onStreamItem(sess: SessionCtx, s: T3State, item: T3StreamItem) {
  // Items the old stream still delivers while a fresh snapshot is on its way don't count.
  if (s.disposed || !s.mirror || s.subscription?.resync) return;
  s.retryDelay = undefined;
  if (item.kind === "synchronized") {
    // Caught up, perhaps with nothing missed: publish so status and connection state are current.
    if (s.mirror.projection) scheduleStep(sess, s, 0);
    return;
  }
  const result = s.mirror.apply(item);
  if (result === "unchanged") return;
  if (result === "resync") {
    resync(sess, s);
    return;
  }
  if (result === "read") s.readNext = true;
  // The first snapshot shows right away; later changes batch up.
  scheduleStep(sess, s, s.synced ? REFRESH_DEBOUNCE_MS : 0);
}

/** Starts over from a fresh snapshot. A thread that keeps needing one is re-read on every change instead. */
function resync(sess: SessionCtx, s: T3State) {
  const now = Date.now();
  s.resyncs = s.resyncs.filter((at) => now - at < 60_000);
  s.resyncs.push(now);
  if (s.resyncs.length > MAX_RESYNCS_PER_MINUTE && s.mirror) {
    s.mirror.reducer = null;
    s.readNext = true;
    scheduleStep(sess, s, REFRESH_DEBOUNCE_MS);
    return;
  }
  s.mirror?.forget();
  const subscription = s.subscription;
  if (!subscription) return;
  subscription.resync = true;
  subscription.interrupt();
}

function lostConnection(sess: SessionCtx, s: T3State, problem: string) {
  s.hooks.onConnection(problem);
  // Nothing is known while disconnected; don't keep showing a run as working.
  sess.setStatus("idle");
  retryLater(s, () => { void subscribe(sess, s); });
}

function scheduleStep(sess: SessionCtx, s: T3State, delay: number) {
  if (s.stepTimer) return;
  s.stepTimer = setTimeout(() => {
    s.stepTimer = undefined;
    void step(sess, s);
  }, delay);
}

/** Emits what changed in the projection. Runs one at a time; a change during a read steps again. */
async function step(sess: SessionCtx, s: T3State) {
  if (s.stepping) { s.stepAgain = true; return; }
  s.stepping = true;
  let reading = false;
  try {
    if (s.readNext && s.mirror) {
      s.readNext = false;
      reading = true;
      const projection = await run<T3Projection>((client) =>
        client["orchestration.getThreadProjection"]({ threadId: s.threadId }));
      if (s.disposed) return;
      s.mirror.replace(projection);
    }
    const projection = s.mirror?.projection;
    if (!projection || s.disposed) return;
    publish(sess, s, s.timeline.step(projection));
  } catch (err) {
    // A failed read: the stream reports a dropped connection itself. The read is
    // tried again, since an idle thread may send nothing that would prompt one.
    if (!s.disposed) {
      s.hooks.onConnection(err instanceof Error ? err.message : String(err));
      if (reading) {
        s.readNext = true;
        retryLater(s, () => scheduleStep(sess, s, 0));
      }
    }
  } finally {
    s.stepping = false;
    if (s.stepAgain && !s.disposed) { s.stepAgain = false; scheduleStep(sess, s, REFRESH_DEBOUNCE_MS); }
  }
}

function publish(sess: SessionCtx, s: T3State, step: T3Step) {
  emitStep(sess, step.events, step.reset || !s.synced);
  s.synced = true;
  s.hooks.onConnection(null);
  s.activeRunId = step.activeRunId;
  s.backgroundStop = step.backgroundStop;
  sess.setStatus(step.status);
  s.hooks.onTitle(step.title);
  if (step.cwd) s.hooks.onCwd(step.cwd);
  const modelSelection = step.modelSelection ?? null;
  if (JSON.stringify(modelSelection) !== JSON.stringify(s.modelSelection)) {
    s.modelSelection = modelSelection;
    s.hooks.onModel(modelSelection);
  }
  if (JSON.stringify(step.request) !== JSON.stringify(s.request)) {
    s.request = step.request;
    s.hooks.onRequest(step.request);
  }
  if (JSON.stringify(step.background) !== JSON.stringify(s.background)) {
    s.background = step.background;
    s.hooks.onBackground(step.background);
  }
}

/** Sends one step's events: the whole history at once on the first read or a
 * rollback (no empty flash), otherwise as one batch. */
export function emitStep(sess: SessionCtx, events: AgentEvent[], replace: boolean) {
  if (replace && sess.replaceHistory) sess.replaceHistory(events);
  else if (sess.emitAll) sess.emitAll(events);
  else {
    if (replace) sess.resetHistory?.();
    for (const evt of events) sess.emit(evt);
  }
}

// MARK: - Retries

/** Chats waiting to resubscribe, and when. One timer serves them all, so
 * chats that lost T3 together retry together and share one sign-in. */
const waiting = new Map<T3State, { due: number; resume: () => void }>();
let retryTimer: ReturnType<typeof setTimeout> | undefined;

/** The wait after a chat's next failure: 1 s, doubling to 30 s, back to 1 s once the stream delivers. */
export function nextRetryDelay(previous: number | undefined): number {
  return previous === undefined ? RETRY_MIN_MS : Math.min(RETRY_MAX_MS, previous * 2);
}

function retryLater(s: T3State, resume: () => void) {
  if (s.disposed) return;
  s.retryDelay = nextRetryDelay(s.retryDelay);
  waiting.set(s, { due: Date.now() + s.retryDelay, resume });
  armRetryTimer();
}

function armRetryTimer() {
  if (retryTimer) clearTimeout(retryTimer);
  retryTimer = undefined;
  if (!waiting.size) return;
  let due = Infinity;
  for (const entry of waiting.values()) due = Math.min(due, entry.due);
  retryTimer = setTimeout(() => {
    retryTimer = undefined;
    // Chats due within a moment go in this round too.
    const now = Date.now() + 250;
    for (const [s, entry] of waiting) {
      if (entry.due > now) continue;
      waiting.delete(s);
      if (!s.disposed) entry.resume();
    }
    armRetryTimer();
  }, Math.max(0, due - Date.now()));
}

function wakeWaitingSessions() {
  if (!waiting.size) return;
  const now = Date.now();
  for (const entry of waiting.values()) entry.due = now;
  armRetryTimer();
}

// MARK: - New threads

const STATE_DB = join(process.env.T3CODE_HOME || join(homedir(), ".t3"), "userdata", "statev2.sqlite");

export type { T3LaunchDefaults, T3ModelOption, T3ModelProvider, T3Project } from "../t3-contract";

export const T3_RUNTIME_MODES = ["approval-required", "auto-accept-edits", "auto", "full-access"] as const;
export const T3_INTERACTION_MODES = ["default", "plan"] as const;

function withStateDb<T>(read: (db: import("bun:sqlite").Database) => T): T {
  const { Database } = require("bun:sqlite") as typeof import("bun:sqlite");
  const db = new Database(STATE_DB, { readonly: true });
  try {
    return read(db);
  } finally {
    db.close();
  }
}

function parseJson(text: string | null | undefined): any {
  if (!text) return null;
  try { return JSON.parse(text); } catch { return null; }
}

/** Projects with their default model and their latest thread's settings, in one
 * statement: the latest thread is an index seek on (project_id, updated_at), and
 * only its payload is parsed, for the three fields read. */
const PROJECT_DEFAULTS_SQL = `
  SELECT p.project_id, p.title, p.workspace_root, p.default_model_selection_json,
    json_extract(t.payload_json, '$.modelSelection') AS thread_model_json,
    json_extract(t.payload_json, '$.runtimeMode') AS runtime_mode,
    json_extract(t.payload_json, '$.interactionMode') AS interaction_mode
  FROM projection_projects p
  LEFT JOIN orchestration_v2_projection_threads t ON t.thread_id = (
    SELECT thread_id FROM orchestration_v2_projection_threads
    WHERE project_id = p.project_id AND deleted_at IS NULL ORDER BY updated_at DESC LIMIT 1)`;

interface ProjectDefaultsRow {
  project_id: string;
  title: string | null;
  workspace_root: string | null;
  default_model_selection_json: string | null;
  thread_model_json: string | null;
  runtime_mode: string | null;
  interaction_mode: string | null;
}

function launchDefaultsOf(row: ProjectDefaultsRow): T3LaunchDefaults {
  return {
    modelSelection: parseJson(row.default_model_selection_json) ?? parseJson(row.thread_model_json) ?? null,
    runtimeMode: row.runtime_mode ?? "full-access",
    interactionMode: row.interaction_mode ?? "default",
  };
}

/** Every T3 project that isn't deleted, by name, with what a new thread there starts with. */
export function t3Projects(): T3Project[] {
  return withStateDb((db) => {
    const rows = db.query(`${PROJECT_DEFAULTS_SQL} WHERE p.deleted_at IS NULL ORDER BY p.title COLLATE NOCASE`).all() as ProjectDefaultsRow[];
    return rows.map((row) => ({
      id: row.project_id,
      name: row.title ?? "",
      root: row.workspace_root ?? "",
      defaults: launchDefaultsOf(row),
    }));
  });
}

function launchDefaults(projectId: string): T3LaunchDefaults {
  return withStateDb((db) => {
    const row = db.query(`${PROJECT_DEFAULTS_SQL} WHERE p.project_id = ?`).get(projectId) as ProjectDefaultsRow | null;
    return row ? launchDefaultsOf(row) : { modelSelection: null, runtimeMode: "full-access", interactionMode: "default" };
  });
}

/** Starts a new T3 thread in a project with a first message; T3 names it.
 * Settings left out come from the project, as in ``launchDefaults``. */
export async function launchT3Thread(input: {
  projectId: string;
  text: string;
  runtimeMode?: string;
  interactionMode?: string;
  modelSelection?: T3ModelSelection;
}): Promise<{ threadId: string }> {
  const text = input.text.trim();
  if (!text) throw new Error("Type what the agent should do.");
  // The defaults are read only for settings the composer left out.
  const defaults = input.modelSelection && input.runtimeMode && input.interactionMode
    ? null
    : launchDefaults(input.projectId);
  const modelSelection = input.modelSelection ?? defaults?.modelSelection;
  if (!modelSelection) throw new Error("Pick a model for this chat; the project has no default and no earlier threads.");
  const firstLine = text.split("\n").find((line) => line.trim())?.trim() ?? text;
  const result = await run<{ threadId: string }>((client) => client["orchestration.launchThread"]({
    commandId: crypto.randomUUID(),
    creationSource: "web",
    projectId: input.projectId,
    title: firstLine.length > 60 ? `${firstLine.slice(0, 59)}…` : firstLine,
    generateTitle: true,
    modelSelection,
    runtimeMode: input.runtimeMode ?? defaults?.runtimeMode ?? "full-access",
    interactionMode: input.interactionMode ?? defaults?.interactionMode ?? "default",
    workspaceStrategy: { type: "root" },
    initialMessage: { text, attachments: [] },
  }));
  return { threadId: String(result.threadId) };
}

/** Answers the thread's pending approval in T3. */
export async function respondT3Request(sess: SessionCtx, requestId: string, decision: T3Decision) {
  await dispatch({ type: "runtime-request.respond", threadId: threadIdOf(sess), requestId, decision });
}

/** Answers the thread's pending questions in T3: question id to an option value, values, or typed text. */
export async function answerT3Question(sess: SessionCtx, requestId: string, answers: T3Answers) {
  await dispatch({ type: "runtime-request.respond", threadId: threadIdOf(sess), requestId, answers });
}

/** Skips the thread's pending questions without answering. */
export async function dismissT3Question(sess: SessionCtx, requestId: string) {
  await dispatch({ type: "thread.user-input.dismiss", threadId: threadIdOf(sess), requestId });
}

/** Changes the thread's model in T3; T3 applies it from the next message. */
export async function setT3Model(sess: SessionCtx, selection: { instanceId: string; model: string; options?: { id: string; value: string | boolean }[] }) {
  await dispatch({ type: "thread.model-selection.set", threadId: threadIdOf(sess), modelSelection: selection });
}

/** Thread actions Agent Home's sidebar sends: settle (mark verified), unsettle (undo), visit (seen). */
export type T3ThreadAction = "settle" | "unsettle" | "visit";

export async function t3ThreadAction(threadId: string, action: T3ThreadAction) {
  if (action === "settle") await dispatch({ type: "thread.settle", threadId });
  else if (action === "unsettle") await dispatch({ type: "thread.unsettle", threadId, reason: "user" });
  else await dispatch({ type: "thread.visit", threadId, visitedAt: new Date().toISOString() });
}

export function t3BackgroundWork(sess: SessionCtx): T3BackgroundWork | null {
  return state(sess)?.background ?? null;
}

export function t3ModelSelection(sess: SessionCtx): T3ModelSelection | null {
  return state(sess)?.modelSelection ?? null;
}

function threadIdOf(sess: SessionCtx): string {
  const s = state(sess);
  if (!s) throw new Error("not a T3 thread");
  return s.threadId;
}

// MARK: - Models

const CATALOG_TTL_MS = 60_000;
let catalogCache: { at: number; providers: Promise<T3ModelProvider[]> } | undefined;

/** The providers and models T3 can run right now, as T3's own model picker lists them. */
export function t3ModelCatalog(): Promise<T3ModelProvider[]> {
  if (catalogCache && Date.now() - catalogCache.at < CATALOG_TTL_MS) return catalogCache.providers;
  const providers = run<{ providers: any[] }>((client) => client["server.getConfig"]({})).then((config) =>
    (config.providers ?? [])
      .filter((p) => p.enabled !== false && p.installed !== false && p.status === "ready" && p.models?.length)
      .map((p): T3ModelProvider => ({
        instanceId: String(p.instanceId),
        driver: String(p.driver ?? p.instanceId),
        name: String(p.displayName ?? p.instanceId),
        models: p.models.map((m: any) => ({
          slug: String(m.slug),
          name: String(m.name ?? m.slug),
          ...(m.isDefault ? { isDefault: true } : {}),
          options: (m.capabilities?.optionDescriptors ?? [])
            .filter((d: any) => d.type === "select" || d.type === "boolean")
            .map((d: any): T3ModelOption => ({
              id: String(d.id),
              label: String(d.label ?? d.id),
              type: d.type,
              ...(d.type === "select" ? {
                choices: (d.options ?? []).map((o: any) => ({
                  id: String(o.id),
                  label: String(o.label ?? o.id),
                  ...(o.description ? { description: String(o.description) } : {}),
                  ...(o.isDefault ? { isDefault: true } : {}),
                })),
              } : {}),
            })),
        })),
      })));
  catalogCache = { at: Date.now(), providers };
  providers.catch(() => { if (catalogCache?.providers === providers) catalogCache = undefined; });
  return providers;
}

export const t3Adapter: Adapter = {
  async send(sess, prompt) {
    const s = state(sess);
    if (!s) throw new Error("not a T3 thread");
    await dispatch({
      type: "message.dispatch",
      createdBy: "user",
      creationSource: "web",
      threadId: s.threadId,
      messageId: crypto.randomUUID(),
      text: prompt,
      attachments: [],
      // Like T3's composer: start now when idle, otherwise wait for the active run.
      dispatchMode: s.activeRunId ? { type: "queue_after_active" } : { type: "start_immediately" },
    });
  },
  stop(sess) {
    const s = state(sess);
    if (!s) return;
    const fail = (err: unknown) => s.hooks.onError(err instanceof Error ? err.message : String(err));
    // Like T3's Stop: the active run, else the run that owns the background work, else the pull request watches.
    const runId = s.activeRunId ?? s.backgroundStop?.runId;
    if (runId) {
      void dispatch({ type: "run.interrupt", threadId: s.threadId, runId }).catch(fail);
      return;
    }
    for (const pr of s.backgroundStop?.pullRequests ?? []) {
      void dispatch({ type: "thread.pull-request.watch", threadId: s.threadId, ...pr, watching: false }).catch(fail);
    }
  },
  dispose(sess) {
    const s = state(sess);
    if (!s) return;
    s.disposed = true;
    if (s.stepTimer) clearTimeout(s.stepTimer);
    waiting.delete(s);
    s.subscription?.interrupt();
  },
  async setOption() {
    throw new Error("Change models and settings for this thread in T3.");
  },
  capabilities: { options: [], triggers: [] },
};



// MARK: - Usage

/** One provider's rate-limit windows, as T3's Limits view shows them. */
export interface T3UsageLimits {
  instanceId: string;
  driver: string;
  name: string;
  email?: string;
  plan?: string;
  /** The account's config folder; the spend summary's `sourcePath`s sit under it. */
  homePath?: string;
  checkedAt?: string;
  windows: { id: string; kind: string; label: string; usedPercent: number; resetsAt?: string; windowDurationMins?: number }[];
  unavailable?: { reason: string; message?: string };
  externalUsage?: { label: string; url: string };
}

/** What cmux shows for provider usage: limits always, spend when the token may read it. */
export interface T3UsageReport {
  limits: T3UsageLimits[];
  summary: unknown | null;
  summaryError?: string;
}

/** The providers' rate-limit windows and, when allowed, token use and cost by day.
 *
 * Limits come with `server.getConfig`, which the orchestration token can read.
 * The spend summary (`server.getUsageSummary`) needs the `diagnostics:read`
 * scope; without it the report says so instead of failing. */
export async function t3Usage(input: {
  sinceDay: string;
  untilDay: string;
  timeZone: string;
  resolution?: "day" | "hour";
  sinceTime?: string;
  untilTime?: string;
}): Promise<T3UsageReport> {
  const readSummary = () => run<unknown>((client) => client["server.getUsageSummary"](input)).then(
    (value) => ({ value, error: undefined as string | undefined }),
    (err) => ({ value: null, error: t3UsageError(err) }),
  );
  let [config, summary] = await Promise.all([
    run<{ providers: any[] }>((client) => client["server.getConfig"]({})),
    readSummary(),
  ]);
  // The scope belongs to the token the socket signed in with, so after the
  // user issues a new one with diagnostics:read, sign in again to use it.
  if (summary.error === "needsDiagnosticsScope") {
    const conn = await connection();
    if (readToken({ fresh: true }) !== conn.token) {
      dropConnection(conn);
      summary = await readSummary();
    }
  }
  const instances = (config as { settings?: { providerInstances?: Record<string, { config?: { homePath?: unknown } }> } })
    .settings?.providerInstances ?? {};
  const limits = (config.providers ?? [])
    .filter((p) => p.enabled !== false && p.installed !== false && p.availability !== "unavailable" && p.usageLimits)
    .map((p): T3UsageLimits => {
      const homePath = homePathOf(p, instances);
      return {
        instanceId: String(p.instanceId),
        driver: String(p.driver ?? p.instanceId),
        name: String(p.displayName ?? p.instanceId),
        ...(p.auth?.email ? { email: String(p.auth.email) } : {}),
        ...(p.auth?.type && p.auth.type !== "apiKey" ? { plan: String(p.auth.type) } : {}),
        ...(homePath ? { homePath } : {}),
        checkedAt: p.usageLimits.checkedAt,
        windows: (p.usageLimits.windows ?? []).map((w: any) => ({
          id: String(w.id),
          kind: String(w.kind),
          label: String(w.label),
          usedPercent: Number(w.usedPercent) || 0,
          ...(w.resetsAt ? { resetsAt: String(w.resetsAt) } : {}),
          ...(typeof w.windowDurationMins === "number" ? { windowDurationMins: w.windowDurationMins } : {}),
        })),
        ...(p.usageLimits.unavailable ? { unavailable: p.usageLimits.unavailable } : {}),
        ...(p.usageLimits.externalUsage ? { externalUsage: p.usageLimits.externalUsage } : {}),
      };
    });
  return { limits, summary: summary.value, ...(summary.error ? { summaryError: summary.error } : {}) };
}

/** Where a provider instance keeps its transcripts: its configured home, else the driver's default. */
function homePathOf(provider: any, instances: Record<string, { config?: { homePath?: unknown } }>): string | undefined {
  const configured = instances[String(provider.instanceId)]?.config?.homePath;
  if (typeof configured === "string" && configured.trim()) return configured.trim().replace(/^~(?=\/|$)/, homedir());
  if (typeof provider.runtimePaths?.homePath === "string") return provider.runtimePaths.homePath;
  if (provider.instanceId === "claudeAgent") return process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
  if (provider.instanceId === "codex") return process.env.CODEX_HOME || join(homedir(), ".codex");
  return undefined;
}

function t3UsageError(err: unknown): string {
  const tag = (err as { _tag?: string })?._tag ?? "";
  const text = err instanceof Error ? err.message : String(err);
  if (tag === "EnvironmentAuthorizationError" || /scope|authoriz|forbidden/i.test(text)) return "needsDiagnosticsScope";
  return text.slice(0, 300);
}
