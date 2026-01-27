# Knowledge Extraction Workflow
# Lobster workflow for extracting durable facts from daily notes into the knowledge graph.
#
# Deterministic pipeline: read notes → extract facts → review → approve → write → log.
# Designed to run on a cron (every 4 hours) or manually.
#
# Usage:
#   lobster run workflows/knowledge-extraction.lobster
#   lobster run workflows/knowledge-extraction.lobster --args-json '{"date":"2026-01-27"}'
#   lobster run workflows/knowledge-extraction.lobster --args-json '{"auto_approve":true}'
#
# ── Platform Customization ──────────────────────────────────────────────
# This workflow does not send messages, but could be extended to notify
# a channel when facts are extracted. If adding notifications:
#   - channel IDs → your platform's channel/group/chat identifiers
#   - message formatting → Discord uses markdown; other platforms may differ
# ────────────────────────────────────────────────────────────────────────

name: knowledge-extraction
description: Extract durable facts from daily notes into the knowledge graph
version: "1.0.0"

# ---------------------------------------------------------------------------
# Input schema
# ---------------------------------------------------------------------------
inputs:
  date:
    type: string
    description: Date to extract from (YYYY-MM-DD). Defaults to today.
    required: false
  auto_approve:
    type: boolean
    description: Skip the approval gate and write all extracted facts automatically.
    default: false
  workspace:
    type: string
    description: Root workspace path containing memory/ and life/ directories.
    default: "~/workspace"

# ---------------------------------------------------------------------------
# Workflow steps
# ---------------------------------------------------------------------------
steps:

  # ── Step 1: Resolve dates ──────────────────────────────────────────────
  # Compute today and yesterday date strings for file lookups.
  - id: resolve_dates
    description: Resolve target date and previous date
    command: |
      TARGET_DATE="${date}"
      if [ -z "$TARGET_DATE" ]; then
        TARGET_DATE=$(date +%Y-%m-%d)
      fi
      # Compute yesterday (works on macOS and Linux)
      if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
        YESTERDAY=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" -v-1d +%Y-%m-%d)
      else
        YESTERDAY=$(date -d "$TARGET_DATE - 1 day" +%Y-%m-%d)
      fi
      echo "{\"target_date\":\"$TARGET_DATE\",\"yesterday\":\"$YESTERDAY\"}"
    output: json

  # ── Step 2: Read today's daily note ────────────────────────────────────
  # Primary source for fact extraction.
  - id: read_today
    description: Read today's daily note from memory/
    command: |
      NOTE_PATH="${workspace}/memory/${resolve_dates.target_date}.md"
      if [ -f "$NOTE_PATH" ]; then
        cat "$NOTE_PATH"
      else
        echo "NO_NOTE_FOUND"
      fi
    output: text

  # ── Step 3: Read yesterday's daily note ────────────────────────────────
  # Catch any facts missed from the previous day.
  - id: read_yesterday
    description: Read yesterday's daily note for missed extractions
    command: |
      NOTE_PATH="${workspace}/memory/${resolve_dates.yesterday}.md"
      if [ -f "$NOTE_PATH" ]; then
        cat "$NOTE_PATH"
      else
        echo "NO_NOTE_FOUND"
      fi
    output: text

  # ── Step 4: List existing entities ─────────────────────────────────────
  # Enumerate all known entities (people, companies, projects) so the LLM
  # can avoid duplicates and reference existing slugs.
  - id: list_entities
    description: List all existing entities across people, companies, projects
    command: |
      AREAS_DIR="${workspace}/life/areas"
      echo "=== EXISTING ENTITIES ==="
      for TYPE in people companies projects; do
        TYPE_DIR="$AREAS_DIR/$TYPE"
        if [ -d "$TYPE_DIR" ]; then
          for ENTITY_DIR in "$TYPE_DIR"/*/; do
            [ -d "$ENTITY_DIR" ] || continue
            SLUG=$(basename "$ENTITY_DIR")
            # Show slug and first line of summary if available
            SUMMARY=""
            if [ -f "$ENTITY_DIR/summary.md" ]; then
              SUMMARY=$(head -3 "$ENTITY_DIR/summary.md" | tr '\n' ' ')
            fi
            # Count active facts
            FACT_COUNT=0
            if [ -f "$ENTITY_DIR/facts.jsonl" ]; then
              FACT_COUNT=$(grep -c '"active"' "$ENTITY_DIR/facts.jsonl" 2>/dev/null || echo 0)
            fi
            echo "$TYPE/$SLUG (${FACT_COUNT} active facts) — $SUMMARY"
          done
        fi
      done
    output: text

  # ── Step 5: Collect existing facts for dedup ───────────────────────────
  # Gather all active facts so the LLM can skip already-known information.
  - id: collect_existing_facts
    description: Collect recent active facts for deduplication
    command: |
      AREAS_DIR="${workspace}/life/areas"
      echo "=== RECENT ACTIVE FACTS ==="
      for TYPE in people companies projects; do
        TYPE_DIR="$AREAS_DIR/$TYPE"
        if [ -d "$TYPE_DIR" ]; then
          for ENTITY_DIR in "$TYPE_DIR"/*/; do
            [ -d "$ENTITY_DIR" ] || continue
            SLUG=$(basename "$ENTITY_DIR")
            if [ -f "$ENTITY_DIR/facts.jsonl" ]; then
              # Show active facts (last 20 per entity to keep context manageable)
              FACTS=$(grep '"active"' "$ENTITY_DIR/facts.jsonl" 2>/dev/null | tail -20)
              if [ -n "$FACTS" ]; then
                echo "--- $TYPE/$SLUG ---"
                echo "$FACTS"
              fi
            fi
          done
        fi
      done
    output: text

  # ── Step 6: Extract facts via LLM ─────────────────────────────────────
  # Use a cheap model to analyze daily notes and produce structured facts.
  # Returns a JSON array of fact objects ready for insertion.
  - id: extract_facts
    description: Use LLM to extract durable facts from daily notes
    command: clawd.invoke
    args:
      tool: sessions_spawn
      model: cheap
      task: |
        You are a fact extraction engine for a knowledge graph.
        Your job: read daily notes and extract DURABLE facts worth remembering.

        ## What qualifies as a durable fact
        ✅ Extract:
        - Relationship changes (new job, new team, promotions)
        - Life milestones (moved cities, started a project)
        - Status changes (left company, started freelancing)
        - Stated preferences ("I prefer X over Y")
        - Key decisions ("decided to use Rust for the backend")
        - Important context ("works night shifts", "allergic to shellfish")

        ❌ Skip:
        - Casual conversation, jokes, greetings
        - Temporary states ("feeling tired today")
        - Already-known facts (check the existing facts below)
        - Vague or uncertain information
        - Bot/system messages, cron logs, extraction logs

        ## Existing entities and their facts (DO NOT duplicate these)
        ${list_entities.stdout}

        ${collect_existing_facts.stdout}

        ## Daily notes to extract from

        ### Today (${resolve_dates.target_date})
        ${read_today.stdout}

        ### Yesterday (${resolve_dates.yesterday})
        ${read_yesterday.stdout}

        ## Output format
        Return a JSON array of fact objects. Each object must have:
        - "entity_type": "people" | "companies" | "projects"
        - "entity_slug": lowercase-hyphenated slug (use existing slug if entity exists)
        - "is_new_entity": true if this entity doesn't exist yet
        - "new_entity_summary": 2-3 line summary (only if is_new_entity is true)
        - "fact": plain English atomic fact
        - "category": "relationship" | "milestone" | "status" | "preference" | "context" | "decision"
        - "source": "conversation" | "manual" | "inference"

        If there are NO new facts to extract, return an empty array: []

        Return ONLY valid JSON. No markdown fences, no explanation.
    output: json
    condition: |
      $read_today.stdout != "NO_NOTE_FOUND" || $read_yesterday.stdout != "NO_NOTE_FOUND"

  # ── Step 7: Review extracted facts ─────────────────────────────────────
  # Display what was found for the user (or logs).
  - id: review_facts
    description: Show extracted facts for review
    command: |
      FACTS='${extract_facts.stdout}'
      COUNT=$(echo "$FACTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "🧠 KNOWLEDGE EXTRACTION RESULTS"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      echo "Date range: ${resolve_dates.yesterday} → ${resolve_dates.target_date}"
      echo "Facts found: $COUNT"
      echo ""
      if [ "$COUNT" = "0" ]; then
        echo "No new facts to extract. Daily notes are up to date."
      else
        echo "$FACTS" | python3 -c "
      import sys, json
      facts = json.load(sys.stdin)
      for i, f in enumerate(facts):
          new = ' 🆕' if f.get('is_new_entity') else ''
          print(f\"  [{i+1}] {f['entity_type']}/{f['entity_slug']}{new}\")
          print(f\"      {f['fact']}\")
          print(f\"      category={f['category']}  source={f['source']}\")
          if f.get('new_entity_summary'):
              print(f\"      summary: {f['new_entity_summary']}\")
          print()
      "
      fi
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output: text
    condition: $extract_facts.success

  # ── Step 8: Approval gate ──────────────────────────────────────────────
  # Ask the user to approve (skipped if auto_approve is true).
  - id: approve_facts
    description: Human approval before writing facts to the knowledge graph
    command: approve
    args:
      prompt: |
        ${review_facts.stdout}

        Write these facts to the knowledge graph?

        ✅ yes  — Write all facts
        ❌ no   — Cancel extraction
    approval: optional
    condition: $extract_facts.success && !${auto_approve}

  # ── Step 9: Auto-approve bypass ────────────────────────────────────────
  # When auto_approve is true, skip the gate entirely.
  - id: auto_approve_gate
    description: Bypass approval when auto_approve is set
    command: |
      echo '{"approved": true, "mode": "auto"}'
    output: json
    condition: $extract_facts.success && ${auto_approve}

  # ── Step 10: Create new entities ───────────────────────────────────────
  # For any fact referencing a new entity, create the directory and summary.
  - id: create_entities
    description: Create directories and summaries for new entities
    command: |
      FACTS='${extract_facts.stdout}'
      AREAS_DIR="${workspace}/life/areas"
      CREATED=0

      echo "$FACTS" | python3 -c "
      import sys, json
      facts = json.load(sys.stdin)
      for f in facts:
          if f.get('is_new_entity'):
              print(f\"{f['entity_type']}|{f['entity_slug']}|{f.get('new_entity_summary','New entity')}\")
      " | while IFS='|' read -r ETYPE ESLUG ESUMMARY; do
        ENTITY_DIR="$AREAS_DIR/$ETYPE/$ESLUG"
        if [ ! -d "$ENTITY_DIR" ]; then
          mkdir -p "$ENTITY_DIR"
          # Write initial summary
          cat > "$ENTITY_DIR/summary.md" << SUMEOF
      # $(echo "$ESLUG" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
      $ESUMMARY
      _Last updated: ${resolve_dates.target_date}_
      SUMEOF
          # Create empty facts file
          touch "$ENTITY_DIR/facts.jsonl"
          echo "Created: $ETYPE/$ESLUG"
          CREATED=$((CREATED + 1))
        fi
      done

      echo "Entity creation complete."
    output: text
    condition: $approve_facts.approved || $auto_approve_gate.approved

  # ── Step 11: Write facts to JSONL files ────────────────────────────────
  # Append each approved fact to the appropriate entity's facts.jsonl.
  # Auto-increments IDs based on existing count.
  - id: write_facts
    description: Append extracted facts to entity facts.jsonl files
    command: |
      FACTS='${extract_facts.stdout}'
      AREAS_DIR="${workspace}/life/areas"
      TARGET_DATE="${resolve_dates.target_date}"
      WRITTEN=0

      echo "$FACTS" | python3 << 'PYEOF'
      import sys, json, os, glob

      areas_dir = os.path.expanduser("${workspace}/life/areas")
      target_date = "${resolve_dates.target_date}"
      facts = json.loads('''${extract_facts.stdout}''')

      written = 0
      for f in facts:
          entity_dir = os.path.join(areas_dir, f["entity_type"], f["entity_slug"])
          facts_file = os.path.join(entity_dir, "facts.jsonl")

          # Determine next ID
          next_num = 1
          if os.path.exists(facts_file):
              with open(facts_file, "r") as fh:
                  for line in fh:
                      line = line.strip()
                      if line:
                          try:
                              existing = json.loads(line)
                              eid = existing.get("id", "")
                              parts = eid.rsplit("-", 1)
                              if len(parts) == 2 and parts[1].isdigit():
                                  next_num = max(next_num, int(parts[1]) + 1)
                          except json.JSONDecodeError:
                              pass

          fact_id = f"{f['entity_slug']}-{next_num:03d}"

          fact_obj = {
              "id": fact_id,
              "fact": f["fact"],
              "category": f["category"],
              "ts": target_date,
              "source": f.get("source", "conversation"),
              "status": "active"
          }

          os.makedirs(os.path.dirname(facts_file), exist_ok=True)
          with open(facts_file, "a") as fh:
              fh.write(json.dumps(fact_obj) + "\n")

          print(f"  ✓ {fact_id}: {f['fact'][:60]}...")
          written += 1

      print(f"\nWrote {written} fact(s) to knowledge graph.")
      PYEOF
    output: text
    condition: $create_entities.success

  # ── Step 12: Log extraction to daily note ──────────────────────────────
  # Append a summary line so we know extraction already ran today.
  - id: log_extraction
    description: Append extraction summary to today's daily note
    command: |
      NOTE_PATH="${workspace}/memory/${resolve_dates.target_date}.md"
      FACTS='${extract_facts.stdout}'
      COUNT=$(echo "$FACTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      TIMESTAMP=$(date +%H:%M)

      # Append log entry
      echo "" >> "$NOTE_PATH"
      echo "---" >> "$NOTE_PATH"
      echo "🧠 **Knowledge extraction** @ $TIMESTAMP — $COUNT fact(s) extracted and saved." >> "$NOTE_PATH"

      echo "Logged extraction to $NOTE_PATH"
    output: text
    condition: $write_facts.success

  # ── Step 13: Save state ────────────────────────────────────────────────
  # Track when extraction last ran so cron can skip if recent.
  - id: save_state
    description: Save last extraction timestamp for cron dedup
    command: state.set
    args:
      key: "knowledge-extraction:last-run"
      value:
        last_extracted_date: "${resolve_dates.target_date}"
        last_extracted_at: "${DATE_NOW}"
        facts_count: "${write_facts.stdout}"
    condition: $log_extraction.success

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
output:
  success: $log_extraction.success
  date: $resolve_dates.target_date
  facts_extracted: $extract_facts.stdout
  write_summary: $write_facts.stdout
