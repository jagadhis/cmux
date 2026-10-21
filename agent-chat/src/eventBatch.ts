// Streamed events arrive many per frame (a delta per token batch, a tool
// start and end). Folding each into its own state update re-groups and
// re-renders the transcript every time; this collects them and applies them
// once per animation frame.

type Schedule = (run: () => void) => unknown;
type Cancel = (handle: unknown) => void;

// A hidden page (a background tab, a WKWebView not on screen) gets no
// animation frames, so a timer races the frame: a chat streaming while hidden
// still folds in as it goes instead of all at once when shown.
const HIDDEN_FLUSH_MS = 100;
const nextFrame: Schedule = (run) => {
  let frame: number | undefined;
  const fire = () => {
    if (frame !== undefined && typeof cancelAnimationFrame === "function") cancelAnimationFrame(frame);
    clearTimeout(timer);
    run();
  };
  const timer = setTimeout(fire, typeof requestAnimationFrame === "function" ? HIDDEN_FLUSH_MS : 16);
  if (typeof requestAnimationFrame === "function") frame = requestAnimationFrame(fire);
  return () => {
    if (frame !== undefined && typeof cancelAnimationFrame === "function") cancelAnimationFrame(frame);
    clearTimeout(timer);
  };
};
const cancelFrame: Cancel = (handle) => (handle as () => void)();

export interface EventBatch<E> {
  /** Queues an event for the next frame. */
  push(event: E): void;
  /** Applies what's queued now: before an update that must come after it. */
  flush(): void;
  /** Drops what's queued: the history it belongs to was replaced. */
  discard(): void;
}

export function createEventBatch<E>(apply: (events: E[]) => void, schedule: Schedule = nextFrame, cancel: Cancel = cancelFrame): EventBatch<E> {
  let queued: E[] = [];
  let handle: unknown = null;
  const take = () => {
    if (handle !== null) cancel(handle);
    handle = null;
    const events = queued;
    queued = [];
    return events;
  };
  return {
    push(event) {
      queued.push(event);
      if (handle === null) {
        handle = schedule(() => {
          handle = null;
          const events = take();
          if (events.length) apply(events);
        });
      }
    },
    flush() {
      const events = take();
      if (events.length) apply(events);
    },
    discard() {
      take();
    },
  };
}
