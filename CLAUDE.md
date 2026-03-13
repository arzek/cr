# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`cr` — a single bash script CLI tool that runs AI code reviews in parallel using Claude, Gemini, and Codex CLIs. No dependencies, no build step.

## Commands

```bash
make install          # symlinks cr.sh → /usr/local/bin/cr
make uninstall        # removes the symlink
cr --help             # usage info
cr -r claude -s       # quick test: single reviewer, staged changes only
```

## Architecture

Everything is in `cr.sh` (~530 lines). The flow:

1. **parse_args** → CLI flags (-r, -s, -t, --no-color)
2. **check_prerequisites** → verifies git repo, detects available CLI tools
3. **gather_diff** → `git diff HEAD` (or `--cached` for staged-only), filters binaries, truncates large diffs
4. **gather_context** → project tree (`git ls-tree`) + full contents of changed files
5. **build_prompt** → assembles structured review prompt with 3 layers of context
6. **run_single_reviewer** → runs one reviewer with stdin pipe + watchdog timeout
7. **run_reviewers** → launches all reviewers as background processes, animated spinner progress
8. **display_results** → colored output with per-reviewer sections and summary

Key design decisions:
- Prompt is written to a temp file and piped via stdin to avoid ARG_MAX limits
- Claude invocation uses `env -u CLAUDECODE` to allow running from within Claude Code sessions
- Codex uses `--output-last-message` flag to capture only the final review (suppresses verbose debug output)
- Config loading: `~/.cr.conf` (global) → `./.cr.conf` (project) → CLI args (highest priority)
- macOS has no `timeout` command, so timeout uses a sleep+kill watchdog pattern
- Time formatting via `fmt_time()` — displays seconds < 60 as `Ns`, otherwise as `XmYs`
- Progress spinner uses braille characters with `printf %b` for color escape interpretation

## Testing Changes

There's no test suite. To verify changes work:
1. Stage some files in any git repo
2. Run `cr -r claude -s` (single reviewer is faster for iteration)
3. Run `cr -s` to test all 3 reviewers in parallel
4. Test edge cases: `cr` in non-git dir, `cr` with no changes, `cr -t abc` for invalid input
