# Deploy Announce Workflow
# Lobster workflow for announcing releases/deployments with human-in-the-loop approval
#
# Fetches release info from GitHub, generates a formatted announcement,
# previews it for approval, posts to channel, and optionally cross-posts to X.
#
# Usage:
#   lobster run workflows/deploy-announce.lobster --args-json '{"repo":"owner/repo","channel":"123456"}'
#   lobster run workflows/deploy-announce.lobster --args-json '{"repo":"owner/repo","tag":"v1.2.0","channel":"123456","post_to_x":true}'
#
# ── Platform Customization ──────────────────────────────────────────────
# This workflow uses Clawdbot's message tool for notifications.
# Adapt these for your messaging platform:
#   - channel IDs → your platform's channel/group/chat identifiers
#   - thread-create → may not be available on all platforms (Telegram, Signal)
#   - message formatting → Discord uses markdown; other platforms may differ
# ────────────────────────────────────────────────────────────────────────

name: deploy-announce
description: Fetch release info, generate announcement, approve, and post to channel (and optionally X)
version: "1.0.0"

# ─────────────────────────────────────────────
# Input schema
# ─────────────────────────────────────────────
inputs:
  repo:
    type: string
    description: "GitHub owner/repo (e.g. 'acme/widgets')"
    required: true
  tag:
    type: string
    description: "Specific tag to announce (defaults to latest release)"
    required: false
  channel:
    type: string
    description: "Channel/group/chat identifier for your messaging platform (e.g., Discord channel ID, Slack channel name)"
    required: true
  post_to_x:
    type: boolean
    description: "Whether to also post a summary to X"
    default: false

# ─────────────────────────────────────────────
# Workflow steps
# ─────────────────────────────────────────────
steps:

  # ── Step 1: Fetch release details from GitHub ──────────────────────
  # If a tag is provided, fetch that specific release; otherwise grab latest.
  # Output: JSON with tag_name, name, body, author.login, published_at, assets.
  - id: fetch_release
    description: Fetch release details from GitHub
    command: |
      if [ -n "${tag}" ]; then
        gh api "repos/${repo}/releases/tags/${tag}" \
          --jq '{
            tag_name: .tag_name,
            name: .name,
            body: .body,
            author: .author.login,
            published_at: .published_at,
            html_url: .html_url,
            assets: [.assets[] | {name: .name, download_count: .download_count, size: .size}]
          }'
      else
        gh api "repos/${repo}/releases/latest" \
          --jq '{
            tag_name: .tag_name,
            name: .name,
            body: .body,
            author: .author.login,
            published_at: .published_at,
            html_url: .html_url,
            assets: [.assets[] | {name: .name, download_count: .download_count, size: .size}]
          }'
      fi
    output: json

  # ── Step 2: Determine previous tag for changelog diff ──────────────
  # Lists recent tags, finds the one immediately before the current release tag.
  - id: find_previous_tag
    description: Find the previous release tag for changelog comparison
    command: |
      CURRENT_TAG="${fetch_release.tag_name}"
      # List releases sorted by date, extract the one right before current
      PREV_TAG=$(gh api "repos/${repo}/releases" --paginate --jq '.[].tag_name' \
        | awk -v cur="$CURRENT_TAG" 'found {print; exit} $0 == cur {found=1}')
      if [ -z "$PREV_TAG" ]; then
        echo '{"previous_tag":"","has_previous":false}'
      else
        echo "{\"previous_tag\":\"${PREV_TAG}\",\"has_previous\":true}"
      fi
    output: json

  # ── Step 3: Fetch changelog diff between tags ─────────────────────
  # Uses GitHub compare API to get commits between previous and current tag.
  # If no previous tag exists, skips gracefully.
  - id: fetch_changelog
    description: Fetch commit diff between previous and current tag
    command: |
      if [ "${find_previous_tag.has_previous}" = "true" ]; then
        gh api "repos/${repo}/compare/${find_previous_tag.previous_tag}...${fetch_release.tag_name}" \
          --jq '{
            total_commits: .total_commits,
            commits: [.commits[] | {
              sha: .sha[0:7],
              message: (.commit.message | split("\n")[0]),
              author: .commit.author.name
            }],
            files_changed: (.files | length),
            diff_url: .html_url
          }'
      else
        echo '{"total_commits":0,"commits":[],"files_changed":0,"diff_url":"","note":"No previous tag found — first release or tags unavailable."}'
      fi
    output: json

  # ── Step 4: Generate announcement via LLM ──────────────────────────
  # Uses clawd.invoke to produce a clean, formatted announcement
  # from the release notes and changelog data.
  - id: generate_announcement
    description: Generate a human-readable announcement from release data
    command: clawd.invoke
    args:
      tool: sessions_spawn
      task: |
        Generate a deployment/release announcement formatted for a messaging channel.

        ## Release Info
        - Repository: ${repo}
        - Tag: ${fetch_release.tag_name}
        - Name: ${fetch_release.name}
        - Author: ${fetch_release.author}
        - Published: ${fetch_release.published_at}
        - URL: ${fetch_release.html_url}

        ## Release Notes
        ${fetch_release.body}

        ## Changelog (since ${find_previous_tag.previous_tag})
        - Total commits: ${fetch_changelog.total_commits}
        - Files changed: ${fetch_changelog.files_changed}
        - Commits: ${fetch_changelog.commits}

        ## Formatting Rules
        - Use markdown formatting (bold, code blocks, etc.)
        - Start with a 🚀 emoji header line with the version
        - Include a brief summary of what changed (synthesize from notes + commits)
        - List key highlights as bullet points
        - Include the release link at the bottom
        - If there are assets, mention them briefly
        - Keep it concise but informative — aim for readable, not verbose
        - Do NOT include any meta-commentary, just the announcement text
        - Be professional and neutral — no personal references

        Return ONLY the formatted announcement text.

  # ── Step 5: Preview the announcement ───────────────────────────────
  # Shows the generated announcement and release metadata for review.
  - id: preview_announcement
    description: Preview the formatted announcement before posting
    command: approve
    args:
      prompt: |
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        🚀 DEPLOYMENT ANNOUNCEMENT PREVIEW
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        ${generate_announcement.stdout}

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        📋 RELEASE METADATA
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        • Repo:     ${repo}
        • Tag:      ${fetch_release.tag_name}
        • Previous: ${find_previous_tag.previous_tag}
        • Author:   ${fetch_release.author}
        • Commits:  ${fetch_changelog.total_commits}
        • Files:    ${fetch_changelog.files_changed}
        • Channel:  ${channel}

        Post this announcement to the channel?

        ✅ yes  — Post now
        ❌ no   — Cancel
        ✏️ edit — Request changes
    approval: required

  # ── Step 6: Post announcement to channel ────────────────────────────
  - id: post_to_channel
    description: Post the announcement to the specified messaging channel
    command: clawd.invoke
    args:
      tool: message_send
      target: "${channel}"
      message: "${generate_announcement.stdout}"
    condition: $preview_announcement.approved

  # ── Step 7: Optionally post to X ───────────────────────────────────
  # Only runs if post_to_x is true. Has its own approval gate.

  # 7a: Generate a shorter X-appropriate version
  - id: generate_x_post
    description: Generate a short X post version of the announcement
    command: clawd.invoke
    args:
      tool: sessions_spawn
      task: |
        Create a short X (Twitter) post announcing this release.

        Release: ${fetch_release.name} (${fetch_release.tag_name})
        Repo: ${repo}
        URL: ${fetch_release.html_url}
        Key changes: ${fetch_release.body}

        Rules:
        - Under 280 characters
        - Include the release URL
        - Use 🚀 emoji
        - Brief, punchy, professional
        - No hashtags unless they add real value

        Return ONLY the post text.
    condition: $post_to_channel.success
    when: ${post_to_x} == true

  # 7b: Approve X post
  - id: approve_x_post
    description: Human approval required before posting to X
    command: approve
    args:
      prompt: |
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        🐦 X POST PREVIEW
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        ${generate_x_post.stdout}

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        Post this to X?

        ✅ yes  — Post now
        ❌ no   — Skip X post
    approval: required
    condition: $generate_x_post.success
    when: ${post_to_x} == true

  # 7c: Post to X via bird CLI
  - id: post_x
    description: Post to X using bird CLI
    command: bird post --text "${generate_x_post.stdout}"
    condition: $approve_x_post.approved
    when: ${post_to_x} == true

  # ── Step 8: Save state — track last announced version ──────────────
  - id: save_state
    description: Save workflow state to track last announced version
    command: state.set
    args:
      key: "deploy-announce:${repo}:${fetch_release.tag_name}"
      value:
        repo: "${repo}"
        tag: "${fetch_release.tag_name}"
        name: "${fetch_release.name}"
        previous_tag: "${find_previous_tag.previous_tag}"
        announced_at: "${NOW}"
        channel: "${channel}"
        channel_posted: true
        x_posted: ${post_to_x}
    condition: $post_to_channel.success

# ─────────────────────────────────────────────
# Output
# ─────────────────────────────────────────────
output:
  success: $post_to_channel.success
  repo: $repo
  tag: $fetch_release.tag_name
  release_name: $fetch_release.name
  announcement: $generate_announcement.stdout
  channel_posted: $post_to_channel.success
  x_posted: $post_x.success
