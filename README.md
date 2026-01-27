# 🦞 Lobster Workflows

A collection of ready-to-use [Lobster](https://github.com/clawdbot/lobster) workflow templates for [Moltbot](https://github.com/clawdbot/clawdbot) (formerly Clawdbot).

Lobster is a deterministic workflow engine — typed pipelines with approval gates, state tracking, and token-efficient automation. These workflows replace freeform LLM orchestration with predictable, repeatable pipelines.

## Workflows

| Workflow | Steps | Description |
|----------|-------|-------------|
| [`x-morning-post`](workflows/x-morning-post.lobster) | 8 | Select a content seed, generate a draft via LLM, approve, and post to X |
| [`daily-roll-call`](workflows/daily-roll-call.lobster) | 10 | Create a thread, ping all agents, collect reports, compile a fleet summary |
| [`pr-review`](workflows/pr-review.lobster) | 7 | Fetch GitHub PR state, diff against last run, summarize changes, post update |
| [`deploy-announce`](workflows/deploy-announce.lobster) | 8 | Fetch release info, generate announcement, approve, post to channel + X |
| [`knowledge-extraction`](workflows/knowledge-extraction.lobster) | 13 | Read daily notes, extract durable facts, write to a knowledge graph |

## Why Lobster?

| Without Lobster | With Lobster |
|-----------------|--------------|
| LLM re-plans every step | Deterministic pipeline |
| 10+ tool calls per run | 1 workflow call |
| "Please don't send" (hope) | `approve` = hard stop |
| Forgets what it did yesterday | Stateful — tracks cursors |

## Quick Start

### 1. Install Lobster

Lobster ships with [Moltbot](https://github.com/clawdbot/clawdbot). If you have Moltbot, you have Lobster.

### 2. Copy a Workflow

```bash
# Clone this repo
git clone https://github.com/jdrhyne/lobster-workflows.git

# Copy a workflow to your Moltbot workspace
cp lobster-workflows/workflows/pr-review.lobster ~/my-workspace/workflows/
```

### 3. Customize

Each workflow has a **Platform Customization** section at the top explaining what to adapt:

```yaml
# ── Platform Customization ──────────────────────────────────────────────
# This workflow uses Moltbot's message tool for notifications.
# Adapt these for your messaging platform:
#   - channel IDs → your platform's channel/group/chat identifiers
#   - thread-create → may not be available on all platforms
#   - message formatting → some platforms use markdown, others don't
# ────────────────────────────────────────────────────────────────────────
```

All channel/bot references use placeholders like `YOUR_CHANNEL_ID` and `BOT_ID_1` — replace these with your actual values.

### 4. Run

```bash
# Run a workflow
lobster run workflows/pr-review.lobster --args-json '{"repo":"owner/repo","pr":"123"}'

# Run with custom inputs
lobster run workflows/deploy-announce.lobster --args-json '{"repo":"owner/repo","channel":"123456"}'

# Run knowledge extraction (no messaging required)
lobster run workflows/knowledge-extraction.lobster
```

## Workflow Details

### 🐦 X Morning Post

Human-in-the-loop content publishing pipeline.

```
Parse content seeds → Select seed → Confirm → Generate draft (LLM) → Approve → Post via bird CLI → Mark posted
```

**Inputs:** `seed_id` (optional), `seeds_file` (path to your content seeds)
**Tools:** [bird CLI](https://github.com/steipete/bird), LLM via `clawd.invoke`
**Approval gates:** 2 (seed selection + final post)

---

### 📋 Daily Roll Call

Multi-agent coordination pipeline. Collects status reports from all agents and compiles a summary.

```
Create thread → Ping agents → Request reports → Self-report → Wait → Read responses → Compile summary → Post
```

**Inputs:** `reports_channel`, `wait_minutes`, `bot_ids`, `agent_labels`
**Tools:** Moltbot message + sessions_send
**Approval gates:** 0 (fully automated)
**Note:** Requires a platform with threading support (Discord, Slack). For non-threaded platforms, use a dedicated channel.

---

### 🔍 PR Review

GitHub PR monitoring with change detection. Only reports when something changes.

```
Fetch PR details → Check CI status → Diff against last run → Generate summary (LLM) → Approve → Post → Save state
```

**Inputs:** `repo` (required), `pr` (required), `channel` (optional), `changes_only` (default: true)
**Tools:** `gh` CLI, LLM via `clawd.invoke`
**Approval gates:** 1 (before posting)

---

### 🚀 Deploy Announce

Release announcement pipeline with optional cross-posting.

```
Fetch release → Find previous tag → Fetch changelog → Generate announcement (LLM) → Approve → Post to channel → Optionally post to X → Save state
```

**Inputs:** `repo` (required), `channel` (required), `tag` (optional, defaults to latest), `post_to_x` (default: false)
**Tools:** `gh` CLI, bird CLI, LLM via `clawd.invoke`
**Approval gates:** 2 (channel post + X post)

---

### 🧠 Knowledge Extraction

Extract durable facts from daily notes into a structured knowledge graph. Pairs with the [knowledge-graph skill](https://github.com/jdrhyne/agent-skills/tree/main/clawdbot/knowledge-graph).

```
Read daily notes → List existing entities → Extract facts (LLM) → Review → Approve → Create entities → Write facts → Log → Save state
```

**Inputs:** `date` (default: today), `auto_approve` (default: false), `workspace` (default: current dir)
**Tools:** LLM via `clawd.invoke`, filesystem
**Approval gates:** 1 (fact approval, can be auto-skipped)
**No messaging required** — this workflow is entirely file-based.

## Platform Support

These workflows use Moltbot's `message` tool, which routes to whatever platform you have configured:

| Platform | Threads | Notes |
|----------|---------|-------|
| Discord | ✅ | Full support — threads, reactions, embeds |
| Slack | ✅ | Full support — threads, reactions |
| Telegram | ❌ | Use dedicated channels instead of threads |
| Signal | ❌ | Use dedicated groups instead of threads |

Workflows that don't use messaging (like `knowledge-extraction`) work on any platform or none at all.

## Anatomy of a Lobster Workflow

```yaml
name: my-workflow
description: What it does
version: "1.0.0"

inputs:
  my_input:
    type: string
    description: What this input controls
    default: "sensible-default"

steps:
  - id: step_1
    description: What this step does
    command: shell-command-here
    output: json

  - id: step_2
    description: LLM-powered step
    command: clawd.invoke
    args:
      tool: sessions_spawn
      task: "Generate something based on ${step_1.stdout}"

  - id: approval
    description: Human checkpoint
    command: approve
    args:
      prompt: "Ready to proceed?"
    approval: required

  - id: final_step
    description: Do the thing
    command: some-command
    condition: $approval.approved

output:
  success: $final_step.success
```

## Contributing

Have a useful workflow? PRs welcome!

1. Add your `.lobster` file to `workflows/`
2. Include a **Platform Customization** comment block
3. Use placeholder values (`YOUR_CHANNEL_ID`, etc.) — not real IDs
4. Add a description to this README
5. Submit a PR

## Related

- [Lobster](https://github.com/clawdbot/lobster) — The workflow engine
- [Moltbot](https://github.com/clawdbot/clawdbot) — The AI agent platform
- [Agent Skills](https://github.com/jdrhyne/agent-skills) — Skills and prompts for AI agents

## License

MIT

## Author

Jonathan Rhyne ([@jdrhyne](https://github.com/jdrhyne))
