// Composer controls for T3 Code threads (cmux Agent Home): the thread's model
// and reasoning, and the card for questions the agent asks. Both are T3
// commands, so a change here shows in T3 and a change in T3 shows here.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { T3Answers, T3ModelOption, T3ModelProvider, T3ModelSelection, T3Question, T3Request } from "../session";
import { CmdkMenu, type CmdkGroup } from "./CmdkMenu";
import { BarsIcon, BoltIcon, Check, Chevron, ProviderIcon } from "./icons";
import { HintTooltip } from "./Tooltips";

const T3_CONTROLS_TEXT = {
  model: "Model",
  changeModel: "Change model (syncs with T3)",
  reasoning: "Reasoning",
  fast: "Fast mode",
  loading: "Loading models…",
  next: "Next",
  submit: "Submit",
  back: "Back",
  skip: "Skip question",
  pickMany: "Pick one or more.",
};

// MARK: - Model

/** The drawn icon for a T3 provider driver. */
function iconProvider(provider: { driver: string; name: string }) {
  const id = provider.driver === "claudeAgent" ? "claude" : provider.driver;
  return { id, label: provider.name };
}

/** The reasoning option of a model: T3 calls it effort, reasoningEffort or variant. */
function reasoningOption(options: T3ModelOption[]): T3ModelOption | undefined {
  return options.find((o) => o.type === "select" && (["effort", "reasoningEffort", "variant"].includes(o.id) || o.label === "Reasoning"));
}

function selectedValue(selection: T3ModelSelection | null | undefined, option: T3ModelOption): string | boolean | undefined {
  const chosen = selection?.options?.find((o) => o.id === option.id)?.value;
  if (chosen !== undefined) return chosen;
  if (option.type === "boolean") return false;
  return option.choices?.find((c) => c.isDefault)?.id;
}

/** Keeps the option values the next model also accepts. */
function carriedOptions(selection: T3ModelSelection | null | undefined, next: T3ModelOption[]): { id: string; value: string | boolean }[] {
  const carried: { id: string; value: string | boolean }[] = [];
  for (const prior of selection?.options ?? []) {
    const option = next.find((o) => o.id === prior.id);
    if (!option) continue;
    if (option.type === "boolean" && typeof prior.value === "boolean") carried.push(prior);
    if (option.type === "select" && option.choices?.some((c) => c.id === prior.value)) carried.push(prior);
  }
  return carried;
}

type FullSelection = T3ModelSelection & { instanceId: string; model: string };

function withOption(selection: FullSelection, id: string, value: string | boolean): FullSelection {
  const options = (selection.options ?? []).filter((o) => o.id !== id);
  return { ...selection, options: [...options, { id, value }] };
}

export function T3ModelControls({
  selection,
  catalog,
  running,
  onLoad,
  onChange,
}: {
  selection: T3ModelSelection | null | undefined;
  catalog: T3ModelProvider[] | null;
  running: boolean;
  onLoad(): void;
  onChange(selection: T3ModelSelection & { instanceId: string; model: string }): void;
}) {
  const [open, setOpen] = useState<"model" | "reasoning" | null>(null);
  useEffect(() => { if (!catalog) onLoad(); }, [catalog, onLoad]);

  const provider = catalog?.find((p) => p.instanceId === selection?.instanceId);
  const model = provider?.models.find((m) => m.slug === selection?.model);
  const reasoning = model ? reasoningOption(model.options) : undefined;
  const fast = model?.options.find((o) => o.id === "fastMode" && o.type === "boolean");
  const label = model?.name ?? selection?.model ?? (catalog ? T3_CONTROLS_TEXT.model : T3_CONTROLS_TEXT.loading);

  const groups = useMemo((): CmdkGroup[] => {
    if (!catalog) return [];
    // The thread's provider first; T3 decides whether another one can take over.
    const ordered = [...catalog].sort((a, b) => Number(b.instanceId === selection?.instanceId) - Number(a.instanceId === selection?.instanceId));
    return ordered.map((p) => ({
      id: p.instanceId,
      label: p.name,
      icon: <ProviderIcon provider={iconProvider(p)} />,
      items: p.models.map((m) => ({
        id: `${p.instanceId}:${m.slug}`,
        label: m.name,
        value: `${p.name} ${m.name} ${m.slug}`,
        selected: p.instanceId === selection?.instanceId && m.slug === selection?.model,
        onSelect: () => {
          if (p.instanceId === selection?.instanceId && m.slug === selection?.model) return;
          const options = carriedOptions(selection, m.options);
          onChange({ instanceId: p.instanceId, model: m.slug, ...(options.length ? { options } : {}) });
        },
      })),
    }));
  }, [catalog, onChange, selection]);

  const current = selection?.instanceId && selection.model ? (selection as T3ModelSelection & { instanceId: string; model: string }) : null;
  const reasoningValue = reasoning ? String(selectedValue(selection, reasoning) ?? "") : "";
  const reasoningChoices = reasoning?.choices ?? [];
  const reasoningIndex = Math.max(0, reasoningChoices.findIndex((c) => c.id === reasoningValue));
  const fill = (index: number) => Math.max(1, Math.round(((index + 1) / Math.max(1, reasoningChoices.length)) * 4));

  return (
    <div className="t3-model-controls">
      <HintTooltip label={T3_CONTROLS_TEXT.changeModel}>
        <span>
          <CmdkMenu
            open={open === "model"}
            onOpenChange={(next) => {
              if (next && !catalog) onLoad();
              setOpen(next ? "model" : null);
            }}
            className="t3-model-menu"
            trigger={
              <button type="button" className={"row-control provider-model-trigger select-trigger" + (running ? " provider-running" : "")} aria-label={T3_CONTROLS_TEXT.changeModel}>
                {provider ? <ProviderIcon provider={iconProvider(provider)} /> : null}
                <span className="row-value">{label}</span>
                <span className="chev"><Chevron /></span>
              </button>
            }
            groups={groups}
          />
        </span>
      </HintTooltip>
      {reasoning && current && reasoningChoices.length ? (
        <HintTooltip label={reasoning.label}>
          <span>
            <CmdkMenu
              open={open === "reasoning"}
              onOpenChange={(next) => setOpen(next ? "reasoning" : null)}
              className="option-menu"
              trigger={
                <button type="button" className="row-control row-select select-trigger" aria-label={reasoning.label}>
                  <span className="row-icon"><BarsIcon filled={fill(reasoningIndex)} /></span>
                  <span className="row-value">{reasoningChoices[reasoningIndex]?.label ?? reasoningValue}</span>
                </button>
              }
              groups={[{
                id: reasoning.id,
                items: reasoningChoices.map((choice, index) => ({
                  id: choice.id,
                  label: choice.label,
                  description: choice.description,
                  icon: <BarsIcon filled={fill(index)} />,
                  selected: choice.id === reasoningValue,
                  onSelect: () => onChange(withOption(current, reasoning.id, choice.id)),
                })),
              }]}
            />
          </span>
        </HintTooltip>
      ) : null}
      {fast && current ? (
        <HintTooltip label={fast.label || T3_CONTROLS_TEXT.fast}>
          <button
            type="button"
            aria-label={fast.label || T3_CONTROLS_TEXT.fast}
            aria-pressed={selectedValue(selection, fast) === true}
            className={"row-control row-icon-only fast-toggle" + (selectedValue(selection, fast) === true ? " active" : "")}
            onClick={() => onChange(withOption(current, fast.id, selectedValue(selection, fast) !== true))}
          >
            <BoltIcon />
          </button>
        </HintTooltip>
      ) : null}
    </div>
  );
}

// MARK: - Questions

interface Draft { selected: string[]; custom?: string }

function optionValue(option: { label: string; value?: string }): string {
  return option.value ?? option.label;
}

function answerFor(question: T3Question, draft: Draft | undefined): string | string[] | null {
  const custom = question.allowCustomAnswer === false ? "" : draft?.custom?.trim() ?? "";
  if (custom) return custom;
  const selected = (draft?.selected ?? []).filter((v) => question.options.some((o) => optionValue(o) === v));
  if (question.multiSelect) return selected.length ? selected : null;
  return selected[0] ?? null;
}

/** Walks the user through a T3 question request, one question at a time.
 * Options are picked in the card; the composer types a custom answer. */
export function useT3Questions(request: T3Request | null | undefined, onAnswer: (requestId: string, answers: T3Answers) => void) {
  const questions = request && !request.isApproval && request.answerable !== false ? request.questions ?? [] : [];
  const requestId = questions.length ? request!.id : null;
  const [index, setIndex] = useState(0);
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const advanceTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    setIndex(0);
    setDrafts({});
    return () => { if (advanceTimer.current) clearTimeout(advanceTimer.current); };
  }, [requestId]);

  const active = questions[Math.min(index, questions.length - 1)];

  const finish = useCallback((next: Record<string, Draft>, from: number) => {
    // Move to the next unanswered question, or send them all.
    for (let i = from + 1; i < questions.length; i++) {
      if (answerFor(questions[i], next[questions[i].id]) === null) { setIndex(i); return; }
    }
    const answers: T3Answers = {};
    for (const question of questions) {
      const answer = answerFor(question, next[question.id]);
      if (answer === null) { setIndex(questions.indexOf(question)); return; }
      answers[question.id] = answer;
    }
    if (requestId) onAnswer(requestId, answers);
  }, [onAnswer, questions, requestId]);

  const pick = useCallback((value: string) => {
    if (!active) return;
    const current = drafts[active.id];
    if (active.multiSelect) {
      const selected = current?.selected ?? [];
      const nextSelected = selected.includes(value) ? selected.filter((v) => v !== value) : [...selected, value];
      setDrafts({ ...drafts, [active.id]: { selected: nextSelected } });
      return;
    }
    const next = { ...drafts, [active.id]: { selected: [value] } };
    setDrafts(next);
    // A beat to see the pick land before moving on.
    if (advanceTimer.current) clearTimeout(advanceTimer.current);
    const from = index;
    advanceTimer.current = setTimeout(() => finish(next, from), 180);
  }, [active, drafts, finish, index]);

  /** The composer's text as the active question's answer. False when it can't take one. */
  const answerWithText = useCallback((text: string): boolean => {
    if (!active || active.allowCustomAnswer === false || !text.trim()) return false;
    const next = { ...drafts, [active.id]: { selected: [], custom: text.trim() } };
    setDrafts(next);
    finish(next, index);
    return true;
  }, [active, drafts, finish, index]);

  const next = useCallback(() => finish(drafts, index), [drafts, finish, index]);
  const back = useCallback(() => setIndex((i) => Math.max(0, i - 1)), []);

  return {
    active: active ?? null,
    index,
    count: questions.length,
    selected: active ? drafts[active.id]?.selected ?? [] : [],
    canAdvance: active ? answerFor(active, drafts[active.id]) !== null : false,
    takesText: Boolean(active && active.allowCustomAnswer !== false),
    pick,
    answerWithText,
    next,
    back,
  };
}

export type T3QuestionFlow = ReturnType<typeof useT3Questions>;

export function T3QuestionCard({ flow, dismissible, onDismiss }: { flow: T3QuestionFlow; dismissible: boolean; onDismiss(): void }) {
  const { active, index, count, selected, pick } = flow;

  // 1–9 pick an option, as in T3, unless the user is typing.
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target;
      if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) return;
      const digit = Number.parseInt(event.key, 10);
      const option = Number.isNaN(digit) ? undefined : active.options[digit - 1];
      if (!option) return;
      event.preventDefault();
      pick(optionValue(option));
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [active, pick]);

  if (!active) return null;
  const isLast = index >= count - 1;
  return (
    <div className="t3-question" role="dialog" aria-label={active.header}>
      <div className="t3-question-head">
        <span className="t3-question-header">{active.header}</span>
        {count > 1 ? <span className="t3-question-progress">{index + 1}/{count}</span> : null}
        <span className="t3-question-spacer" />
        {dismissible ? (
          <button type="button" className="t3-question-skip" onClick={onDismiss}>{T3_CONTROLS_TEXT.skip}</button>
        ) : null}
      </div>
      <div className="t3-question-text">{active.question}</div>
      {active.multiSelect ? <div className="t3-question-hint">{T3_CONTROLS_TEXT.pickMany}</div> : null}
      <div className="t3-question-options" key={active.id}>
        {active.options.map((option, i) => {
          const value = optionValue(option);
          const isSelected = selected.includes(value);
          return (
            <button
              key={value}
              type="button"
              className={"t3-question-option" + (isSelected ? " selected" : "")}
              aria-pressed={isSelected}
              onClick={() => pick(value)}
            >
              <span className="t3-question-option-main">
                <span className="t3-question-option-label">{option.label}</span>
                {option.description && option.description !== option.label ? (
                  <span className="t3-question-option-desc">{option.description}</span>
                ) : null}
              </span>
              {isSelected ? <span className="t3-question-check"><Check /></span> : i < 9 ? <kbd>{i + 1}</kbd> : null}
            </button>
          );
        })}
      </div>
      {index > 0 || active.multiSelect ? (
        <div className="t3-request-actions">
          {index > 0 ? <button type="button" className="t3-request-btn" onClick={flow.back}>{T3_CONTROLS_TEXT.back}</button> : null}
          {active.multiSelect ? (
            <button type="button" className="t3-request-btn primary" disabled={!flow.canAdvance} onClick={flow.next}>
              {isLast ? T3_CONTROLS_TEXT.submit : T3_CONTROLS_TEXT.next}
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
