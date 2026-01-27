# X Morning Post Workflow
# Lobster workflow for human-in-the-loop X posting
# 
# Usage:
#   lobster run workflows/x-morning-post.lobster
#   lobster run workflows/x-morning-post.lobster --args-json '{"seed_id":"SEED-003"}'
#
# ── Platform Customization ──────────────────────────────────────────────
# This workflow posts to X (Twitter) via the bird CLI.
# It does not use Clawdbot's message tool, but could be extended to
# notify a messaging channel (Discord, Slack, etc.) after posting.
# ────────────────────────────────────────────────────────────────────────

name: x-morning-post
description: Select a seed, generate draft, approve, and post to X
version: "1.0.0"

# Input schema
inputs:
  seed_id:
    type: string
    description: Optional specific seed ID to use (e.g., "SEED-003")
    required: false
  seeds_file:
    type: string
    description: Path to seeds.md
    default: "./content/seeds.md"

# Workflow steps
steps:
  # Step 1: Parse seeds and find ready ones
  - id: parse_seeds
    description: Extract ready seeds from seeds.md
    command: |
      cat ${seeds_file} | grep -A 8 "^### SEED-" | awk '
        BEGIN { RS="--\n"; FS="\n"; ORS="" }
        /Status: Ready/ && !/POSTED/ {
          for(i=1; i<=NF; i++) {
            if ($i ~ /^### SEED-/) {
              match($i, /SEED-[0-9]+/)
              id = substr($i, RSTART, RLENGTH)
              gsub(/^### /, "", $i)
              gsub(/ ✅.*$/, "", $i)
              title = $i
            }
            if ($i ~ /Core insight:/) {
              gsub(/.*Core insight: */, "", $i)
              insight = $i
            }
            if ($i ~ /Format:/) {
              gsub(/.*Format: *\[?/, "", $i)
              gsub(/\].*/, "", $i)
              format = $i
            }
            if ($i ~ /Spicy level:/) {
              gsub(/.*Spicy level: */, "", $i)
              spicy = $i
            }
          }
          if (id != "") {
            printf "{\"id\":\"%s\",\"title\":\"%s\",\"insight\":\"%s\",\"format\":\"%s\",\"spicy\":\"%s\"}\n", id, title, insight, format, spicy
          }
          id=""; title=""; insight=""; format=""; spicy=""
        }
      '
    output: json_lines

  # Step 2: Select seed (use provided or pick first)
  - id: select_seed
    description: Select which seed to use
    command: |
      if [ -n "${seed_id}" ]; then
        echo '${parse_seeds.stdout}' | grep "\"id\":\"${seed_id}\""
      else
        echo '${parse_seeds.stdout}' | head -1
      fi
    stdin: $parse_seeds.stdout
    output: json

  # Step 3: Show selection and ask for confirmation
  - id: confirm_seed
    description: Confirm seed selection before generating
    command: approve
    args:
      prompt: |
        🌱 Selected seed for posting:
        
        ID: ${select_seed.id}
        Title: ${select_seed.title}
        Format: ${select_seed.format}
        Core insight: ${select_seed.insight}
        Spicy level: ${select_seed.spicy}
        
        Generate draft from this seed?
    stdin: $select_seed.stdout
    approval: optional  # Can skip if running automated

  # Step 4: Generate draft using LLM
  - id: generate_draft
    description: Generate X post draft from seed
    command: clawd.invoke
    args:
      tool: sessions_spawn
      task: |
        Generate an X post from this seed. Follow the X_GUIDE.md and VOICE_GUIDE.md in thought-leadership/.
        
        Seed: ${select_seed.title}
        Format: ${select_seed.format}
        Core insight: ${select_seed.insight}
        
        Requirements:
        - Match your brand voice (direct, specific, no fluff)
        - Under 280 chars for single post, or clear thread structure
        - Hook in first line
        - No hashtags unless organic
        - Spicy level ${select_seed.spicy}/5
        
        Return ONLY the post text, nothing else.
    condition: $confirm_seed.approved

  # Step 5: Final approval before posting
  - id: approve_post
    description: Human approval required before posting
    command: approve
    args:
      prompt: |
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        📝 POST PREVIEW
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        
        ${generate_draft.stdout}
        
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        📊 POST DETAILS
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        • Seed: ${select_seed.id}
        • Format: ${select_seed.format}
        
        Ready to post to X?
        
        ✅ yes  — Post now
        ❌ no   — Cancel
        ✏️ edit — Request changes
    stdin: $generate_draft.stdout
    approval: required

  # Step 6: Post via bird CLI
  - id: post_to_x
    description: Post to X using bird CLI
    command: bird post --text "${generate_draft.stdout}"
    condition: $approve_post.approved

  # Step 7: Mark seed as posted
  - id: mark_posted
    description: Update seeds.md to mark as posted
    command: |
      DATE=$(date +%Y-%m-%d)
      sed -i '' "s/\(${select_seed.id}.*\)Status: Ready/\1Status: ✅ Posted ${DATE}/" ${seeds_file}
      echo "Marked ${select_seed.id} as posted on ${DATE}"
    condition: $post_to_x.success

  # Step 8: Archive and track state
  - id: save_state
    description: Save workflow state for tracking
    command: state.set
    args:
      key: "x-post:${select_seed.id}"
      value:
        posted_at: "${DATE}"
        post_text: "${generate_draft.stdout}"
    condition: $mark_posted.success

# Output
output:
  success: $mark_posted.success
  seed_id: $select_seed.id
  post_text: $generate_draft.stdout
