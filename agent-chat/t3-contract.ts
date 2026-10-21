// Shared transport contract for T3 Code threads (cmux Agent Home): what the
// server sends the chat page about a thread, and what the page sends back.
// Types only, so the page's bundle takes nothing from the server.

/** T3's model selection: a provider instance, a model, and its option values. */
export interface T3ModelSelection {
  instanceId?: string;
  model?: string;
  options?: { id: string; value: string | boolean }[];
}

/** A selection naming both a provider instance and a model, as T3 commands take it. */
export type T3FullSelection = T3ModelSelection & { instanceId: string; model: string };

export interface T3QuestionOption {
  label: string;
  description?: string;
  value?: string;
}

export interface T3Question {
  id: string;
  header: string;
  question: string;
  options: T3QuestionOption[];
  multiSelect?: boolean;
  allowCustomAnswer?: boolean;
  initialAnswer?: string;
}

/** A pending request the chat shows as an approval card or a question card. */
export interface T3PendingRequest {
  id: string;
  kind: string;
  title: string;
  detail?: string;
  /** Approval requests take a decision; questions take answers. */
  isApproval: boolean;
  /** For `user_input`: the questions, answered in order. */
  questions?: T3Question[];
  /** False when the agent can no longer take the answer here (answer it in T3). */
  answerable: boolean;
  /** Questions T3 lets the user skip without answering. */
  dismissible: boolean;
}

export type T3Decision = "accept" | "acceptForSession" | "decline";
/** Question id to an option value, values, or typed text. */
export type T3Answers = Record<string, string | string[]>;

export type T3BackgroundKind = "subagent" | "command" | "monitor" | "background_task";

/** What T3's background-work banner shows. */
export interface T3BackgroundWork {
  title: string;
  items: { taskId: string; kind: T3BackgroundKind; label: string; childThreadId?: string }[];
  /** Subagents and monitors hold the thread: it isn't done until they end. */
  waiting: boolean;
}

/** A model option T3 offers, e.g. reasoning effort or fast mode. */
export interface T3ModelOption {
  id: string;
  label: string;
  type: "select" | "boolean";
  choices?: { id: string; label: string; description?: string; isDefault?: boolean }[];
}

export interface T3ModelProvider {
  instanceId: string;
  driver: string;
  name: string;
  models: { slug: string; name: string; isDefault?: boolean; options: T3ModelOption[] }[];
}

/** What a new thread in a project starts with: the project's default model,
 * else the model of the project's most recent thread, and that thread's modes. */
export interface T3LaunchDefaults {
  modelSelection: T3ModelSelection | null;
  runtimeMode: string;
  interactionMode: string;
}

/** A T3 project a new chat can start in. */
export interface T3Project {
  id: string;
  name: string;
  root: string;
  defaults: T3LaunchDefaults;
}

/** The New chat pane's `t3-launch` request. */
export interface T3LaunchInput {
  projectId: string;
  text: string;
  model: T3FullSelection;
  runtimeMode: string;
  interactionMode: string;
}
