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

import { homedir } from "node:os";
import { join } from "node:path";
import type { Adapter, SessionCtx } from "../types";
import { T3Timeline, type T3ModelSelection, type T3PendingRequest, type T3Projection } from "./t3-timeline";

const T3CODE_DIR = process.env.CMUX_T3CODE_DIR || join(homedir(), "projects", "t3code");
const RUNTIME_FILE = join(process.env.T3CODE_HOME || join(homedir(), ".t3"), "userdata", "server-runtime.json");
const KEYCHAIN_SERVICE = process.env.CMUX_T3_TOKEN_SERVICE || "cmux-agent-home-t3-token";
const REFRESH_DEBOUNCE_MS = 120;

/** Callbacks the server gives each T3 session. */
export interface T3SessionHooks {
  onTitle(title: string): void;
  onCwd(cwd: string): void;
  onRequest(request: T3PendingRequest | null): void;
  onModel(selection: T3ModelSelection | null): void;
  onError(message: string): void;
}

interface T3State {
  threadId: string;
  timeline: T3Timeline;
  activeRunId?: string;
  request: T3PendingRequest | null;
  modelSelection: T3ModelSelection | null;
  hooks: T3SessionHooks;
  subscription?: { interrupt(): void };
  refreshTimer?: ReturnType<typeof setTimeout>;
  refreshing?: boolean;
  refreshAgain?: boolean;
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

function readToken(): string {
  const result = Bun.spawnSync(["security", "find-generic-password", "-a", process.env.USER ?? "", "-s", KEYCHAIN_SERVICE, "-w"]);
  const token = result.stdout.toString().trim();
  if (!token) {
    throw new Error(
      `No T3 token in the Keychain (${KEYCHAIN_SERVICE}). Issue one with: t3 auth session issue --scope orchestration:read --scope orchestration:operate --label "cmux Agent Home" --token-only`,
    );
  }
  return token;
}

interface Connection {
  client: any;
  holder: any;
  closed: boolean;
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
    const ticketResponse = await fetch(new URL("/api/auth/websocket-ticket", runtime.origin), {
      method: "POST",
      headers: { authorization: `Bearer ${readToken()}` },
    });
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
    const conn: Connection = { client: undefined, holder: undefined, closed: false };
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
  const s: T3State = { threadId, timeline: new T3Timeline(), request: null, modelSelection: null, hooks };
  sess.internal.t3 = s;
  void subscribe(sess, s);
}

async function subscribe(sess: SessionCtx, s: T3State) {
  try {
    const [m, conn] = await Promise.all([effectModules(), connection()]);
    if (s.disposed) return;
    await refresh(sess, s);
    const fiber = m.Effect.runFork(m.Stream.runForEach(
      conn.client["orchestration.subscribeThread"]({ threadId: s.threadId }),
      () => m.Effect.sync(() => scheduleRefresh(sess, s)),
    ));
    s.subscription = { interrupt: () => m.Effect.runFork(m.Fiber.interrupt(fiber)) };
    fiber.addObserver?.(() => {
      if (s.disposed) return;
      // The stream ended (T3 restarted or the socket dropped): sign in again and resubscribe.
      dropConnection(conn);
      setTimeout(() => { if (!s.disposed) void subscribe(sess, s); }, 1_000);
    });
  } catch (err) {
    if (s.disposed) return;
    s.hooks.onError(err instanceof Error ? err.message : String(err));
    setTimeout(() => { if (!s.disposed) void subscribe(sess, s); }, 5_000);
  }
}

function scheduleRefresh(sess: SessionCtx, s: T3State) {
  if (s.refreshTimer) return;
  s.refreshTimer = setTimeout(() => {
    s.refreshTimer = undefined;
    void refresh(sess, s);
  }, REFRESH_DEBOUNCE_MS);
}

/** Reads the thread and emits what changed. Runs one at a time; a change during a read reads again. */
async function refresh(sess: SessionCtx, s: T3State) {
  if (s.refreshing) { s.refreshAgain = true; return; }
  s.refreshing = true;
  try {
    const projection = await run<T3Projection>((client) =>
      client["orchestration.getThreadProjection"]({ threadId: s.threadId }));
    if (s.disposed) return;
    const step = s.timeline.step(projection);
    if (step.reset) sess.resetHistory?.();
    for (const evt of step.events) sess.emit(evt);
    s.activeRunId = step.activeRunId;
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
  } catch (err) {
    if (!s.disposed) s.hooks.onError(err instanceof Error ? err.message : String(err));
  } finally {
    s.refreshing = false;
    if (s.refreshAgain && !s.disposed) { s.refreshAgain = false; scheduleRefresh(sess, s); }
  }
}

// MARK: - New threads

const STATE_DB = join(process.env.T3CODE_HOME || join(homedir(), ".t3"), "userdata", "statev2.sqlite");

/** The settings a new thread in this project starts with: the project's
 * default model, else the project's most recent thread's model and modes. */
function launchDefaults(projectId: string): { modelSelection: unknown; runtimeMode: string; interactionMode: string } {
  const { Database } = require("bun:sqlite") as typeof import("bun:sqlite");
  const db = new Database(STATE_DB, { readonly: true });
  try {
    const project = db.query("SELECT default_model_selection_json FROM projection_projects WHERE project_id = ?").get(projectId) as
      | { default_model_selection_json: string | null }
      | null;
    const latest = db.query(
      "SELECT payload_json FROM orchestration_v2_projection_threads WHERE project_id = ? AND deleted_at IS NULL ORDER BY updated_at DESC LIMIT 1",
    ).get(projectId) as { payload_json: string } | null;
    const payload = latest ? JSON.parse(latest.payload_json) : {};
    const projectModel = project?.default_model_selection_json ? JSON.parse(project.default_model_selection_json) : null;
    const modelSelection = projectModel ?? payload.modelSelection;
    if (!modelSelection) throw new Error("Pick a model for this project in T3 first; it has no default and no earlier threads.");
    return {
      modelSelection,
      runtimeMode: payload.runtimeMode ?? "full-access",
      interactionMode: payload.interactionMode ?? "default",
    };
  } finally {
    db.close();
  }
}

/** Starts a new T3 thread in a project with a first message; T3 names it. */
export async function launchT3Thread(input: { projectId: string; text: string; runtimeMode?: string }): Promise<{ threadId: string }> {
  const text = input.text.trim();
  if (!text) throw new Error("Type what the agent should do.");
  const defaults = launchDefaults(input.projectId);
  const firstLine = text.split("\n").find((line) => line.trim())?.trim() ?? text;
  const result = await run<{ threadId: string }>((client) => client["orchestration.launchThread"]({
    commandId: crypto.randomUUID(),
    creationSource: "web",
    projectId: input.projectId,
    title: firstLine.length > 60 ? `${firstLine.slice(0, 59)}…` : firstLine,
    generateTitle: true,
    modelSelection: defaults.modelSelection,
    runtimeMode: input.runtimeMode ?? defaults.runtimeMode,
    interactionMode: defaults.interactionMode,
    workspaceStrategy: { type: "root" },
    initialMessage: { text, attachments: [] },
  }));
  return { threadId: String(result.threadId) };
}

/** Answers the thread's pending approval in T3. */
export async function respondT3Request(sess: SessionCtx, requestId: string, decision: "accept" | "acceptForSession" | "decline") {
  await dispatch({ type: "runtime-request.respond", threadId: threadIdOf(sess), requestId, decision });
}

/** Answers the thread's pending questions in T3: question id to an option value, values, or typed text. */
export async function answerT3Question(sess: SessionCtx, requestId: string, answers: Record<string, string | string[]>) {
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

export function t3ModelSelection(sess: SessionCtx): T3ModelSelection | null {
  return state(sess)?.modelSelection ?? null;
}

function threadIdOf(sess: SessionCtx): string {
  const s = state(sess);
  if (!s) throw new Error("not a T3 thread");
  return s.threadId;
}

// MARK: - Models

/** A model option T3 offers, e.g. reasoning effort or fast mode. */
export interface T3ModelOption {
  id: string;
  label: string;
  type: "select" | "boolean";
  choices?: { id: string; label: string; description?: string; isDefault?: boolean }[];
}

export interface T3ModelProvider {
  instanceId: string;
  driver: string;
  name: string;
  models: { slug: string; name: string; isDefault?: boolean; options: T3ModelOption[] }[];
}

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
    if (!s?.activeRunId) return;
    void dispatch({ type: "run.interrupt", threadId: s.threadId, runId: s.activeRunId })
      .catch((err) => s.hooks.onError(err instanceof Error ? err.message : String(err)));
  },
  dispose(sess) {
    const s = state(sess);
    if (!s) return;
    s.disposed = true;
    if (s.refreshTimer) clearTimeout(s.refreshTimer);
    s.subscription?.interrupt();
  },
  async setOption() {
    throw new Error("Change models and settings for this thread in T3.");
  },
  capabilities: { options: [], triggers: [] },
};


