#!/bin/sh
# Reads Claude Code status line JSON on stdin and saves only the rate_limits block
# (plus a timestamp) to ~/.claude/usage-bar.json for the claude-bar menu bar app.
# No tokens or conversation data are written.
#
# Claude Code also re-renders the status line without a new reply (on a timer, after /usage,
# when a setting changes), repeating the rate-limit headers of this session's last reply. Such a
# run must not overwrite a fresher snapshot from another session, so the snapshot is written only
# when this session's cost.total_api_duration_ms, which moves only when a reply completes, differs
# from its last write. Sessions are tracked by a short hash of their ID, never the ID itself, in
# ~/.claude/usagebar/sessions, shared with the usagebar-hook helper.
out="$HOME/.claude/usage-bar.json"
markers="$HOME/.claude/usagebar/sessions"
input=$(cat)
snap=$(printf '%s' "$input" | jq -c 'select(.rate_limits != null) | {rate_limits: {five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day}, captured_at: (now | floor)}' 2>/dev/null)
[ -n "$snap" ] || exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
api=$(printf '%s' "$input" | jq -r '(.cost.total_api_duration_ms // empty) | floor' 2>/dev/null)
if [ -n "$sid" ] && [ -n "$api" ]; then
  marker="$markers/$(printf '%s' "$sid" | shasum -a 256 | cut -c1-16)"
  [ "$(cat "$marker" 2>/dev/null)" = "$api" ] && exit 0
  mkdir -p "$markers" && printf '%s' "$api" > "$marker"
  find "$markers" -type f -mtime +7 -delete 2>/dev/null
fi
tmp="$out.tmp.$$"
printf '%s\n' "$snap" > "$tmp" && mv -f "$tmp" "$out"
