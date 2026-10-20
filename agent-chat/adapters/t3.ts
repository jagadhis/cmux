// Chat source for T3 Code threads (cmux Agent Home).
//
// T3 Code runs the agent; this view is another T3 client. It connects to the
// local T3 server over T3's own WebSocket RPC, using the protocol modules
// from a local T3 Code checkout (`CMUX_T3CODE_DIR`, default ~/projects/t3code)
// so the wire format always matches. The bearer token comes from the macOS
// Keychain item `cmux-agent-home-t3-token`, issued once with
// `t3 auth session issue --scope orchestration:read --scope orchestration:operate`.
//
// Sends, stops and approvals are T3 commands, so they show up in T3 too.

import { homedir } from "node:os";
import { join } from "node:path";
import type { Adapter, SessionCtx } from "../types";
import { T3Timeline, type T3PendingRequest, type T3Projection } from "./t3-timeline";

const T3CODE_DIR = process.env.CMUX_T3CODE_DIR || join(homedir(), "projects", "t3code");
const RUNTIME_FILE = join(process.env.T3CODE_HOME || join(homedir(), ".t3"), "userdata", "server-runtime.json");
const KEYCHAIN_SERVICE = process.env.CMUX_T3_TOKEN_SERVICE || "cmux-agent-home-t3-token";
const REFRESH_DEBOUNCE_MS = 120;

/** Callbacks the server gives each T3 session. */
export interface T3SessionHooks {
  onTitle(title: string): void;
  onCwd(cwd: string): void;
  onRequest(request: T3PendingRequest | null): void;
  onError(message: string): void;
}

interface T3State {
  threadId: string;
  timeline: T3Timeline;
  activeRunId?: string;
  request: T3PendingRequest | null;
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
  WsRpcGroup: any;
}

let modulesPromise: Promise<EffectModules> | undefined;
function effectModules(): Promise<EffectModules> {
  modulesPromise ??= (async () => {
    const base = join(T3CODE_DIR, "packages", "client-runtime", "src", "rpc") + "/";
    const load = (m: string) => import(Bun.resolveSync(m, base));
    const [Effect, Layer, Stream, Fiber, RpcClient, RpcSerialization, Socket, contracts] = await Promise.all([
      load("effect/Effect"), load("effect/Layer"), load("effect/Stream"), load("effect/Fiber"),
      load("effect/rpc/RpcClient"), load("effect/rpc/RpcSerialization"), load("effect/socket/Socket"),
      import(join(T3CODE_DIR, "packages", "contracts", "src", "index.ts")),
    ]);
    return { Effect, Layer, Stream, Fiber, RpcClient, RpcSerialization, Socket, WsRpcGroup: contracts.WsRpcGroup };
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

/** The shared connection to the running T3 server, reconnecting after it drops. */
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

    const layer = m.Layer.effect(m.RpcClient.Protocol, m.RpcClient.makeProtocolSocket({})).pipe(
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

async function run<T>(make: (client: any) => any): Promise<T> {
  const [m, conn] = await Promise.all([effectModules(), connection()]);
  return m.Effect.runPromise(make(conn.client));
}

async function dispatch(command: Record<string, unknown>) {
  await run((client) => client["orchestration.dispatchCommand"]({ commandId: crypto.randomUUID(), ...command }));
}

// MARK: - Session wiring

function state(sess: SessionCtx): T3State | undefined {
  return sess.internal.t3 as T3State | undefined;
}

/** Starts mirroring a T3 thread into a chat session. */
export function attachT3Thread(sess: SessionCtx, threadId: string, hooks: T3SessionHooks) {
  const s: T3State = { threadId, timeline: new T3Timeline(), request: null, hooks };
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
      // The stream ended (T3 restarted or the socket dropped): reconnect shortly.
      setTimeout(() => { if (!s.disposed) void subscribe(sess, s); }, 2_000);
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
export async function launchT3Thread(input: { projectId: string; text: string }): Promise<{ threadId: string }> {
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
    runtimeMode: defaults.runtimeMode,
    interactionMode: defaults.interactionMode,
    workspaceStrategy: { type: "root" },
    initialMessage: { text, attachments: [] },
  }));
  return { threadId: String(result.threadId) };
}

/** Answers the thread's pending approval in T3. */
export async function respondT3Request(sess: SessionCtx, requestId: string, decision: "accept" | "acceptForSession" | "decline") {
  const s = state(sess);
  if (!s) throw new Error("not a T3 thread");
  await dispatch({ type: "runtime-request.respond", threadId: s.threadId, requestId, decision });
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
