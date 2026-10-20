// cmux Agent Home's New chat pane: the composer that starts a T3 Code thread.
// It has the same model, reasoning and fast-mode controls as a T3 chat, plus
// the project, access mode and plan mode T3 asks for when a thread starts.
// Once T3 starts the thread, the page becomes that thread's chat.

import { useEffect, useMemo, useState } from "react";
import { useCtx } from "../context";
import type { T3ModelProvider, T3ModelSelection, T3Project } from "../session";
import { CmdkMenu } from "./CmdkMenu";
import { isCtrlJ, insertNewlineAtCaret } from "./CommandMenu";
import { ArrowUp, FolderIcon, PinwheelSpinner, PlanIcon, ShieldIcon } from "./icons";
import { T3ModelControls } from "./T3Controls";
import { HintTooltip } from "./Tooltips";
import { useAutoGrow } from "../hooks/useAutoGrow";

const T3_NEW_CHAT_TEXT = {
  placeholder: "What should the agent do?",
  project: "Project",
  noProjects: "No T3 projects yet. Add one in T3 first.",
  loadingProjects: "Loading projects…",
  access: "Access",
  plan: "Plan mode: the agent plans first and waits for your go-ahead",
  start: "Start",
  hint: "Enter to start · Shift+Enter for newline · Runs in T3 and syncs both ways",
  connecting: "Connecting to cmux…",
};

const RUNTIME_MODES: { id: string; label: string; description: string }[] = [
  { id: "full-access", label: "Full access", description: "Runs commands and edits files without asking" },
  { id: "auto", label: "Auto", description: "Asks only when an action looks risky" },
  { id: "auto-accept-edits", label: "Accept edits", description: "Edits files freely, asks before commands" },
  { id: "approval-required", label: "Ask first", description: "Asks before every edit and command" },
];

type FullSelection = T3ModelSelection & { instanceId: string; model: string };

function fullSelection(selection: T3ModelSelection | null | undefined): FullSelection | null {
  return selection?.instanceId && selection.model ? (selection as FullSelection) : null;
}

/** T3's default model, for a project with no default and no earlier threads. */
function catalogDefault(catalog: T3ModelProvider[] | null): FullSelection | null {
  for (const provider of catalog ?? []) {
    const model = provider.models.find((m) => m.isDefault);
    if (model) return { instanceId: provider.instanceId, model: model.slug };
  }
  const provider = catalog?.[0];
  return provider?.models[0] ? { instanceId: provider.instanceId, model: provider.models[0].slug } : null;
}

export function T3NewChat() {
  const { ready, lastError, clearError, t3Projects, requestT3Projects, t3Models, requestT3Models, launchT3, t3LaunchPending } = useCtx();
  const params = useMemo(() => new URLSearchParams(location.search), []);
  const [text, setText] = useState(() => params.get("text") ?? "");
  const [projectId, setProjectId] = useState(() => params.get("project") ?? "");
  // Settings the user picked; until then they follow the project's defaults.
  const [model, setModel] = useState<FullSelection | null>(null);
  const [runtimeMode, setRuntimeMode] = useState<string | null>(null);
  const [interactionMode, setInteractionMode] = useState<string | null>(null);
  const [open, setOpen] = useState<"project" | "access" | null>(null);
  const taRef = useAutoGrow(text, 300);

  // Asked once connected; the model controls' own request can go out before the socket opens.
  useEffect(() => {
    if (!ready) return;
    requestT3Projects();
    requestT3Models();
  }, [ready, requestT3Models, requestT3Projects]);
  // The prefilled text has been read; keep it out of reloads and history.
  useEffect(() => {
    if (!params.has("text")) return;
    const search = new URLSearchParams(location.search);
    search.delete("text");
    const query = search.toString();
    history.replaceState(null, "", location.pathname + (query ? `?${query}` : ""));
  }, [params]);

  const project: T3Project | undefined = t3Projects?.find((p) => p.id === projectId) ?? t3Projects?.[0];
  useEffect(() => {
    if (project && project.id !== projectId) setProjectId(project.id);
  }, [project, projectId]);

  const selection = model ?? fullSelection(project?.defaults.modelSelection) ?? (project ? catalogDefault(t3Models) : null);
  const access = runtimeMode ?? project?.defaults.runtimeMode ?? "full-access";
  const plan = (interactionMode ?? project?.defaults.interactionMode) === "plan";
  const accessInfo = RUNTIME_MODES.find((m) => m.id === access) ?? RUNTIME_MODES[0];
  const canStart = ready && !t3LaunchPending && Boolean(project && selection && text.trim());

  const submit = () => {
    const prompt = text.trim();
    if (!canStart || !project || !selection || !prompt) return;
    launchT3({
      projectId: project.id,
      text: prompt,
      model: selection,
      runtimeMode: access,
      interactionMode: plan ? "plan" : "default",
    });
  };

  const projectLabel = project?.name || (t3Projects ? T3_NEW_CHAT_TEXT.project : T3_NEW_CHAT_TEXT.loadingProjects);

  return (
    <section id="composer-view">
      <div id="composer-card">
        <div className="input-wrap">
          <textarea
            ref={taRef}
            id="prompt-input"
            data-primary-textarea="true"
            placeholder={T3_NEW_CHAT_TEXT.placeholder}
            value={text}
            autoFocus
            disabled={t3LaunchPending}
            onChange={(e) => {
              setText(e.target.value);
              if (lastError) clearError();
            }}
            onKeyDown={(e) => {
              if (isCtrlJ(e)) { e.preventDefault(); insertNewlineAtCaret(text, setText, taRef); return; }
              if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
            }}
          />
        </div>
        <div className="status-row">
          <HintTooltip label={T3_NEW_CHAT_TEXT.project}>
            <span>
              <CmdkMenu
                open={open === "project"}
                onOpenChange={(next) => setOpen(next ? "project" : null)}
                className="t3-project-menu"
                trigger={
                  <button type="button" className="row-control cwd-trigger" aria-label={T3_NEW_CHAT_TEXT.project}>
                    <FolderIcon />
                    <span className="cwd-label">{projectLabel}</span>
                  </button>
                }
                groups={[{
                  id: "projects",
                  items: (t3Projects ?? []).map((p) => ({
                    id: p.id,
                    label: p.name || p.root,
                    description: p.root,
                    value: `${p.name} ${p.root}`,
                    selected: p.id === project?.id,
                    onSelect: () => {
                      setProjectId(p.id);
                      setOpen(null);
                    },
                  })),
                }]}
              />
            </span>
          </HintTooltip>
          <T3ModelControls
            selection={selection}
            catalog={t3Models}
            running={false}
            onLoad={requestT3Models}
            onChange={setModel}
          />
          <HintTooltip label={`${T3_NEW_CHAT_TEXT.access}: ${accessInfo.description}`}>
            <span>
              <CmdkMenu
                open={open === "access"}
                onOpenChange={(next) => setOpen(next ? "access" : null)}
                className="option-menu"
                trigger={
                  <button type="button" className="row-control row-select select-trigger" aria-label={T3_NEW_CHAT_TEXT.access}>
                    <span className="row-icon"><ShieldIcon /></span>
                    <span className="row-value">{accessInfo.label}</span>
                  </button>
                }
                groups={[{
                  id: "access",
                  items: RUNTIME_MODES.map((mode) => ({
                    id: mode.id,
                    label: mode.label,
                    description: mode.description,
                    selected: mode.id === access,
                    onSelect: () => {
                      setRuntimeMode(mode.id);
                      setOpen(null);
                    },
                  })),
                }]}
              />
            </span>
          </HintTooltip>
          <HintTooltip label={T3_NEW_CHAT_TEXT.plan}>
            <button
              type="button"
              aria-label={T3_NEW_CHAT_TEXT.plan}
              aria-pressed={plan}
              className={"row-control row-icon-only plan-toggle" + (plan ? " active" : "")}
              onClick={() => setInteractionMode(plan ? "default" : "plan")}
            >
              <PlanIcon />
            </button>
          </HintTooltip>
          <div className="status-row-spacer" />
          <button className="send" type="button" aria-label={T3_NEW_CHAT_TEXT.start} disabled={!canStart} onClick={submit}>
            {t3LaunchPending ? <PinwheelSpinner size={13} /> : <ArrowUp />}
          </button>
        </div>
      </div>
      {t3Projects && !t3Projects.length ? <div className="composer-error">{T3_NEW_CHAT_TEXT.noProjects}</div> : null}
      {lastError ? <div className="composer-error">{lastError}</div> : null}
      <div id="composer-hint">{ready ? T3_NEW_CHAT_TEXT.hint : T3_NEW_CHAT_TEXT.connecting}</div>
    </section>
  );
}
