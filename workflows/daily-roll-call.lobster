# Daily Roll Call Workflow
# Deterministic pipeline for daily agent roll call.
# Creates a thread, pings all fleet instances, collects reports, compiles summary.
#
# Usage:
#   lobster run workflows/daily-roll-call.lobster
#   lobster run workflows/daily-roll-call.lobster --args-json '{"wait_minutes":3}'
#
# ── Platform Customization ──────────────────────────────────────────────
# This workflow uses Clawdbot's message tool for notifications.
# Adapt these for your messaging platform:
#   - channel IDs → your platform's channel/group/chat identifiers
#   - thread-create → may not be available on all platforms (Telegram, Signal)
#   - message formatting → Discord uses markdown; other platforms may differ
#
# ⚠️  Threading Note: This workflow relies on thread-create and thread-reply.
#     These features require a platform that supports threading (Discord, Slack).
#     For non-threaded platforms (Telegram, Signal, etc.), post to a dedicated
#     channel instead and replace thread-reply steps with regular message sends.
# ────────────────────────────────────────────────────────────────────────

name: daily-roll-call
description: Daily fleet roll call — collect agent reports and post compiled summary
version: "1.0.0"

# ---------------------------------------------------------------------------
# Input schema
# ---------------------------------------------------------------------------
inputs:
  reports_channel:
    type: string
    description: "Channel/group/chat identifier for your messaging platform (e.g., Discord channel ID, Slack channel name)"
    default: "YOUR_CHANNEL_ID"
  wait_minutes:
    type: number
    description: Minutes to wait for external instance responses
    default: 5
  bot_ids:
    type: string
    description: "Bot/agent identifiers to mention (platform-specific: Discord uses numeric IDs, Slack uses member IDs, etc.)"
    default: "BOT_ID_1,BOT_ID_2,BOT_ID_3,BOT_ID_4"

# ---------------------------------------------------------------------------
# Workflow steps
# ---------------------------------------------------------------------------
steps:

  # ── Step 1: Capture today's date ────────────────────────────────────────
  - id: today
    description: Get today's date for thread naming and log lookup
    command: |
      echo "{\"date\":\"$(date +%Y-%m-%d)\",\"display\":\"$(date +'%A, %B %-d %Y')\"}"
    output: json

  # ── Step 2: Create messaging thread ──────────────────────────────────────
  - id: create_thread
    description: Create a dated roll-call thread in the reports channel
    command: clawd.invoke
    args:
      tool: message
      action: thread-create
      channel: "${reports_channel}"
      threadName: "📋 Daily Roll Call — ${today.display}"
      message: |
        # 📋 Daily Roll Call
        **${today.display}**

        Fleet status check. All agents report in.

  # ── Step 3: Ping all Clawdbot instances ─────────────────────────────────
  - id: ping_fleet
    description: Mention all bot instances so they wake up and see the thread
    command: clawd.invoke
    args:
      tool: message
      action: thread-reply
      threadId: "${create_thread.threadId}"
      message: |
        📡 **Roll call — all agents report in.**

        <@${bot_ids[0]}> <@${bot_ids[1]}> <@${bot_ids[2]}> <@${bot_ids[3]}>

        Please reply with:
        • **Activity** — What you worked on
        • **Outcomes** — Key results
        • **Status** — 🟢 Nominal / 🟡 Degraded / 🔴 Down

  # ── Step 4: Request reports from other agents ────────────────────────────
  #    Send to agent-2 and agent-3 via sessions_send
  - id: request_agent_2
    description: Ask agent-2 for daily report
    command: clawd.invoke
    args:
      tool: sessions_send
      target: agent-2
      message: |
        📋 The coordinator requests your daily roll-call report.
        Reply with:
        - **Activity**: What you worked on today
        - **Outcomes**: Key results or deliverables
        - **Status**: 🟢 Nominal / 🟡 Degraded / 🔴 Down

  - id: request_agent_3
    description: Ask agent-3 for daily report
    command: clawd.invoke
    args:
      tool: sessions_send
      target: agent-3
      message: |
        📋 The coordinator requests your daily roll-call report.
        Reply with:
        - **Activity**: What you worked on today
        - **Outcomes**: Key results or deliverables
        - **Status**: 🟢 Nominal / 🟡 Degraded / 🔴 Down

  # ── Step 5: Collect coordinator's own report ─────────────────────────────
  - id: coordinator_self_report
    description: Read today's session logs for the coordinator's own activity
    command: |
      SESSION_DIR=~/.clawdbot/agents/coordinator/sessions
      TODAY="${today.date}"

      # Find today's session files
      SESSION_FILES=$(find "$SESSION_DIR" -name "*${TODAY}*" -type f 2>/dev/null | head -20)

      if [ -z "$SESSION_FILES" ]; then
        echo '{"activity":"Session startup and fleet coordination","outcomes":"Initiated daily roll call","status":"🟢 Nominal"}'
        exit 0
      fi

      # Count sessions and extract summary info
      SESSION_COUNT=$(echo "$SESSION_FILES" | wc -l | tr -d ' ')
      # Get unique channels from filenames
      CHANNELS=$(echo "$SESSION_FILES" | sed 's/.*\///' | cut -d'.' -f1 | sort -u | tr '\n' ', ' | sed 's/,$//')

      echo "{\"activity\":\"${SESSION_COUNT} sessions active across: ${CHANNELS}\",\"outcomes\":\"Fleet coordination, daily roll call\",\"status\":\"🟢 Nominal\"}"
    output: json

  # ── Step 6: Wait for external responses ─────────────────────────────────
  - id: wait_for_responses
    description: "Wait ${wait_minutes} minutes for fleet to respond"
    command: |
      WAIT_SECS=$((${wait_minutes} * 60))
      echo "⏳ Waiting ${wait_minutes} minutes (${WAIT_SECS}s) for fleet responses..."
      sleep ${WAIT_SECS}
      echo "✅ Wait complete."

  # ── Step 7: Read thread responses ───────────────────────────────────────
  - id: collect_responses
    description: Read the thread to gather all agent replies
    command: clawd.invoke
    args:
      tool: message
      action: read
      channel: "${create_thread.threadId}"
      limit: 30

  # ── Step 8: Compile Fleet Summary ───────────────────────────────────────
  - id: compile_summary
    description: Format all reports into a unified fleet summary
    command: clawd.invoke
    args:
      tool: sessions_spawn
      task: |
        Compile a fleet status summary from the roll-call data below.
        Output ONLY the formatted summary (no preamble).

        ## Coordinator's Report (self-collected)
        - Activity: ${coordinator_self_report.activity}
        - Outcomes: ${coordinator_self_report.outcomes}
        - Status: ${coordinator_self_report.status}

        ## Thread Responses
        ${collect_responses.stdout}

        ## Format Template
        Use this exact format:

        **━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━**
        **📋 Fleet Status — ${today.display}**
        **━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━**

        📋 **Coordinator** — Fleet Coordinator
        > Activity: ...
        > Outcomes: ...
        > Status: ...

        🔍 **Analyst** — Analysis & Computation
        > Activity: ...
        > Outcomes: ...
        > Status: ...

        📝 **Content Manager** — Content & Communication
        > Activity: ...
        > Outcomes: ...
        > Status: ...

        🤖 **Agent-4** — Dev Rel & Technical Docs
        > Activity: ...
        > Outcomes: ...
        > Status: ...

        📊 **Agent-5** — Trading Analyst
        > Activity: ...
        > Outcomes: ...
        > Status: ...

        **━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━**
        **Fleet Strength:** X/5 reporting | Overall: 🟢/🟡/🔴

        Rules:
        - If an agent did NOT reply, mark them: `⚠️ No report received`
        - Use the emoji + bold name format exactly
        - Count only agents that actually replied for "Fleet Strength"
        - Overall status = worst status among reporting agents

  # ── Step 9: Post compiled summary to thread ─────────────────────────────
  - id: post_summary
    description: Post the final fleet summary to the roll-call thread
    command: clawd.invoke
    args:
      tool: message
      action: thread-reply
      threadId: "${create_thread.threadId}"
      message: |
        ${compile_summary.stdout}

  # ── Step 10: Save state for tracking ────────────────────────────────────
  - id: save_state
    description: Persist roll-call completion for audit trail
    command: state.set
    args:
      key: "roll-call:${today.date}"
      value:
        date: "${today.date}"
        thread_id: "${create_thread.threadId}"
        wait_minutes: "${wait_minutes}"
        completed: true

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
output:
  success: $post_summary.success
  date: $today.date
  thread_id: $create_thread.threadId
  summary: $compile_summary.stdout
