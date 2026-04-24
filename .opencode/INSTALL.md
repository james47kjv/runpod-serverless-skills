# OpenCode install — runpod-serverless plugin

OpenCode follows the same "cat-based skill loading" pattern as Codex.
See `../.codex/INSTALL.md` for the full setup. The only differences:

## One-time install

```bash
ln -s ~/.claude/plugins/local/runpod-serverless ~/.opencode/runpod-serverless
echo 'include ~/.opencode/runpod-serverless/.codex/runpod-codex-bootstrap.md' \
  >> ~/.opencode/agent-rules.md   # adjust path if OpenCode uses a different root rules file
```

OpenCode can reuse the Codex bootstrap (`.codex/runpod-codex-bootstrap.md`)
because the Claude→non-Claude primitive mapping is the same.

If OpenCode has additional primitives that Claude doesn't (e.g., its
own scheduling / cron tool), extend this file with a "What OpenCode
does that Codex doesn't" section.
