# Agent Home

Agent Home is this fork's main feature. It turns cmux into one place to run and track all agent work. Work is grouped as Project → Task → agents. The screen is built around what each agent is doing right now, rather than around terminals. The approved design is the interactive mockup in [agent-home-mockup.html](agent-home-mockup.html).

## What the user sees

- **Left sidebar.**
  - Three views: *Needs you* (with a count), *Running* (animated), and *Ready for review*.
  - *Projects*, each with its tasks nested underneath. Each task shows a status dot and a ⌘1–9 shortcut on hover.
  - *Unsorted threads* for imported threads that don't belong to a task yet.
  - Today's spend and token use at the bottom.
- **Task view.**
  - Header: project, title, branch, PR with check status, agent count, elapsed time and cost.
  - A segmented control to switch between *Overview*, *Sessions* and *Changes*.
- **Overview, left column: one card per agent.** Each card shows:
  - the agent's kind and model
  - elapsed time and a ring for how much context it has used
  - a live line saying what it's doing now
  - its plan, with steps ticking off
  - Allow / Always allow / Deny buttons when it's asking permission
- **Overview, right column:** the pull request and its checks, the changed files with +/− counts, and a timeline.
- **Composer.** A floating message box that sends text to the chosen agent's terminal.
- **Sessions** shows the existing terminal tabs. **Changes** opens the existing diff viewer.
- **⌘K** searches tasks and runs actions. Confirmations appear as small pop-ups.

## Model

| Concept | Backed by | Notes |
| --- | --- | --- |
| Project | workspace group (`TabManager` groups, `CmuxWorkspaces/Values/WorkspaceGroup.swift`) | Uses the existing name, colour and icon. |
| Task | workspace (`Sources/Workspace.swift`) | Linked to a branch or worktree. Status comes from `WorkspaceTaskStatus`. |
| Agent | an agent session on a panel of the task's workspace | Lifecycle: `workspace.agentLifecycleStatesByPanelId`. |

No new persistence is needed for these. Projects and tasks are saved in the existing session snapshot. The T3 import adds one small mapping file (phase 6).

## Where each piece of data comes from

| UI element | Source (in-process) | Status |
| --- | --- | --- |
| Lifecycle (running, idle, needs input) | `Workspace+PanelLifecycle.swift:33`, `WorkspaceSidebarAgentRuntimeObservationModel` | exists |
| Permission request plus approve/deny | `FeedCoordinator.shared.store` (`WorkstreamStore`, `.permissionRequest`). Reply with `FeedCoordinator.shared.deliverReply(requestId:decision:)`. Map to the workspace with `FeedCoordinator.resolveTargets(for:)`, as `AgentInboxProjection` does. | exists |
| "Doing now" line | latest `.toolUse` / `.userPrompt` per `workstreamId` in `WorkstreamStore.items` | exists |
| Plan checklist | `WorkstreamPayload.todos` plus its parser | needs a one-line producer (phase 5) |
| Model, context %, cost | `AgentUsageSnapshot` via `SidebarAgentUsageCoordinator` into `sidebarMetadata.agentUsageByStatusKey` | exists, but only while the agent-usage sidebar setting is on |
| Daily spend | sum of `AgentUsageSnapshot.estimatedCost` | new aggregation |
| PR number and state | `sidebarMetadata.pullRequest` (`SidebarPullRequestState`) | exists |
| PR checks | none | new: `gh pr checks` or the REST check-runs call, next to `PullRequestProbeService` |
| Changed files and +/− | `WorkspaceChangesService.changedFiles(forDirectory:)` | exists |
| Composer send | `TerminalController.shared.v2MobileTerminalPaste(... "submit_key": "return")`, or `FeedCoordinator.sendTextToWorkstream` | exists |

## Build phases

Each phase ends with a tagged dev build that works (`CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag agent-home`). That build installs as "cmux DEV agent-home", next to the real cmux.app, and never replaces it.

0. **Toolchain and baseline.** Install Xcode and the Metal toolchain, run `./scripts/setup.sh`, and build an unmodified tagged app.
1. **Data layer.**
   - Add a new package, `Packages/macOS/CmuxAgentHome`. It holds pure value types (`AgentHomeTask`, `AgentHomeAgent`, `AgentHomeAttention`) and a projection that builds them from snapshots, with unit tests.
   - Add app glue in `Sources/AgentHome/AgentHomeStore.swift`: a `@MainActor @Observable` store that observes workspaces, groups, lifecycle, `WorkstreamStore`, usage and changes.
2. **Sidebar.**
   - Add an "Agent Home" sidebar provider modelled on Conversations: an ID and descriptor in `CmuxExtensionSidebarSelection.swift`, plus one branch in `ContentView.swift` next to `ConversationSidebarView`.
   - Contents: the three views, the Projects → Tasks tree and the usage meter.
3. **Task overview panel.**
   - Add a new `PanelType` case modelled on `WorkspaceTodoPanel` (`Sources/Panels/WorkspaceTodoPanel.swift`, rendered in `PanelContentView.swift`). Handle the new case in every exhaustive switch over `PanelType`; `grep 'case .notifications:'` finds them.
   - Add the agent cards, with approvals wired through `FeedRowActions.bound()` logic (`FeedPanelView.swift:921`), plus the PR, changes and timeline column.
4. **Composer.** Message box, agent picker, `/` commands and `@` mentions, sent with the agent's submit key.
5. **Fill the gaps.**
   - In `WorkstreamStore.decode`'s `.preToolUse` case, turn Claude `TodoWrite` into `.todos`.
   - Add PR checks.
   - Add the daily usage total.
   - Keep the usage sampler running whenever Agent Home is on.
6. **T3 Code import.**
   - Read `~/.t3/userdata/statev2.sqlite` read-only, from `orchestration_v2_projection_threads` and `projection_thread_pull_requests`.
   - Group threads into tasks by project plus branch or worktree, and create groups and workspaces with the worktree as the working directory.
   - Threads with no project go to *Unsorted*, which offers a sorting flow.
   - Each task keeps "Open in T3 Code" links.
7. **Polish.**
   - Motion: activity shimmer, pulses, a card transition when an approval resolves, and pop-ups.
   - ⌘K actions, ⌘1–9, and a light-mode pass.
   - Native materials (`NSVisualEffectView` sidebar) and SF Symbols in place of the mockup's SVGs.

## Staying mergeable with upstream

Almost all new code lives in new files: `Packages/macOS/CmuxAgentHome`, `Sources/AgentHome/` and `docs/fork/`. Existing files only get registration points:

- `CmuxExtensionSidebarSelection.swift`: provider ID and descriptor
- `ContentView.swift`: one sidebar branch
- `Panel.swift`, `PanelContentView.swift` and the exhaustive `PanelType` switches: new panel case
- `WorkstreamStore.swift`: TodoWrite decoding

Sync with `git fetch upstream && git merge upstream/main` on `main`, then merge `main` into feature branches. Never force-push over a merge.

## Status

- **Phase 1, pure core: done.** `Packages/macOS/CmuxAgentHome` contains:
  - the models
  - `AgentHomeProjection` (task status, filters, ⌘1–9 order, totals)
  - `AgentActivityDescriber` (the "doing now" line)
  - `T3CodeStateReader` (read-only SQLite)
  - `T3ThreadGrouping`
  - 25 tests, all passing
- **First run on the owner's T3 data (2026-10-19):** 1,891 active threads became 32 tasks, with 1,727 left unsorted. 1,707 of those are on a default branch and 20 have no project. The sorting flow in phase 6 is what clears that backlog.
- **Phase 0, toolchain: done (2026-10-20).** Upstream builds under Xcode 27.1 even though it pins 26. The package is wired into `cmux.xcodeproj` and passes `swift test` (26 tests).
- **Phase 2, sidebar: first version running in the tagged build.**
  - Agent Home is an always-available built-in sidebar (`cmux.sidebar.agentHome`), not a beta setting.
  - It shows the three views with counts, then Projects. Each project row opens the group's anchor workspace as the project home; the remaining workspaces are its tasks.
  - Tasks have status dots and ⌘1–9 hints on hover.
  - Still to do: the ⌘1–9 key bindings themselves, collapsing projects, and the usage meter.

- **Phase 3, task overview and agent cards: first version running (2026-10-20).**
  - With Agent Home as the sidebar, every task gets a header (project, title, branch, PR, agent count, elapsed time, cost) and an Overview / Sessions switch.
  - Overview replaces the terminals by marking the selected workspace not visible (the workspace-switching path), because portal-hosted terminals can draw above SwiftUI. Sessions shows the terminals.
  - Agent cards show the title (the session's first prompt, unless you named the tab), model, elapsed time, context ring, live "doing now" line, plan, the last reply when idle, and Allow / Always allow / Deny for pending permission requests.
  - The side column shows the PR and its checks, plus changed files refreshed every 10 s. A composer sends text to the chosen agent through the Feed's send-text path.
  - Verified live with Claude Code 2.1.303: title, model, context %, Working/Idle, live activity line, last reply and changed files.
  - Not verified live: approvals. The owner's Claude runs in auto mode even with `--permission-mode default`, so no permission request was raised.
  - Plans: this Claude Code version has no `TodoWrite` or task-list tool, so Claude cards show no plan for now. Agents that report todos still do.
  - Agent cards read the Feed's in-memory items (`FeedCoordinator.shared.store`), not `~/.cmuxterm/workstream.jsonl`, which redacts paths.

- **Chat-first rework (2026-10-20):** T3 Code is the source of truth. T3 threads are tasks with their sub-threads nested, opened as chat plus terminal, with an Overview tab and New chat. Approvals were verified live: a command request in an approval-required thread was answered from the in-chat card and resolved in T3 as accept.
- **Open work only; working, done, verify (2026-10-20):**
  - The T3 reader skips settled tasks (their root thread's `settledOverride` is `settled`) and their sub-threads, plus snoozed threads. On the owner's data that's about 45 of 1,930 threads, read in about 24 ms. Threads with a live run or pending request, and tasks open in cmux, are always read.
  - Task states:
    - **Needs you:** amber.
    - **Working:** pulse. The filter is renamed from "Running".
    - **Done:** a finished, unsettled run. It shows a green check, filled until the user has seen it (T3's rule: the run finished after `lastVisitedAt`), and amber if the run stopped early. Done tasks are counted under "Ready for review".
  - Opening a thread, or watching a run finish, sends `thread.visit`.
  - **Mark verified** (header button, or ✓ on row hover) sends `thread.settle` through the sidecar (`POST /api/t3/threads/<id>/settle`). It closes the task's workspace, which asks first if something is still running. If the task was on screen, it opens the next task waiting for review. A toast offers Undo (`thread.unsettle`) for 6 s.
  - Verified live on a throwaway thread: verify from the header and from the row, then undo.
- **Pull requests (2026-10-20):**
  - A sidebar row opens the user's GitHub pull requests in the main area:
    - **To review:** `review-requested:@me`, split into new and "asked again after your review".
    - **Yours:** `author:@me`, split into "Needs you" (conflicts, failing checks, changes requested, ready to merge) and "Waiting".
  - Data comes from one `gh api graphql` call, every 2 minutes or on ⌘R, with one retry because GitHub search sometimes returns 502.
  - Rows show:
    - **Status:** CI, review state, draft and conflicts.
    - **Activity:** comments, size, author, and when it was last updated.
    - **Links:** a T3 chip when a T3 thread links the PR.
  - Hover actions:
    - **Review with agent:** a New chat prefilled with a review prompt, in the project whose git origin, or else folder name, matches the repository.
    - **Open thread:** when a T3 thread links the PR.
    - **Open in your browser.**
  - Clicking a row opens the PR in a workspace: cmux's browser beside a terminal in the matched project. Private repositories need a one-time GitHub sign-in in cmux's browser.
  - New chat now lists every T3 project, not only those with open work.
- **Models and questions in the chat (2026-10-20):**
  - A T3 chat's composer shows the thread's model, reasoning level and fast mode. They're read from the thread's `modelSelection`, and the choices come from T3's `server.getConfig` providers (cached for 60 s). Changing one dispatches `thread.model-selection.set`. Option values the new model also accepts are kept. Verified live in both directions: a change in cmux landed in T3, and a change in T3 showed in cmux.
  - When the agent asks questions (`user_input` requests), a card above the composer shows them one at a time. It shows the header, a progress count and option rows with 1–9 shortcuts, plus Back, Next/Submit for multi-select, and Skip when T3 allows it. Typing in the composer answers the current question with custom text. Answers go out as `runtime-request.respond` with `answers`, keyed by question id, using the option value or label, or an array for multi-select. Answered questions show in the transcript as the user's reply ("Header: answer").
  - The card's flows (single pick, multi-select, typed answer) and the model picker are checked in the gallery (`/gallery#t3-thread`). Live, questions on the test thread were answered from elsewhere within seconds every time, so the card wasn't clicked against a live request.
- **Phase 6, T3 Code integration: first version running (2026-10-20).**
  - `AgentHomeT3Model` reads `~/.t3/userdata/statev2.sqlite` read-only every 60 s, off the main thread, and groups threads into tasks.
  - Each T3 project is matched to a cmux project by: the group's `externalID` (`t3:<project id>`), then the anchor workspace's folder versus T3's `workspace_root`, then the name.
  - Unopened T3 tasks appear dimmed under their project, tagged "T3" with a thread count, three at a time plus "N more from T3". T3 projects with no cmux project are listed under "From T3 Code". Leftover threads show as one "Unsorted T3 threads" count.
  - Clicking a T3 task creates the project if it's missing (tagged with the `t3:` external id), opens a workspace in the task's worktree or the project root, files it under the project, selects it, and records the link in UserDefaults (`agentHomeT3TaskLinks`).
  - On the owner's data, the dev build showed matches under devjags-portfolio and oorva-app, T3-only projects (suttru-tn, oorva-landing, oorva-bookeeping, workspace), and 1,742 unsorted threads.
  - Not built yet: the sorting flow for unsorted threads, resuming a T3 thread's agent session in the new terminal, and "Open in T3".

### Daily app: cmux Home

Build or update the fork's everyday app:

```bash
CMUX_DEV_BACKEND_MODE=local CMUX_STAGING_LOCAL_SIGNING=1 ./scripts/reloads.sh --name "cmux Home" \
  --bundle-id com.cmuxterm.app.staging.home \
  --derived-data ~/Library/Developer/Xcode/DerivedData/cmux-home
```

- **Separate from upstream:** it's a Release build with its own name and app ID, next to `/Applications/cmux.app`.
- **Signing:** `CMUX_STAGING_LOCAL_SIGNING=1` drops the entitlements tied to Manaflow's signing team, as `reload.sh` already does for local Release builds. Cloud tunnels, which need the network-extension entitlement, aren't available in cmux Home.
- **No Sparkle updates:** upstream never compares a `com.cmuxterm.app.staging.*` ID against its Sparkle feed, so cmux Home can't be auto-replaced by upstream cmux.
- **First-launch defaults:** `AgentHomeFirstLaunchDefaults` selects the Agent Home sidebar, turns on the Agent Chat flag and per-agent usage, and turns off anonymous telemetry. It runs once per app ID, so later changes stick.
- **Depends on:**
  - `agentChat.startCommand` in `~/.config/cmux/cmux.json`, which runs `agent-chat/server.ts` from this checkout with bun. Keep this checkout in place.
  - T3 Code running, and the Keychain token `cmux-agent-home-t3-token`.
  - A `~/projects/t3code` checkout close to the installed T3 version.

### Building on this machine

- **Commands:** `CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag agent-home`, with Homebrew's rustup on `PATH` (`/opt/homebrew/opt/rustup/bin`). Zig must be 0.16 (`brew install zig@0.16`).
- **Launching:** `--launch` needs Manaflow team credentials, so build without it and open the printed app path. Agent Home is selected for the dev build with `defaults write com.cmuxterm.app.debug.agent.home cmuxExtensionSidebarProviderId cmux.sidebar.agentHome`.
- **Stuck at "Resolve Package Graph":** Xcode's own binary-artifact download can stall. Download the Sentry and iroh-ffi zips with curl, check their SHA-256 against the package manifests, and copy them into `~/Library/Caches/org.swift.swiftpm/artifacts/` under the URL with every non-alphanumeric character replaced by `_`.
- **Stray CLI wrapper:** `reload.sh` drops a `cmux` wrapper into the first directory on `PATH`. If that's rustup's folder, remove it.

### Running the package tests without Xcode (historical)

On this machine the Command Line Tools are mixed versions:

- `swift build` and `swift test` crash with a dyld error.
- The macOS 27 SDK needs Swift 6.4, but the compiler is Swift 6.3.
- The Testing framework doesn't match its macro plugin.

Until Xcode is installed, compile against `MacOSX26.5.sdk` with `swiftc`. Run the tests through a shim that strips the `@Suite`/`@Test` macros and calls each test directly. The shim generator lived at `/tmp/agenthome-runner/make_shim.py`, outside the repo. With Xcode installed, use plain `swift test` in the package directory.

### Localization

User-facing strings use `String(localized: "agentHome.…", defaultValue: …)` keys with English text only. This fork doesn't ship upstream's nine translations. The keys let them be added later without code changes.

## Open decisions

- App name, bundle ID and icon for a personal release build. Dev builds already get their own identity.
- Whether Agent Home becomes the default sidebar, or stays a switchable provider.
