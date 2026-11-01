// The open T3 Code threads, for the phone's home page.
//
// The same rule as Agent Home on the Mac (`T3CodeStateReader.activeThreads`):
// a thread is listed unless it's archived, deleted, or its task is settled or
// snoozed, and a live run, a working sub-agent or a pending request always
// lists it. Read straight from T3's database, read-only.

import type { Database } from "bun:sqlite";
import { requestTitle } from "./t3-timeline";

/** What the home page shows for a thread, most urgent first. */
export type T3ThreadState = "needs-input" | "running" | "unread" | "idle";

export interface T3ThreadSummary {
  id: string;
  title: string;
  projectId: string;
  projectName: string;
  /** The task's first thread; null when this thread is one. */
  rootThreadId: string | null;
  state: T3ThreadState;
  /** What the thread waits on you for ("Asked you a question"), while it needs input. */
  waitingFor: string | null;
  branch: string | null;
  /** ISO time of the last change. */
  updatedAt: string;
}

const ACTIVE = ["preparing", "queued", "starting", "running", "waiting"];
const ACTIVE_LIST = ACTIVE.map((s) => `'${s}'`).join(", ");

function subagentSql(db: Database): string {
  const has = db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'orchestration_v2_projection_subagents'").get();
  // Older T3 versions have no sub-agent table.
  return has
    ? `SELECT child_thread_id, status FROM (
         SELECT child_thread_id, status, row_number() OVER (PARTITION BY child_thread_id ORDER BY updated_at DESC, rowid DESC) AS n
         FROM orchestration_v2_projection_subagents WHERE child_thread_id IS NOT NULL)
       WHERE n = 1`
    : "SELECT NULL AS child_thread_id, NULL AS status WHERE 0";
}

interface Row {
  thread_id: string;
  project_id: string | null;
  project_title: string | null;
  title: string | null;
  updated_at: string | null;
  payload_json: string | null;
  run_status: string | null;
  run_completed_at: string | null;
  pending: number;
  pending_kind: string | null;
  subagent_status: string | null;
}

function threadSql(db: Database): string {
  return `
    WITH latest_run AS (
      SELECT r.thread_id, r.status, r.completed_at
      FROM orchestration_v2_projection_runs r
      WHERE r.ordinal = (SELECT max(ordinal) FROM orchestration_v2_projection_runs WHERE thread_id = r.thread_id)
    ),
    subagent AS (${subagentSql(db)})
    SELECT t.thread_id, t.project_id, p.title AS project_title, t.title, t.updated_at, t.payload_json,
           lr.status AS run_status, lr.completed_at AS run_completed_at,
           (SELECT count(*) FROM orchestration_v2_projection_runtime_requests q
             WHERE q.thread_id = t.thread_id AND q.status = 'pending') AS pending,
           (SELECT q.kind FROM orchestration_v2_projection_runtime_requests q
             WHERE q.thread_id = t.thread_id AND q.status = 'pending'
             ORDER BY q.created_at DESC LIMIT 1) AS pending_kind,
           sa.status AS subagent_status
    FROM orchestration_v2_projection_threads t
    LEFT JOIN projection_projects p ON p.project_id = t.project_id AND p.deleted_at IS NULL
    LEFT JOIN orchestration_v2_projection_threads root
           ON root.thread_id = json_extract(t.payload_json, '$.lineage.rootThreadId')
          AND root.thread_id <> t.thread_id
    LEFT JOIN latest_run lr ON lr.thread_id = t.thread_id
    LEFT JOIN subagent sa ON sa.child_thread_id = t.thread_id
    WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
      AND (
        (coalesce(json_extract(coalesce(root.payload_json, t.payload_json), '$.settledOverride'), '') <> 'settled'
          AND coalesce(julianday(json_extract(coalesce(root.payload_json, t.payload_json), '$.snoozedUntil')), 0) <= julianday('now'))
        OR lr.status IN (${ACTIVE_LIST})
        OR sa.status IN (${ACTIVE_LIST})
        OR EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests q
                    WHERE q.thread_id = t.thread_id AND q.status = 'pending')
      )
    ORDER BY t.updated_at DESC
    LIMIT ?`;
}

function parse(text: string | null): Record<string, any> {
  if (!text) return {};
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" ? value : {};
  } catch {
    return {};
  }
}

/** How a thread reads at a glance: waiting on you, working, finished since you last looked, or quiet. */
export function threadState(input: {
  pending: number;
  runStatus: string | null;
  subagentStatus: string | null;
  runCompletedAt: string | null;
  lastVisitedAt: string | null;
}): T3ThreadState {
  if (input.pending > 0) return "needs-input";
  if (ACTIVE.includes(input.runStatus ?? "") || ACTIVE.includes(input.subagentStatus ?? "")) return "running";
  const completed = Date.parse(input.runCompletedAt ?? "");
  if (!isNaN(completed)) {
    const visited = Date.parse(input.lastVisitedAt ?? "");
    if (isNaN(visited) || visited < completed) return "unread";
  }
  return "idle";
}

/** The open threads, most recently changed first. */
export function readOpenT3Threads(db: Database, limit = 300): T3ThreadSummary[] {
  const rows = db.query(threadSql(db)).all(limit) as Row[];
  return rows.map((row) => {
    const payload = parse(row.payload_json);
    const rootThreadId = typeof payload.lineage?.rootThreadId === "string" && payload.lineage.rootThreadId !== row.thread_id
      ? payload.lineage.rootThreadId
      : null;
    const state = threadState({
      pending: row.pending,
      runStatus: row.run_status,
      subagentStatus: row.subagent_status,
      runCompletedAt: row.run_completed_at,
      lastVisitedAt: typeof payload.lastVisitedAt === "string" ? payload.lastVisitedAt : null,
    });
    return {
      id: row.thread_id,
      title: row.title ?? "",
      projectId: row.project_id ?? "",
      projectName: row.project_title ?? "",
      rootThreadId,
      state,
      waitingFor: state === "needs-input" ? requestTitle(row.pending_kind ?? "") : null,
      branch: typeof payload.branch === "string" ? payload.branch : null,
      updatedAt: row.updated_at ?? "",
    };
  });
}
