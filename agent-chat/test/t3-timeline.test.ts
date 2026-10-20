import { describe, expect, test } from "bun:test";
import { T3Timeline, type T3Projection } from "../adapters/t3-timeline";

function projection(overrides: Partial<T3Projection> = {}): T3Projection {
  return {
    thread: { id: "th", title: "Voice relay", worktreePath: "/repo", modelSelection: { model: "claude-opus-5-5" } },
    runs: [{ id: "r1", ordinal: 1, status: "running", userMessageId: "m1" }],
    messages: [{ id: "m1", role: "user", text: "Switch the relay" }],
    turnItems: [],
    runtimeRequests: [],
    ...overrides,
  };
}

describe("T3Timeline", () => {
  test("emits the user message once, then streams assistant text as deltas", () => {
    const timeline = new T3Timeline();
    const first = timeline.step(projection({
      turnItems: [{ id: "a1", runId: "r1", ordinal: 1, status: "running", type: "assistant_message", text: "Switching" }],
    }));
    expect(first.events).toEqual([{ kind: "user", text: "Switch the relay" }, { kind: "delta", text: "Switching" }]);
    expect(first.status).toBe("running");
    expect(first.activeRunId).toBe("r1");
    expect(first.cwd).toBe("/repo");

    const second = timeline.step(projection({
      turnItems: [{ id: "a1", runId: "r1", ordinal: 1, status: "running", type: "assistant_message", text: "Switching now." }],
    }));
    expect(second.events).toEqual([{ kind: "delta", text: " now." }]);
  });

  test("tools start once and end with their outcome; finished runs emit done", () => {
    const timeline = new T3Timeline();
    timeline.step(projection({
      turnItems: [{ id: "t1", runId: "r1", ordinal: 1, status: "running", type: "command_execution", input: "bun test\nmore" }],
    }));
    const finished = timeline.step(projection({
      runs: [{ id: "r1", ordinal: 1, status: "completed", userMessageId: "m1" }],
      turnItems: [{ id: "t1", runId: "r1", ordinal: 1, status: "completed", type: "command_execution", input: "bun test\nmore" }],
    }));
    expect(finished.events).toEqual([{ kind: "tool-end", toolId: "t1", ok: true }, { kind: "done" }]);
    expect(finished.status).toBe("idle");
    expect(timeline.step(projection({
      runs: [{ id: "r1", ordinal: 1, status: "completed", userMessageId: "m1" }],
      turnItems: [{ id: "t1", runId: "r1", ordinal: 1, status: "completed", type: "command_execution", input: "bun test" }],
    })).events).toEqual([]);
  });

  test("dynamic tools describe their input", () => {
    const step = new T3Timeline().step(projection({
      turnItems: [{ id: "t2", runId: "r1", ordinal: 1, status: "running", type: "dynamic_tool", toolName: "Read", input: { file_path: "/repo/a.ts" } }],
    }));
    expect(step.events[1]).toEqual({ kind: "tool-start", toolId: "t2", name: "Read", detail: "/repo/a.ts" });
  });

  test("a vanished item asks for a reset and replays", () => {
    const timeline = new T3Timeline();
    timeline.step(projection({
      turnItems: [{ id: "a1", runId: "r1", ordinal: 1, status: "completed", type: "assistant_message", text: "Old answer" }],
    }));
    const after = timeline.step(projection({
      turnItems: [{ id: "a2", runId: "r1", ordinal: 1, status: "completed", type: "assistant_message", text: "New" }],
    }));
    expect(after.reset).toBe(true);
    expect(after.events).toEqual([{ kind: "user", text: "Switch the relay" }, { kind: "delta", text: "New" }]);
  });

  test("a pending command request becomes an approval card naming the command", () => {
    const step = new T3Timeline().step(projection({
      turnItems: [{ id: "t1", runId: "r1", ordinal: 1, status: "waiting", type: "command_execution", input: "fly deploy --strategy canary" }],
      runtimeRequests: [{ id: "q1", kind: "command", status: "pending" }],
    }));
    expect(step.request).toEqual({ id: "q1", kind: "command", title: "Wants to run a command", detail: "fly deploy --strategy canary", isApproval: true });
    const question = new T3Timeline().step(projection({ runtimeRequests: [{ id: "q2", kind: "user_input", status: "pending" }] }));
    expect(question.request?.isApproval).toBe(false);
  });

  test("a sub-thread's items under the parent's run ids still show", () => {
    const step = new T3Timeline().step(projection({
      runs: [],
      messages: [],
      turnItems: [
        { id: "a1", runId: "parent-run", ordinal: 2, status: "completed", type: "assistant_message", text: "Found it" },
        { id: "t1", runId: "parent-run", ordinal: 1, status: "completed", type: "command_execution", input: "rg relay" },
      ],
    }));
    expect(step.events).toEqual([
      { kind: "tool-start", toolId: "t1", name: "Bash", detail: "rg relay" },
      { kind: "tool-end", toolId: "t1", ok: true },
      { kind: "delta", text: "Found it" },
      { kind: "done" },
    ]);
    expect(step.status).toBe("idle");
  });
});
