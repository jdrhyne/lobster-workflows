# X Morning Post Workflow
# Lobster workflow for human-in-the-loop X draft creation
# 
# Usage:
#   lobster run workflows/x-morning-post.lobster
#   lobster run workflows/x-morning-post.lobster --args-json '{"seed_id":"SEED-003"}'
#
# -- Platform Customization ----------------------------------------------
# This workflow generates and saves an X post draft pack for manual posting.
# It intentionally does not post directly to X. Customize:
#   - seeds_file -> your content queue
#   - output_dir -> where approved draft packs should be written
#   - guide paths in generate_draft -> your local voice/content guides
# Requires CLAWD_URL/CLAWD_TOKEN if your llm_task.invoke setup needs them.
# ------------------------------------------------------------------------

name: x-morning-post
description: Select a seed, generate a draft pack, and hand off for manual posting
version: "1.1.0"

# Argument schema
args:
  seed_id:
    type: string
    description: Optional specific seed ID to use (e.g., "SEED-003")
    required: false
    default: ""
  seeds_file:
    type: string
    description: Path to seeds.md
    default: "./content/seeds.md"
  output_dir:
    type: string
    description: Directory where approved draft packs are saved
    default: "./output"

# Workflow steps
steps:
  # Step 1: Parse seeds and find ready ones
  - id: parse_seeds
    description: Extract ready seeds from seeds.md
    command: |
      node <<'NODE'
      const fs = require('fs');
      const os = require('os');
      const path = require('path');

      const expandHome = (value) => {
        if (!value) return value;
        return value.startsWith('~/') ? path.join(os.homedir(), value.slice(2)) : value;
      };

      const seedsFile = expandHome(process.env.SEEDS_FILE || './content/seeds.md');
      const text = fs.readFileSync(seedsFile, 'utf8');
      const sections = text.split(/\n(?=### SEED-\d+)/);

      const field = (section, name) => {
        const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const match = section.match(new RegExp(`^-\\s+(?:\\*\\*)?${escaped}:(?:\\*\\*)?\\s*(.+)$`, 'mi'));
        return match ? match[1].trim().replace(/^\[|\]$/g, '') : '';
      };

      for (const section of sections) {
        const heading = section.match(/^###\s+(SEED-\d+):?\s*(.*)$/m);
        if (!heading) continue;

        const status = field(section, 'Status');
        if (!/^Ready$/i.test(status)) continue;

        const seed = {
          id: heading[1],
          title: heading[2].replace(/\s*✅.*$/, '').trim(),
          insight: field(section, 'Core insight'),
          format: field(section, 'Format'),
          spicy: field(section, 'Spicy level')
        };

        process.stdout.write(`${JSON.stringify(seed)}\n`);
      }
      NODE
    env:
      SEEDS_FILE: ${seeds_file}
    output: json_lines

  # Step 2: Select seed (use provided or pick first)
  - id: select_seed
    description: Select which seed to use
    command: |
      node <<'NODE'
      const fs = require('fs');
      const raw = (process.env.READY_SEEDS || '').trim();
      const seeds = raw ? raw.split(/\n+/).map((line) => JSON.parse(line)) : [];
      const requested = process.env.SEED_ID || '';
      const selected = requested ? seeds.find((seed) => seed.id === requested) : seeds[0];

      if (!selected) {
        process.stderr.write(requested ? `Seed not found or not ready: ${requested}` : 'No ready seeds found');
        process.exit(1);
      }

      process.stdout.write(JSON.stringify(selected));
      NODE
    env:
      READY_SEEDS: $parse_seeds.stdout
      SEED_ID: ${seed_id}
    output: json

  # Step 3: Show selection and ask for confirmation
  - id: confirm_seed
    description: Confirm seed selection before generating
    command: |
      node <<'NODE'
      const raw = (process.env.SELECTED_SEED || '').trim();
      const seed = raw ? JSON.parse(raw) : {};
      const prompt = `Selected seed for posting:

      ID: ${seed.id ?? ''}
      Title: ${seed.title ?? ''}
      Format: ${seed.format ?? ''}
      Core insight: ${seed.insight ?? ''}
      Spicy level: ${seed.spicy ?? ''}

      Generate draft from this seed?`;

      process.stdout.write(JSON.stringify({
        requiresApproval: {
          prompt,
          items: [seed]
        }
      }));
      NODE
    env:
      SELECTED_SEED: $select_seed.stdout
    approval: required

  # Step 4: Generate draft using LLM
  - id: generate_draft
    description: Generate X post draft from seed
    command: |
      node <<'NODE'
      const { spawnSync } = require('child_process');

      const raw = (process.env.SELECTED_SEED || '').trim();
      const seed = raw ? JSON.parse(raw) : {};
      const prompt = `Generate an X post from this seed. Follow the X_GUIDE.md and VOICE_GUIDE.md in your content workspace.

      Seed: ${seed.title ?? ''}
      Format: ${seed.format ?? ''}
      Core insight: ${seed.insight ?? ''}

      Requirements:
      - Match your brand voice (direct, specific, no fluff)
      - Under 280 chars for single post, or clear thread structure
      - Hook in first line
      - No hashtags unless organic
      - Spicy level ${seed.spicy ?? ''}/5

      Return ONLY the post text, nothing else.`;

      const shellQuote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;
      const pipeline = `llm_task.invoke --prompt ${shellQuote(prompt)}`;
      const result = spawnSync('lobster', ['run', '--mode', 'tool', pipeline], {
        encoding: 'utf8',
        env: process.env
      });

      if (result.status !== 0) {
        process.stderr.write(result.stderr || result.stdout);
        process.exit(result.status || 1);
      }

      let envelope;
      try {
        envelope = JSON.parse(result.stdout);
      } catch {
        process.stdout.write(result.stdout.trim());
        process.exit(0);
      }

      if (!envelope.ok) {
        process.stderr.write(JSON.stringify(envelope.error ?? envelope));
        process.exit(1);
      }

      const output = Array.isArray(envelope.output) ? envelope.output[0] : envelope.output;
      if (typeof output === 'string') {
        process.stdout.write(output.trim());
      } else if (output && typeof output === 'object') {
        process.stdout.write(String(output.text ?? output.content ?? output.output ?? JSON.stringify(output)));
      }
      NODE
    env:
      SELECTED_SEED: $select_seed.stdout
    condition: $confirm_seed.approved

  # Step 5: Final approval before manual handoff
  - id: approve_post
    description: Human approval required before saving the draft pack
    command: |
      node <<'NODE'
      const draft = (process.env.DRAFT_TEXT || '').trim();
      const seed = JSON.parse(process.env.SELECTED_SEED || '{}');
      const prompt = `DRAFT PREVIEW

      ${draft}

      POST DETAILS
      Seed: ${seed.id ?? ''}
      Format: ${seed.format ?? ''}

      Approve this draft pack for manual posting handoff?`;

      process.stdout.write(JSON.stringify({
        requiresApproval: {
          prompt,
          items: [{ seed, draft }]
        }
      }));
      NODE
    env:
      SELECTED_SEED: $select_seed.stdout
      DRAFT_TEXT: $generate_draft.stdout
    approval: required

  # Step 6: Save approved draft locally
  - id: save_handoff
    description: Save manual-post draft pack to output directory
    command: |
      DATE=$(date +%Y-%m-%d)
      mkdir -p "${output_dir}"
      OUT="${output_dir}/x-morning-post-${DATE}.md"
      cat > "$OUT"
      echo "$OUT"
    stdin: $generate_draft.stdout
    condition: $approve_post.approved

  # Step 7: Track state without posting or mutating queue status
  - id: save_state
    description: Save workflow state for tracking
    command: |
      node <<'NODE'
      const handoffPath = (process.env.HANDOFF_PATH || '').trim();
      const seed = JSON.parse(process.env.SELECTED_SEED || '{}');
      const postText = process.env.POST_TEXT || '';
      process.stdout.write(JSON.stringify({
        success: true,
        seed_id: seed.id,
        handoff_path: handoffPath,
        post_text: postText
      }));
      NODE
    env:
      SELECTED_SEED: $select_seed.stdout
      HANDOFF_PATH: $save_handoff.stdout
      POST_TEXT: $generate_draft.stdout
    condition: $approve_post.approved

# Output
output:
  success: $save_handoff.success
  seed_id: $select_seed.id
  handoff_path: $save_handoff.stdout
  post_text: $generate_draft.stdout
