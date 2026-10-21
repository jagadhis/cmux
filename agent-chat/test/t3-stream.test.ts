import { describe, expect, test } from "bun:test";
import { emitStep, nextRetryDelay } from "../adapters/t3";
import { T3ThreadMirror, type T3DomainEvent, type T3ProjectionReducer } from "../adapters/t3-stream";
import { T3Timeline, type T3Projection, type T3TurnItem } from "../adapters/t3-timeline";
import type { AgentEvent, SessionCtx } from "../types";

function projection(turnItems: T3TurnItem[] = []): T3Projection {
  return {
    thread: { id: "th", title: "Relay" },
    runs: [{ id: "r1", ordinal: 1, status: "running", userMessageId: "m1" }],
    messages: [{ id: "m1", role: "user", text: "Go" }],
    turnItems,
    runtimeRequests: [],
  };
}

/** Upserts turn items like T3's reducer; anything else is a type it doesn't know. */
const reducer: T3ProjectionReducer = (current, event) => {
  if (!current) return current;
  if (event.type !== "turn-item.updated") return undefined;
  const item = event.payload as T3TurnItem;
  const index = current.turnItems.findIndex((i) => i.id === item.id);
  const turnItems = index < 0 ? [...current.turnItems, item] : current.turnItems.map((i, n) => (n === index ? item : i));
  return { ...current, turnItems };
};

function itemEvent(sequence: number, item: T3TurnItem): { kind: "event"; sequence: number; event: T3DomainEvent } {
  return { kind: "event", sequence, event: { type: "turn-item.updated", threadId: "th", payload: item } };
}

const text = (id: string, value: string, ordinal = 1): T3TurnItem =>
  ({ id, runId: "r1", ordinal, status: "running", type: "assistant_message", text: value });

describe("T3ThreadMirror", () => {
  test("seeds from the snapshot and applies each event without a re-read", () => {
    const mirror = new T3ThreadMirror(reducer);
    expect(mirror.apply({ kind: "snapshot", snapshotSequence: 10, projection: projection() })).toBe("changed");
    expect(mirror.apply(itemEvent(11, text("a1", "Hel")))).toBe("changed");
    expect(mirror.apply(itemEvent(12, text("a1", "Hello")))).toBe("changed");
    expect(mirror.sequence).toBe(12);

    // The timeline reads the mirrored projection as it read a fetched one.
    const timeline = new T3Timeline();
    expect(timeline.step(mirror.projection!).events).toEqual([{ kind: "user", text: "Go" }, { kind: "delta", text: "Hello" }]);
  });

  test("skips events at or below the last sequence, as a replay overlapping the live tail sends them", () => {
    const mirror = new T3ThreadMirror(reducer);
    mirror.apply({ kind: "snapshot", snapshotSequence: 10, projection: projection() });
    mirror.apply(itemEvent(11, text("a1", "Hello")));
    expect(mirror.apply(itemEvent(11, text("a1", "Hel")))).toBe("unchanged");
    expect(mirror.apply(itemEvent(9, text("a1", "")))).toBe("unchanged");
    expect(mirror.projection!.turnItems[0]!.text).toBe("Hello");
  });

  test("an event the reducer can't apply asks for a fresh snapshot", () => {
    const mirror = new T3ThreadMirror(reducer);
    mirror.apply({ kind: "snapshot", snapshotSequence: 1, projection: projection() });
    expect(mirror.apply({ kind: "event", sequence: 2, event: { type: "something.new", threadId: "th" } })).toBe("resync");
    expect(mirror.apply({ kind: "unknown-event", sequence: 3, eventType: "newer.event" })).toBe("resync");

    const throwing = new T3ThreadMirror(() => { throw new Error("bad payload"); });
    throwing.apply({ kind: "snapshot", snapshotSequence: 1, projection: projection() });
    const error = console.error;
    console.error = () => {};
    try {
      expect(throwing.apply(itemEvent(2, text("a1", "x")))).toBe("resync");
    } finally {
      console.error = error;
    }

    // Events before any snapshot (a forgotten mirror) can't be applied either.
    expect(new T3ThreadMirror(reducer).apply(itemEvent(1, text("a1", "x")))).toBe("resync");
  });

  test("without T3's reducer every event asks for a re-read, as before", () => {
    const mirror = new T3ThreadMirror(null);
    mirror.apply({ kind: "snapshot", snapshotSequence: 1, projection: projection() });
    expect(mirror.apply(itemEvent(2, text("a1", "x")))).toBe("read");
    expect(mirror.sequence).toBe(2);
    mirror.replace(projection([text("a1", "x")]));
    expect(mirror.projection!.turnItems).toHaveLength(1);
  });

  test("a windowed snapshot applies events as a partial timeline and raises the watermark", () => {
    const calls: unknown[] = [];
    const recording: T3ProjectionReducer = (current, event, options) => {
      calls.push(options);
      return reducer(current, event, options);
    };
    const mirror = new T3ThreadMirror(recording);
    mirror.apply({ kind: "snapshot", snapshotSequence: 5, projection: projection(), hasMoreHistory: true, latestLocalTurnOrdinal: 40 });
    mirror.apply(itemEvent(6, text("a1", "x", 41)));
    mirror.apply(itemEvent(7, text("a2", "y", 42)));
    expect(calls).toEqual([
      { partialTimeline: true, latestLocalTurnOrdinal: 40 },
      { partialTimeline: true, latestLocalTurnOrdinal: 41 },
    ]);

    const whole = new T3ThreadMirror(recording);
    calls.length = 0;
    whole.apply({ kind: "snapshot", snapshotSequence: 5, projection: projection() });
    whole.apply(itemEvent(6, text("a1", "x")));
    expect(calls).toEqual([undefined]);
  });

  test("forget starts the next subscription from a snapshot", () => {
    const mirror = new T3ThreadMirror(reducer);
    mirror.apply({ kind: "snapshot", snapshotSequence: 5, projection: projection() });
    mirror.forget();
    expect(mirror.sequence).toBeUndefined();
    expect(mirror.projection).toBeNull();
  });
});

describe("T3 retries", () => {
  test("back off from 1 s, doubling to 30 s", () => {
    const delays: number[] = [];
    let delay: number | undefined;
    for (let i = 0; i < 8; i++) delays.push(delay = nextRetryDelay(delay));
    expect(delays).toEqual([1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]);
  });
});

describe("emitStep", () => {
  function fakeSession() {
    const calls: { op: string; events?: AgentEvent[] }[] = [];
    const sess = {
      emit(evt: AgentEvent) { calls.push({ op: "emit", events: [evt] }); },
      emitAll(events: AgentEvent[]) { calls.push({ op: "emitAll", events }); },
      replaceHistory(events: AgentEvent[]) { calls.push({ op: "replaceHistory", events }); },
      resetHistory() { calls.push({ op: "resetHistory" }); },
    } as unknown as SessionCtx;
    return { sess, calls };
  }
  const events: AgentEvent[] = [{ kind: "user", text: "Go" }, { kind: "delta", text: "Hi" }];

  test("the first read and a rollback replace the history in one message", () => {
    const { sess, calls } = fakeSession();
    emitStep(sess, events, true);
    expect(calls).toEqual([{ op: "replaceHistory", events }]);
  });

  test("later steps go out as one batch", () => {
    const { sess, calls } = fakeSession();
    emitStep(sess, events, false);
    expect(calls).toEqual([{ op: "emitAll", events }]);
  });
});
