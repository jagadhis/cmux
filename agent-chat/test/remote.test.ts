import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { handleRemoteFetchForTest } from "../server";
import { loadOrCreateRemoteToken, phoneUrl, remoteConfig, remoteHostTrusted, remoteOriginTrusted } from "../remote";
import { readOpenT3Threads, threadState } from "../adapters/t3-threads";
import { ago, groupThreads, type HomeThread } from "../src/components/Home";

const TOKEN = "a".repeat(43);
const HOST = "my-mac.tail1234.ts.net";

function request(path: string, headers: Record<string, string> = {}): Request {
  return new Request(`http://127.0.0.1:7740${path}`, { headers: { host: HOST, ...headers } });
}

describe("phone access settings", () => {
  test("off unless asked for", () => {
    expect(remoteConfig([], {})).toBeNull();
  });

  test("--remote or the env var turns it on, on 7740 by default", () => {
    expect(remoteConfig(["--remote"], { HOME: "/h" })).toEqual({ port: 7740, tokenFile: "/h/.config/cmux/agent-chat-remote.json", extraHosts: [] });
    expect(remoteConfig([], { CMUX_AGENT_CHAT_REMOTE: "1", CMUX_AGENT_CHAT_REMOTE_PORT: "9000", HOME: "/h" })?.port).toBe(9000);
    expect(remoteConfig(["--remote", "--remote-port=7999"], { HOME: "/h" })?.port).toBe(7999);
  });

  test("extra hosts are lowercased and trimmed", () => {
    expect(remoteConfig(["--remote"], { CMUX_AGENT_CHAT_REMOTE_HOSTS: " Chat.Example.com ,", HOME: "/h" })?.extraHosts).toEqual(["chat.example.com"]);
  });

  test("a bad port is refused", () => {
    expect(() => remoteConfig(["--remote", "--remote-port", "nope"], {})).toThrow();
  });
});

describe("phone token", () => {
  test("made once, kept private, then reused", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-chat-remote-"));
    try {
      const file = join(dir, "nested", "agent-chat-remote.json");
      const token = loadOrCreateRemoteToken(file);
      expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(statSync(file).mode & 0o777).toBe(0o600);
      expect(loadOrCreateRemoteToken(file)).toBe(token);
      expect(JSON.parse(readFileSync(file, "utf8")).token).toBe(token);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a damaged file gets a new token", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-chat-remote-"));
    try {
      const file = join(dir, "agent-chat-remote.json");
      writeFileSync(file, JSON.stringify({ token: "short" }));
      expect(loadOrCreateRemoteToken(file)).toMatch(/^[A-Za-z0-9_-]{43}$/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the phone link opens the home page", () => {
    expect(phoneUrl(HOST, TOKEN)).toBe(`https://${HOST}/${TOKEN}/home`);
  });
});

describe("who may reach the phone listener", () => {
  test("hosts: loopback, tailnet names and listed hosts only", () => {
    expect(remoteHostTrusted("127.0.0.1:7740")).toBe(true);
    expect(remoteHostTrusted(HOST)).toBe(true);
    expect(remoteHostTrusted("chat.example.com", ["chat.example.com"])).toBe(true);
    expect(remoteHostTrusted("evil.example.com")).toBe(false);
    expect(remoteHostTrusted("ts.net.evil.example.com")).toBe(false);
    expect(remoteHostTrusted(null)).toBe(false);
  });

  test("origins: none, or the page's own https address", () => {
    expect(remoteOriginTrusted(null, HOST)).toBe(true);
    expect(remoteOriginTrusted(`https://${HOST}`, HOST)).toBe(true);
    expect(remoteOriginTrusted(`http://${HOST}`, HOST)).toBe(false);
    expect(remoteOriginTrusted("https://evil.example.com", HOST)).toBe(false);
    expect(remoteOriginTrusted("http://127.0.0.1:7740", "127.0.0.1:7740")).toBe(true);
  });
});

describe("phone listener routes", () => {
  test("pages need the phone token", async () => {
    expect((await handleRemoteFetchForTest(request("/home"), TOKEN))?.status).toBe(404);
    expect((await handleRemoteFetchForTest(request(`/${"b".repeat(43)}/home`), TOKEN))?.status).toBe(404);
  });

  test("a page from another host is refused before anything else", async () => {
    const res = await handleRemoteFetchForTest(request(`/${TOKEN}/home`, { host: "evil.example.com" }), TOKEN);
    expect(res?.status).toBe(403);
  });

  test("the home page is installable and knows it's on the phone", async () => {
    const res = await handleRemoteFetchForTest(request(`/${TOKEN}/home`), TOKEN);
    expect(res?.status).toBe(200);
    const html = await res!.text();
    expect(html).toContain("window.__AGENT_CHAT_REMOTE__=true;");
    expect(html).toContain(`window.__AGENT_CHAT_BASE__="/${TOKEN}"`);
    expect(html).toContain('<link rel="manifest" href="manifest.webmanifest">');
    expect(html).toContain("viewport-fit=cover");
  });

  test("the manifest starts at home, under the token", async () => {
    const res = await handleRemoteFetchForTest(request(`/${TOKEN}/manifest.webmanifest`), TOKEN);
    const manifest = await res!.json();
    expect(manifest.start_url).toBe("home");
    expect(manifest.scope).toBe("./");
    expect(manifest.display).toBe("standalone");
  });

  test("the socket refuses another site's page", async () => {
    const res = await handleRemoteFetchForTest(request(`/${TOKEN}/ws`, { origin: "https://evil.example.com" }), TOKEN);
    expect(res?.status).toBe(403);
  });
});

function fixtureDb(): Database {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE projection_projects (project_id TEXT, title TEXT, workspace_root TEXT, deleted_at TEXT);
    CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, project_id TEXT, title TEXT, updated_at TEXT, payload_json TEXT, archived_at TEXT, deleted_at TEXT);
    CREATE TABLE orchestration_v2_projection_runs (thread_id TEXT, ordinal INTEGER, status TEXT, completed_at TEXT);
    CREATE TABLE orchestration_v2_projection_runtime_requests (thread_id TEXT, status TEXT);
    INSERT INTO projection_projects VALUES ('p1', 'cmux', '/x', NULL);
  `);
  const thread = db.query("INSERT INTO orchestration_v2_projection_threads VALUES (?, 'p1', ?, ?, ?, NULL, NULL)");
  const run = db.query("INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?)");
  thread.run("asks", "Asks a question", "2026-10-21T10:05:00Z", "{}");
  run.run("asks", 1, "waiting", null);
  db.query("INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('asks', 'pending')").run();
  thread.run("works", "Working", "2026-10-21T10:04:00Z", JSON.stringify({ branch: "feat/x" }));
  run.run("works", 1, "completed", "2026-10-21T09:00:00Z");
  run.run("works", 2, "running", null);
  thread.run("child", "Sub-agent", "2026-10-21T10:03:00Z", JSON.stringify({ lineage: { rootThreadId: "works" } }));
  run.run("child", 1, "completed", "2026-10-21T10:03:00Z");
  thread.run("seen", "Finished, seen", "2026-10-21T10:02:00Z", JSON.stringify({ lastVisitedAt: "2026-10-21T10:01:00Z" }));
  run.run("seen", 1, "completed", "2026-10-21T10:00:00Z");
  thread.run("settled", "Settled", "2026-10-21T10:01:00Z", JSON.stringify({ settledOverride: "settled" }));
  run.run("settled", 1, "completed", "2026-10-21T10:00:00Z");
  thread.run("snoozed", "Snoozed", "2026-10-21T10:00:00Z", JSON.stringify({ snoozedUntil: "2999-01-01T00:00:00Z" }));
  return db;
}

describe("open T3 threads", () => {
  test("listed as Agent Home lists them, with their state", () => {
    const db = fixtureDb();
    const threads = readOpenT3Threads(db);
    expect(threads.map((t) => [t.id, t.state])).toEqual([
      ["asks", "needs-input"],
      ["works", "running"],
      ["child", "unread"],
      ["seen", "idle"],
    ]);
    expect(threads.find((t) => t.id === "child")?.rootThreadId).toBe("works");
    expect(threads.find((t) => t.id === "works")?.branch).toBe("feat/x");
    expect(threads[0].projectName).toBe("cmux");
  });

  test("a settled task still shows while it works or asks", () => {
    const db = fixtureDb();
    db.query("INSERT INTO orchestration_v2_projection_runs VALUES ('settled', 2, 'running', NULL)").run();
    expect(readOpenT3Threads(db).map((t) => t.id)).toContain("settled");
  });

  test("state precedence", () => {
    const base = { pending: 0, runStatus: null, subagentStatus: null, runCompletedAt: null, lastVisitedAt: null };
    expect(threadState({ ...base, pending: 1, runStatus: "running" })).toBe("needs-input");
    expect(threadState({ ...base, subagentStatus: "running" })).toBe("running");
    expect(threadState({ ...base, runCompletedAt: "2026-10-21T10:00:00Z" })).toBe("unread");
    expect(threadState({ ...base, runCompletedAt: "2026-10-21T10:00:00Z", lastVisitedAt: "2026-10-21T11:00:00Z" })).toBe("idle");
    expect(threadState(base)).toBe("idle");
  });
});

describe("home page grouping", () => {
  const t = (id: string, state: HomeThread["state"], rootThreadId: string | null = null, projectId = "p1"): HomeThread => ({
    id, title: id, projectId, projectName: projectId, rootThreadId, state, branch: null, updatedAt: "2026-10-21T10:00:00Z",
  });

  test("sub-threads sit under their task, which takes their most urgent state", () => {
    const projects = groupThreads([t("child", "needs-input", "root"), t("root", "idle"), t("other", "running", null, "p2")]);
    expect(projects.map((p) => p.id)).toEqual(["p1", "p2"]);
    expect(projects[0].tasks).toHaveLength(1);
    expect(projects[0].tasks[0].root.id).toBe("root");
    expect(projects[0].tasks[0].children.map((c) => c.id)).toEqual(["child"]);
    expect(projects[0].tasks[0].state).toBe("needs-input");
  });

  test("a sub-thread whose task isn't listed stands on its own", () => {
    const projects = groupThreads([t("orphan", "idle", "gone")]);
    expect(projects[0].tasks[0].root.id).toBe("orphan");
  });

  test("relative times", () => {
    const now = Date.parse("2026-10-21T12:00:00Z");
    expect(ago("2026-10-21T12:00:00Z", now)).toBe("now");
    expect(ago("2026-10-21T11:55:00Z", now)).toBe("5m");
    expect(ago("2026-10-21T09:00:00Z", now)).toBe("3h");
    expect(ago("2026-10-19T12:00:00Z", now)).toBe("2d");
    expect(ago("nope", now)).toBe("");
  });
});
