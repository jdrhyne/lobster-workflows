# PR Review Workflow
# Lobster workflow for monitoring and reviewing GitHub PRs
# Deterministic pipeline: fetch → diff → summarize → approve → post
#
# Usage:
#   lobster run workflows/pr-review.lobster --args-json '{"repo":"owner/repo","pr":"123"}'
#   lobster run workflows/pr-review.lobster --args-json '{"repo":"owner/repo","pr":"123","channel":"123456","changes_only":false}'
#
# ── Platform Customization ──────────────────────────────────────────────
# This workflow uses Clawdbot's message tool for notifications.
# Adapt these for your messaging platform:
#   - channel IDs → your platform's channel/group/chat identifiers
#   - thread-create → may not be available on all platforms (Telegram, Signal)
#   - message formatting → Discord uses markdown; other platforms may differ
# ────────────────────────────────────────────────────────────────────────

name: pr-review
description: Monitor a GitHub PR, detect changes, summarize, and optionally post to a messaging channel
version: "1.0.0"
author: Clawdbot

# ---------------------------------------------------------------------------
# Input schema
# ---------------------------------------------------------------------------
inputs:
  repo:
    type: string
    description: "GitHub repo in owner/repo format"
    required: true
  pr:
    type: string
    description: "PR number to review"
    required: true
  channel:
    type: string
    description: "Channel/group/chat identifier for your messaging platform (e.g., Discord channel ID, Slack channel name). Optional."
    required: false
  changes_only:
    type: boolean
    description: "Only report when state has changed since last run"
    default: true

# ---------------------------------------------------------------------------
# Workflow steps
# ---------------------------------------------------------------------------
steps:

  # ── Step 1: Fetch PR details ──────────────────────────────────────────────
  # Pulls the full PR payload from GitHub as JSON.
  # Fields: state, title, author, reviewDecision, mergeable,
  #         statusCheckRollup, additions, deletions, files
  - id: fetch_pr
    description: Fetch PR metadata and status from GitHub
    command: |
      gh pr view ${pr} \
        --repo ${repo} \
        --json state,title,author,reviewDecision,mergeable,statusCheckRollup,additions,deletions,files
    output: json

  # ── Step 2: Extract CI status ─────────────────────────────────────────────
  # Flatten statusCheckRollup into a concise summary line per check.
  # Output: one JSON object with totals and a per-check breakdown.
  - id: check_ci
    description: Parse CI check results from statusCheckRollup
    command: |
      echo '${fetch_pr.stdout}' | jq '{
        ci_summary: {
          total:    (.statusCheckRollup | length),
          success:  ([.statusCheckRollup[] | select(.conclusion == "SUCCESS")]  | length),
          failure:  ([.statusCheckRollup[] | select(.conclusion == "FAILURE")]  | length),
          pending:  ([.statusCheckRollup[] | select(.conclusion == null or .conclusion == "PENDING")] | length),
          checks:   [.statusCheckRollup[] | {name: .name, status: .status, conclusion: .conclusion}]
        }
      }'
    stdin: $fetch_pr.stdout
    output: json

  # ── Step 3: Diff against last run ─────────────────────────────────────────
  # Compare the current PR state against the snapshot from the previous run.
  # diff.last returns { changed: bool, diff: string, previous: object }
  - id: diff_state
    description: Diff current PR state against last saved snapshot
    command: diff.last
    args:
      key: "pr-review:${repo}:${pr}"
      value:
        state: "${fetch_pr.state}"
        title: "${fetch_pr.title}"
        author: "${fetch_pr.author}"
        reviewDecision: "${fetch_pr.reviewDecision}"
        mergeable: "${fetch_pr.mergeable}"
        additions: "${fetch_pr.additions}"
        deletions: "${fetch_pr.deletions}"
        ci_success: "${check_ci.ci_summary.success}"
        ci_failure: "${check_ci.ci_summary.failure}"
        ci_pending: "${check_ci.ci_summary.pending}"
        ci_total: "${check_ci.ci_summary.total}"

  # ── Step 4: Generate change summary ───────────────────────────────────────
  # Only runs when a change is detected (or changes_only is false).
  # Asks the LLM to produce a concise, readable summary of the PR + delta.
  - id: generate_summary
    description: Generate a human-readable PR review summary
    command: clawd.invoke
    args:
      tool: sessions_spawn
      task: |
        Summarize this GitHub PR for a messaging channel. Be concise and factual.

        ## PR Details
        - **Repo:** ${repo}
        - **PR:** #${pr}
        - **Title:** ${fetch_pr.title}
        - **Author:** ${fetch_pr.author}
        - **State:** ${fetch_pr.state}
        - **Review Decision:** ${fetch_pr.reviewDecision}
        - **Mergeable:** ${fetch_pr.mergeable}
        - **Diff:** +${fetch_pr.additions} / -${fetch_pr.deletions}

        ## CI Status
        - Total checks: ${check_ci.ci_summary.total}
        - ✅ Passed: ${check_ci.ci_summary.success}
        - ❌ Failed: ${check_ci.ci_summary.failure}
        - ⏳ Pending: ${check_ci.ci_summary.pending}

        ## Changes since last check
        Changed: ${diff_state.changed}
        Diff: ${diff_state.diff}

        ## Instructions
        - Format with markdown (keep under 1500 chars)
        - Lead with a one-line status emoji + headline
        - List what changed since last check (if anything)
        - Mention failing CI checks by name if any
        - End with mergeable status
        - No preamble — output the message body only
    condition: |
      ${diff_state.changed} == true || ${changes_only} == false

  # ── Step 5: Approval gate ─────────────────────────────────────────────────
  # Present the summary and ask whether to post it.
  - id: approve_post
    description: Human approval before posting to channel
    command: approve
    args:
      prompt: |
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        📋 PR REVIEW SUMMARY
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        ${generate_summary.stdout}

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        🎯 DETAILS
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        • Repo: ${repo}
        • PR:   #${pr}
        • Channel: ${channel}

        Post this summary to the channel?

        ✅ yes  — Post now
        ❌ no   — Skip
    stdin: $generate_summary.stdout
    approval: required
    condition: $generate_summary.success

  # ── Step 6: Post to channel ───────────────────────────────────────────────
  # Send the approved summary to the specified messaging channel.
  - id: post_to_channel
    description: Post the PR summary to the messaging channel
    command: clawd.invoke
    args:
      tool: message_send
      target: "${channel}"
      message: "${generate_summary.stdout}"
    condition: $approve_post.approved && "${channel}" != ""

  # ── Step 7: Save state for next comparison ────────────────────────────────
  # Persist the current snapshot so the next run can diff against it.
  - id: save_state
    description: Save current PR state for future diffing
    command: state.set
    args:
      key: "pr-review:${repo}:${pr}"
      value:
        state: "${fetch_pr.state}"
        title: "${fetch_pr.title}"
        author: "${fetch_pr.author}"
        reviewDecision: "${fetch_pr.reviewDecision}"
        mergeable: "${fetch_pr.mergeable}"
        additions: "${fetch_pr.additions}"
        deletions: "${fetch_pr.deletions}"
        ci_success: "${check_ci.ci_summary.success}"
        ci_failure: "${check_ci.ci_summary.failure}"
        ci_pending: "${check_ci.ci_summary.pending}"
        ci_total: "${check_ci.ci_summary.total}"
        checked_at: "${NOW}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
output:
  success: $save_state.success
  changed: $diff_state.changed
  summary: $generate_summary.stdout
  pr_state: $fetch_pr.state
  review_decision: $fetch_pr.reviewDecision
