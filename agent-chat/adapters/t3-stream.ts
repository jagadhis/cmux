// Keeps a T3 Code thread's projection current from T3's thread stream.
//
// `orchestration.subscribeThread` sends the thread once as a snapshot, then
// each change as a domain event with a sequence number. T3's own client
// applies those events to its copy with a pure reducer
// (`applyOrchestrationV2ProjectionEvent` in client-runtime); this does the
// same, so a streamed token costs one small event instead of a re-read of the
// thread. An event it can't apply asks for a fresh snapshot.
//
// Without the reducer (an older T3 checkout), every event asks for a re-read
// instead, as before.

import type { T3Projection } from "./t3-timeline";

/** A T3 domain event. Only `type`, `threadId` and a turn item's `ordinal` are read here. */
export interface T3DomainEvent {
  type: string;
  threadId?: string;
  payload?: unknown;
}

/** T3's `applyOrchestrationV2ProjectionEvent`. */
export type T3ProjectionReducer = (
  projection: T3Projection | null,
  event: T3DomainEvent,
  options?: { partialTimeline?: boolean; latestLocalTurnOrdinal?: number | null },
) => T3Projection | null | undefined;

/** What `orchestration.subscribeThread` streams, as T3's contracts decode it. */
export type T3StreamItem =
  | { kind: "synchronized" }
  | {
    kind: "snapshot";
    snapshotSequence: number;
    projection: T3Projection;
    historyCursor?: string | null;
    hasMoreHistory?: boolean;
    latestLocalTurnOrdinal?: number | null;
  }
  | { kind: "event"; sequence: number; event: T3DomainEvent }
  | { kind: "unknown-event"; sequence: number; eventType: string };

/**
 * What a stream item did to the projection: `changed` it, left it
 * `unchanged`, needs a fresh snapshot (`resync`), or needs the thread
 * re-read (`read`, without a reducer).
 */
export type T3StreamResult = "changed" | "unchanged" | "resync" | "read";

export class T3ThreadMirror {
  projection: T3Projection | null = null;
  /** The last sequence seen. Resubscribing after it replays only what was missed. */
  sequence: number | undefined;
  /** Set while the projection is the recent window of a longer thread, as T3 sends long threads. */
  private window: { latestLocalTurnOrdinal: number | null } | null = null;

  constructor(public reducer: T3ProjectionReducer | null) {}

  apply(item: T3StreamItem): T3StreamResult {
    switch (item.kind) {
      case "synchronized":
        return "unchanged";
      case "snapshot":
        this.projection = item.projection;
        this.sequence = item.snapshotSequence;
        this.window = item.hasMoreHistory || (item.historyCursor ?? null) !== null
          ? { latestLocalTurnOrdinal: item.latestLocalTurnOrdinal ?? null }
          : null;
        return "changed";
      case "unknown-event":
        // An event this T3 checkout's contracts don't know: only T3 can say what it changed.
        if (!this.advance(item.sequence)) return "unchanged";
        return this.reducer ? "resync" : "read";
      case "event": {
        if (!this.advance(item.sequence)) return "unchanged";
        if (!this.reducer) return "read";
        if (!this.projection) return "resync";
        let next: T3Projection | null | undefined;
        try {
          next = this.reducer(this.projection, item.event, this.window
            ? { partialTimeline: true, latestLocalTurnOrdinal: this.window.latestLocalTurnOrdinal }
            : undefined);
        } catch (err) {
          console.error("[agent-chat] T3 event didn't apply; reading the thread again", item.event.type, err);
          return "resync";
        }
        // The reducer has no case for an event type it doesn't know.
        if (!next) return "resync";
        if (next === this.projection) return "unchanged";
        // Like T3's client: only an item the reducer took moves the watermark.
        if (this.window && item.event.type === "turn-item.updated") {
          const ordinal = (item.event.payload as { ordinal?: unknown } | undefined)?.ordinal;
          const watermark = this.window.latestLocalTurnOrdinal;
          if (typeof ordinal === "number" && (watermark === null || ordinal > watermark)) this.window.latestLocalTurnOrdinal = ordinal;
        }
        this.projection = next;
        return "changed";
      }
    }
  }

  /** Takes a projection read over RPC (no reducer). The sequence stays where the stream is. */
  replace(projection: T3Projection) {
    this.projection = projection;
  }

  /** Forgets everything, so the next subscription starts from a snapshot. */
  forget() {
    this.projection = null;
    this.sequence = undefined;
    this.window = null;
  }

  /** Records a sequence; false for one already applied (a replay overlapping the live tail). */
  private advance(sequence: number): boolean {
    if (this.sequence !== undefined && sequence <= this.sequence) return false;
    this.sequence = sequence;
    return true;
  }
}
