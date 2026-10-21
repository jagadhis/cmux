import { describe, expect, test } from "bun:test";
import { T3Timeline, answerLines, type T3Projection, type T3Question } from "../adapters/t3-timeline";

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
    expect(step.request).toEqual({
      id: "q1", kind: "command", title: "Wants to run a command", detail: "fly deploy --strategy canary",
      isApproval: true, answerable: true, dismissible: false,
    });
    const stale = new T3Timeline().step(projection({
      runtimeRequests: [{ id: "q1", kind: "command", status: "pending", responseCapability: { type: "not_resumable" } }],
    }));
    expect(stale.request?.answerable).toBe(false);
  });

  const deployQuestion: T3Question = {
    id: "target",
    header: "Target",
    question: "Where should this deploy?",
    options: [{ label: "Staging", description: "Safe" }, { label: "Production", description: "Live", value: "prod" }],
  };

  test("a pending question carries its questions and options", () => {
    const step = new T3Timeline().step(projection({
      turnItems: [{ id: "u1", runId: "r1", ordinal: 1, status: "waiting", type: "user_input_request", requestId: "q2", questions: [deployQuestion] }],
      runtimeRequests: [{ id: "q2", kind: "user_input", status: "pending", responseCapability: { type: "live" } }],
    }));
    expect(step.request).toEqual({
      id: "q2", kind: "user_input", title: "Asked you a question", isApproval: false,
      questions: [{ ...deployQuestion, multiSelect: false }], answerable: true, dismissible: false,
    });
  });

  test("an answered question shows its answer once, by option label", () => {
    const timeline = new T3Timeline();
    const answered = projection({
      turnItems: [{ id: "u1", runId: "r1", ordinal: 1, status: "completed", type: "user_input_request", requestId: "q2", questions: [deployQuestion] }],
      runtimeRequests: [{ id: "q2", kind: "user_input", status: "resolved", answers: { target: "prod" } }],
    });
    expect(timeline.step(answered).events).toContainEqual({ kind: "user", text: "Target: Production" });
    expect(timeline.step(answered).events).toEqual([]);
    const onItem = new T3Timeline().step(projection({
      turnItems: [{ id: "u1", runId: "r1", ordinal: 1, status: "completed", type: "user_input_request", requestId: "q2", questions: [deployQuestion], questionAnswer: { answers: { target: "Staging" } } }],
      runtimeRequests: [{ id: "q2", kind: "user_input", status: "resolved" }],
    }));
    expect(onItem.events).toContainEqual({ kind: "user", text: "Target: Staging" });
    expect(answerLines([{ ...deployQuestion, multiSelect: true }], { target: ["Staging", "prod"] })).toEqual(["Target: Staging, Production"]);
    expect(answerLines([deployQuestion], { target: "Somewhere else" })).toEqual(["Target: Somewhere else"]);
  });

  test("reports the thread's model selection", () => {
    const selection = { instanceId: "claudeAgent", model: "claude-opus-5-5", options: [{ id: "effort", value: "high" }] };
    const step = new T3Timeline().step(projection({ thread: { id: "th", title: "t", modelSelection: selection } }));
    expect(step.modelSelection).toEqual(selection);
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

  test("work still running after the turn ends shows like T3's background banner", () => {
    const step = new T3Timeline().step(projection({
      runs: [{ id: "r1", ordinal: 1, status: "completed", userMessageId: "m1" }],
      turnItems: [
        { id: "c1", runId: "r1", ordinal: 1, status: "running", type: "command_execution", input: "bun run dev\n--watch" },
        { id: "c2", runId: "r1", ordinal: 2, status: "completed", type: "command_execution", input: "ls" },
      ],
    }));
    expect(step.status).toBe("idle");
    expect(step.background).toEqual({
      title: "Running: bun run dev",
      items: [{ taskId: "c1", kind: "command", label: "bun run dev" }],
      waiting: false,
    });
    expect(step.backgroundStop).toEqual({ runId: "r1", pullRequests: [] });
  });

  test("subagents the provider still runs hold the thread idle and are named", () => {
    const step = new T3Timeline().step(projection({
      thread: { id: "th", title: "t", activeProviderThreadId: "pt1" },
      runs: [{ id: "r1", ordinal: 1, status: "waiting", userMessageId: "m1" }],
      providerThreads: [
        { id: "pt1", pendingBackgroundTasks: [
          { taskId: "a1", kind: "subagent", description: "Subagent: Review the diff", childThreadId: "child" },
          { taskId: "b1", kind: "background_task", description: "Tail logs" },
        ] },
        { id: "other", pendingBackgroundTasks: [{ taskId: "x", kind: "command", description: "ignored" }] },
      ],
    }));
    expect(step.status).toBe("idle");
    expect(step.background).toEqual({
      title: "Waiting on 1 subagent and 1 background task",
      items: [
        { taskId: "a1", kind: "subagent", label: "Review the diff", childThreadId: "child" },
        { taskId: "b1", kind: "background_task", label: "Tail logs" },
      ],
      waiting: true,
    });
  });

  test("a watched pull request shows as a monitor and stops by unwatching", () => {
    const step = new T3Timeline().step(projection({
      thread: { id: "th", title: "t", pullRequests: [
        { host: "github.com", repository: "o/r", number: 7, watch: {} },
        { host: "github.com", repository: "o/r", number: 8 },
      ] },
      runs: [],
      messages: [],
    }));
    expect(step.background?.title).toBe("Watching pull request #7");
    expect(step.backgroundStop).toEqual({ pullRequests: [{ host: "github.com", repository: "o/r", number: 7 }] });
  });

  test("no background banner while the run is still working", () => {
    const step = new T3Timeline().step(projection({
      turnItems: [{ id: "c1", runId: "r1", ordinal: 1, status: "running", type: "command_execution", input: "sleep 9" }],
    }));
    expect(step.status).toBe("running");
    expect(step.background).toBeNull();
    expect(step.backgroundStop).toBeUndefined();
  });

  test("consecutive assistant messages start a new paragraph instead of running together", () => {
    const timeline = new T3Timeline();
    const first = timeline.step(projection({
      turnItems: [
        { id: "a1", runId: "r1", ordinal: 1, status: "completed", type: "assistant_message", text: "Checked the relay; done." },
        { id: "a2", runId: "r1", ordinal: 2, status: "running", type: "assistant_message", text: "Next" },
      ],
    }));
    expect(first.events.slice(1)).toEqual([
      { kind: "delta", text: "Checked the relay; done." },
      { kind: "delta", text: "\n\nNext" },
    ]);
    // The second message keeps streaming into its own paragraph, and a later
    // step that starts a third message separates it too.
    const second = timeline.step(projection({
      turnItems: [
        { id: "a1", runId: "r1", ordinal: 1, status: "completed", type: "assistant_message", text: "Checked the relay; done." },
        { id: "a2", runId: "r1", ordinal: 2, status: "completed", type: "assistant_message", text: "Next, the deploy." },
        { id: "a3", runId: "r1", ordinal: 3, status: "running", type: "assistant_message", text: "Shipped." },
      ],
    }));
    expect(second.events).toEqual([{ kind: "delta", text: ", the deploy." }, { kind: "delta", text: "\n\nShipped." }]);
  });

  test("a tool ending between two messages still separates them", () => {
    // The page leaves the open text block open when a tool ends, so without the
    // break the second message would read "Launched it.It finished."
    const timeline = new T3Timeline();
    timeline.step(projection({
      turnItems: [
        { id: "t1", runId: "r1", ordinal: 1, status: "running", type: "command_execution", input: "deploy" },
        { id: "a1", runId: "r1", ordinal: 2, status: "completed", type: "assistant_message", text: "Launched it." },
      ],
    }));
    const next = timeline.step(projection({
      turnItems: [
        { id: "t1", runId: "r1", ordinal: 1, status: "completed", type: "command_execution", input: "deploy" },
        { id: "a1", runId: "r1", ordinal: 2, status: "completed", type: "assistant_message", text: "Launched it." },
        { id: "a2", runId: "r1", ordinal: 3, status: "running", type: "assistant_message", text: "It finished." },
      ],
    }));
    expect(next.events).toEqual([{ kind: "tool-end", toolId: "t1", ok: true }, { kind: "delta", text: "\n\nIt finished." }]);
  });

  test("text after a tool or of another kind needs no separator", () => {
    const step = new T3Timeline().step(projection({
      turnItems: [
        { id: "a1", runId: "r1", ordinal: 1, status: "completed", type: "assistant_message", text: "Running tests." },
        { id: "t1", runId: "r1", ordinal: 2, status: "completed", type: "command_execution", input: "bun test" },
        { id: "a2", runId: "r1", ordinal: 3, status: "completed", type: "assistant_message", text: "All green." },
        { id: "k1", runId: "r1", ordinal: 4, status: "completed", type: "reasoning", text: "Anything else?" },
        { id: "a3", runId: "r1", ordinal: 5, status: "running", type: "assistant_message", text: "No." },
      ],
    }));
    expect(step.events.slice(1)).toEqual([
      { kind: "delta", text: "Running tests." },
      { kind: "tool-start", toolId: "t1", name: "Bash", detail: "bun test" },
      { kind: "tool-end", toolId: "t1", ok: true },
      { kind: "delta", text: "All green." },
      { kind: "thinking", text: "Anything else?" },
      { kind: "delta", text: "No." },
    ]);
  });

  test("a finished run is skipped once settled, but still shows items that arrive later", () => {
    const timeline = new T3Timeline();
    const done = { id: "r1", ordinal: 1, status: "completed", userMessageId: "m1" };
    const items = [{ id: "a1", runId: "r1", ordinal: 1, status: "completed", type: "assistant_message", text: "Done." }];
    expect(timeline.step(projection({ runs: [done], turnItems: items })).events).toEqual([
      { kind: "user", text: "Switch the relay" }, { kind: "delta", text: "Done." }, { kind: "done" },
    ]);
    expect(timeline.step(projection({ runs: [done], turnItems: items })).events).toEqual([]);
    const late = timeline.step(projection({
      runs: [done],
      turnItems: [...items, { id: "n1", runId: "r1", ordinal: 2, status: "completed", type: "notification", summary: "PR merged" }],
    }));
    expect(late.events).toEqual([{ kind: "status", text: "PR merged" }]);
  });

  test("a tool still running after its run finished ends later", () => {
    const timeline = new T3Timeline();
    const done = { id: "r1", ordinal: 1, status: "completed", userMessageId: "m1" };
    timeline.step(projection({ runs: [done], turnItems: [{ id: "c1", runId: "r1", ordinal: 1, status: "running", type: "command_execution", input: "watch" }] }));
    const ended = timeline.step(projection({ runs: [done], turnItems: [{ id: "c1", runId: "r1", ordinal: 1, status: "completed", type: "command_execution", input: "watch" }] }));
    expect(ended.events).toEqual([{ kind: "tool-end", toolId: "c1", ok: true }]);
  });
});
