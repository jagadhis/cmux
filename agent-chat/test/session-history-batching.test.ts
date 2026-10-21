import { describe, expect, test } from "bun:test";
import type { AgentEvent, SessionCtx } from "../types";

const { coalesceStreamedText, emitSessionEventForTest, emitSessionEventsForTest, replaceSessionHistory } = await import("../server");

type ServerSession = Parameters<typeof replaceSessionHistory>[0];

function fakeSession(id: string) {
  const messages: any[] = [];
  const sess = {
    id, provider: "claude", cwd: "/tmp", title: "fixture", status: "idle",
    autoApprove: false, startOptions: {}, events: [], internal: {}, createdAt: 0,
    sockets: new Set([{ send(data: string) { messages.push(JSON.parse(data)); return 1; } }]),
    emit(event: AgentEvent) { emitSessionEventForTest(sess, event); },
    setStatus(status: SessionCtx["status"]) { sess.status = status; },
  } as unknown as ServerSession;
  return { sess, messages };
}

describe("streamed text in the stored history", () => {
  test("consecutive deltas are stored as one event; open views still get each delta", () => {
    const { sess, messages } = fakeSession("coalesce");
    for (const text of ["Hel", "lo", " there"]) emitSessionEventForTest(sess, { kind: "delta", text });
    expect(sess.events).toEqual([{ kind: "delta", text: "Hello there" }]);
    expect(messages.map((m) => m.evt.text)).toEqual(["Hel", "lo", " there"]);
  });

  test("a different kind or anything in between keeps the block boundary", () => {
    const { sess } = fakeSession("boundaries");
    const events: AgentEvent[] = [
      { kind: "thinking", text: "Plan " }, { kind: "thinking", text: "it." },
      { kind: "delta", text: "On " }, { kind: "delta", text: "it." },
      { kind: "tool-start", toolId: "t1", name: "Bash" },
      { kind: "delta", text: "Done" }, { kind: "delta", text: "." },
      { kind: "done" },
      { kind: "delta", text: "Next" },
    ];
    for (const evt of events) emitSessionEventForTest(sess, evt);
    expect(sess.events).toEqual([
      { kind: "thinking", text: "Plan it." },
      { kind: "delta", text: "On it." },
      { kind: "tool-start", toolId: "t1", name: "Bash" },
      { kind: "delta", text: "Done." },
      { kind: "done" },
      { kind: "delta", text: "Next" },
    ]);
  });

  test("deltas from different turn generations stay apart", () => {
    const events: AgentEvent[] = [{ kind: "delta", text: "a" }];
    const generations = [1];
    expect(coalesceStreamedText(events, generations, { kind: "delta", text: "b" }, 2)).toBe(false);
    expect(coalesceStreamedText(events, generations, { kind: "delta", text: "b" }, 1)).toBe(true);
    expect(events).toEqual([{ kind: "delta", text: "ab" }]);
  });

  test("a long stream no longer pushes the start of the reply past the event cap", () => {
    const { sess } = fakeSession("cap");
    emitSessionEventForTest(sess, { kind: "user", text: "Write a lot" });
    for (let i = 0; i < 6_000; i++) emitSessionEventForTest(sess, { kind: "delta", text: "x" });
    expect(sess.events).toHaveLength(2);
    expect(sess.events[0]).toEqual({ kind: "user", text: "Write a lot" });
    expect((sess.events[1] as { text: string }).text).toHaveLength(6_000);
  });
});

describe("replacing and batching history", () => {
  test("a replaced history goes out as one history message, with no empty one first", () => {
    const { sess, messages } = fakeSession("replace");
    emitSessionEventForTest(sess, { kind: "user", text: "old" });
    messages.length = 0;
    const events: AgentEvent[] = [{ kind: "user", text: "new" }, { kind: "delta", text: "a" }, { kind: "delta", text: "b" }, { kind: "done" }];
    replaceSessionHistory(sess, events);
    expect(messages).toHaveLength(1);
    expect(messages[0]).toMatchObject({ kind: "history", sessionId: "replace" });
    expect(messages[0].events).toEqual([{ kind: "user", text: "new" }, { kind: "delta", text: "ab" }, { kind: "done" }]);
    expect(sess.internal.eventGenerations).toEqual([0, 0, 0]);
  });

  test("a batch is stored like single events and sent as one message", () => {
    const { sess, messages } = fakeSession("batch");
    const events: AgentEvent[] = [{ kind: "tool-start", toolId: "t1", name: "Bash" }, { kind: "tool-end", toolId: "t1", ok: true }, { kind: "delta", text: "ok" }];
    emitSessionEventsForTest(sess, events);
    expect(messages).toEqual([{ kind: "events", sessionId: "batch", events }]);
    expect(sess.events).toEqual(events);
    emitSessionEventsForTest(sess, []);
    expect(messages).toHaveLength(1);
  });
});
