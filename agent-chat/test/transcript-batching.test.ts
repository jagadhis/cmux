// Streamed events fold into the transcript once per frame, the server stores
// consecutive deltas as one event, and unchanged turns skip rendering. Each
// must leave the transcript exactly as folding event by event would.
import type { AgentEvent, Block } from "../src/session";
import { createEventBatch } from "../src/eventBatch";
import { groupTurns, sameTurnGroup } from "../src/turns";

(globalThis as any).location ??= { pathname: "/" };
const { foldEvent } = await import("../src/session");

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

// Events between two frames apply in one update, in order.
{
  const frames: (() => void)[] = [];
  const applied: string[][] = [];
  const batch = createEventBatch<string>((events) => applied.push(events), (run) => frames.push(run), () => {});
  batch.push("a");
  batch.push("b");
  batch.push("c");
  assert(!applied.length, "events applied before the frame");
  assert(frames.length === 1, `expected one scheduled frame, got ${frames.length}`);
  frames[0]!();
  assert(same(applied, [["a", "b", "c"]]), `expected one batch, got ${JSON.stringify(applied)}`);

  // flush applies now (an optimistic user block must land after queued deltas); the stale frame does nothing.
  batch.push("d");
  batch.flush();
  frames[1]!();
  assert(same(applied, [["a", "b", "c"], ["d"]]), `flush: ${JSON.stringify(applied)}`);

  // discard drops what a replaced history already contains.
  batch.push("e");
  batch.discard();
  frames[2]!();
  assert(same(applied, [["a", "b", "c"], ["d"]]), `discarded events applied: ${JSON.stringify(applied)}`);
}

// Folding a batch, or the server's coalesced deltas, gives the same blocks.
{
  const events: AgentEvent[] = [
    { kind: "user", text: "Go" },
    { kind: "thinking", text: "Plan " }, { kind: "thinking", text: "it." },
    { kind: "delta", text: "On " }, { kind: "delta", text: "it." },
    { kind: "tool-start", toolId: "t1", name: "Bash", detail: "ls" },
    { kind: "tool-end", toolId: "t1", ok: true },
    { kind: "delta", text: "Done" }, { kind: "delta", text: "." },
    { kind: "done" },
  ];
  const oneByOne = events.reduce((blocks: Block[], evt) => foldEvent(blocks, evt), []);
  const coalesced: AgentEvent[] = [
    events[0]!, { kind: "thinking", text: "Plan it." }, { kind: "delta", text: "On it." },
    events[5]!, events[6]!, { kind: "delta", text: "Done." }, events[9]!,
  ];
  assert(same(coalesced.reduce(foldEvent, [] as Block[]), oneByOne), "coalesced deltas fold differently");
}

// Turns whose blocks didn't change compare equal, so they skip rendering.
{
  let blocks: Block[] = [];
  for (const evt of [
    { kind: "user", text: "First" }, { kind: "delta", text: "One." }, { kind: "done" },
    { kind: "user", text: "Second" }, { kind: "delta", text: "Tw" },
  ] as AgentEvent[]) blocks = foldEvent(blocks, evt);
  const before = groupTurns(blocks, "running");
  blocks = foldEvent(blocks, { kind: "delta", text: "o." });
  const after = groupTurns(blocks, "running");
  assert(before.length === 2 && after.length === 2, "expected two turns");
  assert(before[0] !== after[0] && sameTurnGroup(before[0]!, after[0]!), "finished turn should compare equal");
  assert(!sameTurnGroup(before[1]!, after[1]!), "streaming turn should compare different");

  blocks = foldEvent(blocks, { kind: "done" });
  const finished = groupTurns(blocks, "idle");
  assert(!sameTurnGroup(after[1]!, finished[1]!), "a turn gaining its footer should compare different");
}

// A hidden page gets no animation frames: the default schedule still flushes
// on a timer, so a chat streaming in the background doesn't queue everything.
{
  const g = globalThis as any;
  const hadFrame = "requestAnimationFrame" in g;
  g.requestAnimationFrame = () => 1;
  g.cancelAnimationFrame = () => {};
  try {
    const applied: string[][] = [];
    const batch = createEventBatch<string>((events) => applied.push(events));
    batch.push("a");
    batch.push("b");
    await new Promise((resolve) => setTimeout(resolve, 250));
    assert(same(applied, [["a", "b"]]), `hidden page should still flush, got ${JSON.stringify(applied)}`);
  } finally {
    if (!hadFrame) { delete g.requestAnimationFrame; delete g.cancelAnimationFrame; }
  }
}

console.log("transcript batching: OK");

export {};
