<p align="center">

```
     _____ _____
    / ____|  __ \    AI-Powered Code Review
   | |    | |__) |   Three reviewers. One command.
   | |    |  _  /
   | |____|  | \ \
    \_____|  |  \_\
```

<strong>One command. Three AI reviewers. Zero trust issues.</strong>

<br/>

<a href="#install">Install</a> &middot;
<a href="#usage">Usage</a> &middot;
<a href="#how-it-works">How It Works</a>

</p>

---

## The Problem

You use AI coding agents — Claude Code, Codex, Cursor — to write code. Great. But now you need to **review code you didn't write**. You stare at the diff, try to catch bugs, security holes, logic errors... in code that came from a black box.

This is slow. Error-prone. And boring.

## The Fix

`cr` sends your git diff to **three AI reviewers in parallel**. Each one sees the full project for context but reviews **only your changes**. You get three independent opinions in the time it takes to get one.

```
          You write code
          (or AI writes it)
                |
            git diff
                |
        .-------+-------.
        |       |       |
     Claude  Gemini   Codex      parallel, read-only
        |       |       |
        '-------+-------'
                |
       Formatted reviews
```

> When 2 out of 3 reviewers flag the same line — you know it's real.

## Install

```bash
git clone git@github.com:arzek/code-review.git
cd code-review
make install
```

Creates a symlink at `/usr/local/bin/cr`. Uninstall with `make uninstall`.

### Prerequisites

At least one of these CLI tools must be installed:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Gemini CLI](https://github.com/google-gemini/gemini-cli)
- [Codex CLI](https://github.com/openai/codex)

`cr` auto-detects which tools are available. Missing ones are skipped with a warning.

## Usage

```bash
cr                        # review all uncommitted changes
cr /path/to/repo          # review changes in a specific repo
cr -r claude              # use only Claude
cr -r claude,gemini       # use Claude and Gemini
cr -m sonnet              # use specific model for all reviewers
cr -s                     # review only staged changes
cr -t 180                 # custom timeout (default: 300s)
cr -l uk                  # review in Ukrainian
cr -l de                  # review in German
cr --ai                   # compact output for AI agents
```

All options: `cr --help`

## How It Works

Each reviewer receives **three layers of context**:

| Layer | Source | Purpose |
|:------|:-------|:--------|
| Project tree | `git ls-tree` | Understand the architecture |
| Changed files | Full file contents | See surrounding code |
| Git diff | Changed lines only | **This is what gets reviewed** |

The AI reviews **only the diff**. Everything else is context. No wasted tokens on unchanged code or data files.

Results **stream as they arrive** — the fastest reviewer's output appears immediately, while the others are still working. No waiting for the slowest one.

## Output

```
     _____ _____
    / ____|  __ \   AI-Powered Code Review
   | |    | |__) |  Three reviewers. One command.
   | |    |  _  /
   | |____|  | \ \
    \_____|  |  \_\

  ──────────────────────────────────────────────────────────
  my-project (feature/auth)
  5 files changed · 247 diff lines
  ──────────────────────────────────────────────────────────

  Reviewing with: claude, gemini, codex

  ✓ claude  ✓ gemini  ⠹ codex  42s

━━ CLAUDE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 42s

  Found 2 issues (1 critical, 1 warning)
  [CRITICAL] auth.js:42 — SQL injection via unsanitized user input
  [WARNING]  utils.js:15 — Missing null check on optional parameter
  Overall: Auth endpoint needs input sanitization before merge.

━━ GEMINI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 28s

  Found 1 issue (1 warning)
  [WARNING] auth.js:42 — Consider using parameterized queries
  Overall: One SQL safety concern, otherwise clean.

━━ CODEX ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 51s

  No issues found.
  Overall: Clean implementation, follows existing patterns.

  ──────────────────────────────────────────────────────────
  3/3 passed  ·  51s (parallel)
```

## AI-Friendly

`cr` is designed to be called by AI agents too. Use `--ai` for compact, token-efficient output with no banner, no colors, no decorations — just the findings.

```bash
cr --ai                   # compact output, optimized for AI consumption
cr --ai -r claude,gemini  # AI mode with specific reviewers
```

Ask Claude Code to run `cr --ai` and it gets structured review output from other AI models — a second (and third) opinion on its own code.

## License

MIT
