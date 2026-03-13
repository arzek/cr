#!/usr/bin/env bash
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    BLUE=$'\033[0;34m'
    PURPLE=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    YELLOW=$'\033[1;33m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED='' GREEN='' BLUE='' PURPLE='' CYAN='' YELLOW='' BOLD='' DIM='' NC=''
fi

# ── Helpers ─────────────────────────────────────────────────────────────────
fmt_time() {
    local secs="$1"
    if [[ "$secs" -ge 60 ]]; then
        echo "$((secs / 60))m$((secs % 60))s"
    else
        echo "${secs}s"
    fi
}

# ── Defaults ────────────────────────────────────────────────────────────────
REVIEWERS="claude,gemini,codex"
TIMEOUT=300
MAX_DIFF_LINES=3000
MAX_FILE_LINES=500
MODEL=""
LANG_CODE="en"
STAGED_ONLY=false
AI_MODE=false
TARGET_DIR="."

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
cr — AI-Powered Code Review

Usage: cr [OPTIONS] [DIRECTORY]

Options:
  -r, --reviewers LIST    Comma-separated: claude,gemini,codex (default: all)
  -m, --model MODEL       Model to use for reviewers (e.g. sonnet, o3, etc.)
  -s, --staged-only       Only review staged changes (git diff --cached)
  -t, --timeout SECS      Timeout per reviewer in seconds (default: 300)
  -l, --lang LANG         Review language: en, uk, de, fr, es, ja (default: en)
      --ai                Compact output optimized for AI agents (no banner, no colors)
      --no-color          Disable colored output
  -h, --help              Show this help

Examples:
  cr                      Review all uncommitted changes
  cr /path/to/repo        Review changes in a specific repo
  cr -r claude            Use only Claude
  cr -r claude,gemini     Use Claude and Gemini
  cr -m sonnet            Use specific model for all reviewers
  cr -s                   Review only staged changes
  cr -l uk                Review in Ukrainian
  cr -t 180               Set timeout to 3 minutes
  cr --ai                 Output optimized for AI consumption
USAGE
    exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--reviewers) REVIEWERS="$2"; shift 2 ;;
            -m|--model) MODEL="$2"; shift 2 ;;
            -s|--staged-only) STAGED_ONLY=true; shift ;;
            -t|--timeout)
                if [[ "$2" =~ ^[0-9]+$ ]]; then
                    TIMEOUT="$2"
                else
                    echo "Error: --timeout must be a number, got '$2'" >&2
                    exit 1
                fi
                shift 2 ;;
            -l|--lang) LANG_CODE="$2"; shift 2 ;;
            --ai) AI_MODE=true; RED='' GREEN='' BLUE='' PURPLE='' CYAN='' YELLOW='' BOLD='' DIM='' NC=''; shift ;;
            --no-color) RED='' GREEN='' BLUE='' PURPLE='' CYAN='' YELLOW='' BOLD='' DIM='' NC=''; shift ;;
            -h|--help) usage ;;
            -*) echo "Unknown option: $1" >&2; usage ;;
            *) TARGET_DIR="$1"; shift ;;
        esac
    done
}

# ── Prerequisites ──────────────────────────────────────────────────────────
check_prerequisites() {
    # Check if target is a git repo
    if ! git -C "$TARGET_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        echo "${RED}Error:${NC} $TARGET_DIR is not a git repository." >&2
        exit 1
    fi

    # Check which reviewers are available
    local available=()
    local missing=()
    IFS=',' read -ra requested_reviewers <<< "$REVIEWERS"

    for reviewer in "${requested_reviewers[@]}"; do
        reviewer=$(echo "$reviewer" | tr -d '[:space:]')
        case "$reviewer" in
            claude)
                if command -v claude &>/dev/null; then
                    available+=("claude")
                else
                    missing+=("claude")
                fi
                ;;
            gemini)
                if command -v gemini &>/dev/null; then
                    available+=("gemini")
                else
                    missing+=("gemini")
                fi
                ;;
            codex)
                if command -v codex &>/dev/null; then
                    available+=("codex")
                else
                    missing+=("codex")
                fi
                ;;
            *)
                echo "${YELLOW}Warning:${NC} Unknown reviewer '$reviewer', skipping." >&2
                ;;
        esac
    done

    # Warn about missing tools
    if [[ ${#missing[@]} -gt 0 ]]; then
        for tool in "${missing[@]}"; do
            echo "${YELLOW}Warning:${NC} '$tool' not found, skipping." >&2
        done
    fi

    if [[ ${#available[@]} -eq 0 ]]; then
        echo "${RED}Error:${NC} No reviewers available. Install at least one of: claude, gemini, codex" >&2
        exit 1
    fi

    ACTIVE_REVIEWERS=("${available[@]}")
}

# ── Gather diff ────────────────────────────────────────────────────────────
gather_diff() {
    local diff_output

    if [[ "$STAGED_ONLY" == true ]]; then
        diff_output=$(git -C "$TARGET_DIR" diff --cached -- . ':(exclude)*.lock' ':(exclude)*.min.js' ':(exclude)*.min.css' 2>/dev/null || true)
    else
        # Try diff HEAD first (works when there are commits)
        diff_output=$(git -C "$TARGET_DIR" diff HEAD -- . ':(exclude)*.lock' ':(exclude)*.min.js' ':(exclude)*.min.css' 2>/dev/null || true)
        # If empty and HEAD failed, try staged only (initial commit case)
        if [[ -z "$diff_output" ]]; then
            diff_output=$(git -C "$TARGET_DIR" diff --cached -- . ':(exclude)*.lock' ':(exclude)*.min.js' ':(exclude)*.min.css' 2>/dev/null || true)
        fi
    fi

    # Filter out binary files
    diff_output=$(echo "$diff_output" | grep -v "^Binary files" || true)

    if [[ -z "$diff_output" ]]; then
        echo ""
        echo "  ${GREEN}Nothing to review${NC} ${DIM}— no changes detected.${NC}"
        echo ""
        exit 0
    fi

    # Truncate if too large
    local line_count
    line_count=$(echo "$diff_output" | wc -l | tr -d '[:space:]')

    if [[ "$line_count" -gt "$MAX_DIFF_LINES" ]]; then
        echo "${YELLOW}Warning:${NC} Diff is $line_count lines, truncating to $MAX_DIFF_LINES." >&2
        diff_output=$(echo "$diff_output" | head -n "$MAX_DIFF_LINES")
        diff_output+=$'\n[TRUNCATED: diff exceeded '"$MAX_DIFF_LINES"' lines]'
    fi

    DIFF_OUTPUT="$diff_output"
    DIFF_LINES="$line_count"
}

# ── Gather file context ───────────────────────────────────────────────────
gather_context() {
    # 1. Project structure
    local project_tree
    project_tree=$(git -C "$TARGET_DIR" ls-tree --name-only -r HEAD 2>/dev/null | head -200 || true)
    if [[ -z "$project_tree" ]]; then
        # No commits yet — use find
        project_tree=$(find "$TARGET_DIR" -not -path '*/.git/*' -not -path '*/node_modules/*' -type f | head -200 | sed "s|^$TARGET_DIR/||" || true)
    fi
    PROJECT_TREE="$project_tree"

    # 2. Changed file list
    local changed_files
    if [[ "$STAGED_ONLY" == true ]]; then
        changed_files=$(git -C "$TARGET_DIR" diff --cached --name-only 2>/dev/null || true)
    else
        changed_files=$(git -C "$TARGET_DIR" diff HEAD --name-only 2>/dev/null || true)
        if [[ -z "$changed_files" ]]; then
            changed_files=$(git -C "$TARGET_DIR" diff --cached --name-only 2>/dev/null || true)
        fi
    fi
    CHANGED_FILES="$changed_files"
    CHANGED_COUNT=$(echo "$changed_files" | grep -c '.' || echo "0")

    # 3. Full contents of changed files
    local file_contents=""
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local full_path="$TARGET_DIR/$file"
        if [[ -f "$full_path" ]]; then
            # Skip binary files
            if file "$full_path" | grep -q "text"; then
                local content
                content=$(head -n "$MAX_FILE_LINES" "$full_path" 2>/dev/null || true)
                local actual_lines
                actual_lines=$(wc -l < "$full_path" 2>/dev/null | tr -d '[:space:]')
                file_contents+="=== FILE: $file ($actual_lines lines) ===
$content"
                if [[ "$actual_lines" -gt "$MAX_FILE_LINES" ]]; then
                    file_contents+="
[TRUNCATED at $MAX_FILE_LINES lines]"
                fi
                file_contents+=$'\n\n'
            fi
        fi
    done <<< "$changed_files"
    FILE_CONTENTS="$file_contents"
}

# ── Build prompt ───────────────────────────────────────────────────────────
build_prompt() {
    local repo_name branch_name
    repo_name=$(basename "$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || basename "$TARGET_DIR")
    branch_name=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null || echo "unknown")

    REVIEW_PROMPT="You are an expert code reviewer performing a technical review of code changes.

PROJECT: $repo_name (branch: $branch_name)
CHANGED FILES: $CHANGED_FILES

PROJECT STRUCTURE:
$PROJECT_TREE

CHANGED FILES (full content for context):
$FILE_CONTENTS

DIFF TO REVIEW:
$DIFF_OUTPUT

TASK: Review ONLY the changes shown in the DIFF above. The full file contents and project structure are provided only for context — do not review them.

First, detect the tech stack from the project structure and file extensions (e.g. package.json = Node/TS, go.mod = Go, Cargo.toml = Rust, etc.). Apply the idiomatic conventions of that stack throughout your review.

Focus on:
1. Bugs & logic errors — incorrect logic, off-by-one, null/undefined, race conditions, missing edge cases
2. Security — injection, exposed secrets, unsafe deserialization, auth gaps
3. Performance — unnecessary allocations, O(n²) where O(n) possible, unbounded growth
4. Error handling — swallowed errors, missing validation, unhandled rejections
5. Code quality — naming clarity, dead code, unnecessary complexity
6. Conventions & idioms — file/folder naming, project structure, patterns and style expected by the detected stack (e.g. Go: if err != nil, cmd/internal layout; NestJS: *.module.ts, DTOs, decorators; React: PascalCase components, use* hooks)

OUTPUT FORMAT:
- Start with a one-line severity summary: \"No issues found\" OR \"Found N issues (X critical, Y warnings, Z suggestions)\"
- List each finding as: [CRITICAL|WARNING|SUGGESTION] filename:line — description and recommended fix
- End with a brief overall assessment (2-3 sentences max)
- Be concise. Do NOT repeat the code back. Do NOT praise. Only report findings.
- If there are no issues, say so briefly.
$(if [[ "$LANG_CODE" != "en" ]]; then echo "
IMPORTANT: Write your ENTIRE review in the language with code '$LANG_CODE'. All descriptions, assessments, and explanations must be in that language. Keep technical terms, filenames, and code references as-is."; fi)"
}

# ── Run a single reviewer ──────────────────────────────────────────────────
run_single_reviewer() {
    local reviewer="$1"
    local prompt_file="$2"
    local out_file="$3"
    local err_file="$4"
    local time_file="$5"
    local status_file="$6"
    local timeout_secs="$7"

    local start_time=$SECONDS
    local cmd_pid

    case "$reviewer" in
        claude)
            local model_flag=""
            [[ -n "${MODEL:-}" ]] && model_flag="--model $MODEL"
            env -u CLAUDECODE claude -p --no-session-persistence $model_flag < "$prompt_file" > "$out_file" 2> "$err_file" &
            cmd_pid=$!
            ;;
        gemini)
            local model_flag=""
            [[ -n "${MODEL:-}" ]] && model_flag="-m $MODEL"
            gemini $model_flag < "$prompt_file" > "$out_file" 2> "$err_file" &
            cmd_pid=$!
            ;;
        codex)
            local model_flag=""
            [[ -n "${MODEL:-}" ]] && model_flag="-m $MODEL"
            codex exec $model_flag --output-last-message "$out_file" - < "$prompt_file" > /dev/null 2> "$err_file" &
            cmd_pid=$!
            ;;
    esac

    # Watchdog: kill after timeout
    (
        sleep "$timeout_secs"
        kill "$cmd_pid" 2>/dev/null
    ) &
    local watchdog_pid=$!

    # Wait for the command
    if wait "$cmd_pid" 2>/dev/null; then
        echo "ok" > "$status_file"
    else
        local code=$?
        if [[ $code -eq 137 ]] || [[ $code -eq 143 ]]; then
            echo "timeout" > "$status_file"
        else
            echo "error" > "$status_file"
        fi
    fi

    # Kill watchdog
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null || true

    echo "$((SECONDS - start_time))" > "$time_file"
}

# ── Display one reviewer result ────────────────────────────────────────────
display_one_result() {
    local reviewer="$1"

    local upper_name
    upper_name=$(echo "$reviewer" | tr '[:lower:]' '[:upper:]')
    local status_file="$TMP_DIR/${reviewer}.status"
    local out_file="$TMP_DIR/${reviewer}.out"
    local err_file="$TMP_DIR/${reviewer}.err"
    local time_file="$TMP_DIR/${reviewer}.time"

    local elapsed_raw="?"
    [[ -f "$time_file" ]] && elapsed_raw=$(cat "$time_file")
    local elapsed_fmt
    if [[ "$elapsed_raw" == "?" ]]; then
        elapsed_fmt="?"
    else
        elapsed_fmt=$(fmt_time "$elapsed_raw")
    fi

    local status="ok"
    [[ -f "$status_file" ]] && status=$(cat "$status_file")

    if [[ "$AI_MODE" == true ]]; then
        echo "## ${upper_name}"
        if [[ "$status" == "ok" ]] && [[ -f "$out_file" ]] && [[ -s "$out_file" ]]; then
            cat "$out_file"
        elif [[ "$status" == "timeout" ]]; then
            echo "TIMEOUT after ${TIMEOUT}s"
        else
            echo "FAILED"
        fi
        echo ""
        return
    fi

    local color
    case "$reviewer" in
        claude) color="$PURPLE" ;;
        gemini) color="$BLUE" ;;
        codex)  color="$GREEN" ;;
        *)      color="$CYAN" ;;
    esac

    echo ""
    if [[ "$status" == "ok" ]]; then
        local pad_len=$((54 - ${#upper_name} - ${#elapsed_fmt}))
        [[ $pad_len -lt 4 ]] && pad_len=4
        local padding=""
        for ((p=0; p<pad_len; p++)); do padding+="━"; done
        echo "${color}━━ ${BOLD}${upper_name}${NC} ${color}${padding} ${DIM}${elapsed_fmt}${NC}"
        echo ""
        if [[ -f "$out_file" ]] && [[ -s "$out_file" ]]; then
            sed 's/^/  /' "$out_file"
        else
            echo "  ${DIM}(no output)${NC}"
        fi
    elif [[ "$status" == "timeout" ]]; then
        echo "${RED}━━ ${BOLD}${upper_name}${NC} ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ TIMEOUT ${TIMEOUT}s${NC}"
        echo "  ${RED}Timed out after ${TIMEOUT}s${NC}"
        if [[ -f "$err_file" ]] && [[ -s "$err_file" ]]; then
            echo "  ${DIM}$(head -5 "$err_file")${NC}"
        fi
    else
        echo "${RED}━━ ${BOLD}${upper_name}${NC} ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ FAILED${NC}"
        if [[ -f "$err_file" ]] && [[ -s "$err_file" ]]; then
            echo "  ${RED}$(head -10 "$err_file")${NC}"
        fi
        if [[ -f "$out_file" ]] && [[ -s "$out_file" ]]; then
            sed 's/^/  /' "$out_file"
        fi
    fi
}

# ── Run reviewers and stream results ──────────────────────────────────────
run_and_stream() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    TMP_DIR="$tmp_dir"
    trap 'kill 0 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP_DIR"' EXIT INT TERM

    # Write prompt to temp file
    local prompt_file="$tmp_dir/prompt.txt"
    printf '%s' "$REVIEW_PROMPT" > "$prompt_file"

    local pids=()
    local names=()

    for reviewer in "${ACTIVE_REVIEWERS[@]}"; do
        run_single_reviewer \
            "$reviewer" \
            "$prompt_file" \
            "$tmp_dir/${reviewer}.out" \
            "$tmp_dir/${reviewer}.err" \
            "$tmp_dir/${reviewer}.time" \
            "$tmp_dir/${reviewer}.status" \
            "$TIMEOUT" &
        pids+=($!)
        names+=("$reviewer")
    done

    # Header
    local total_start=$SECONDS

    if [[ "$AI_MODE" != true ]]; then
        local repo_name branch_name
        repo_name=$(basename "$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || basename "$TARGET_DIR")
        branch_name=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null || echo "unknown")
        local display_branch="$branch_name"
        if [[ ${#display_branch} -gt 30 ]]; then
            display_branch="${display_branch:0:27}..."
        fi
        local title="$repo_name ($display_branch)"

        echo "  ${DIM}──────────────────────────────────────────────────────────${NC}"
        echo "  ${BOLD}${title}${NC}"
        echo "  ${DIM}${CHANGED_COUNT} files changed ${DIM}·${NC}${DIM} ${DIFF_LINES} diff lines${NC}"
        echo "  ${DIM}──────────────────────────────────────────────────────────${NC}"

        local reviewer_list="${ACTIVE_REVIEWERS[*]}"
        echo ""
        echo "  ${DIM}Reviewing with:${NC} ${BOLD}${reviewer_list// /, }${NC}"
    fi

    # Stream results as they finish
    local displayed=()
    local succeeded=0
    local failed=0
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_idx=0

    for reviewer in "${ACTIVE_REVIEWERS[@]}"; do
        displayed+=("false")
    done

    while true; do
        local all_done=true
        local new_results=false

        # Check for newly finished reviewers
        for i in "${!pids[@]}"; do
            if [[ "${displayed[$i]}" == "false" ]] && ! kill -0 "${pids[$i]}" 2>/dev/null; then
                # Clear spinner line before printing result
                if [[ "$AI_MODE" != true ]]; then
                    printf "\r%80s\r" ""
                fi
                displayed[$i]="true"
                new_results=true

                local s_file="$tmp_dir/${names[$i]}.status"
                if [[ -f "$s_file" ]] && [[ "$(cat "$s_file")" == "ok" ]]; then
                    succeeded=$((succeeded + 1))
                else
                    failed=$((failed + 1))
                fi

                display_one_result "${names[$i]}"
            fi
        done

        # Check if all done
        for i in "${!displayed[@]}"; do
            if [[ "${displayed[$i]}" == "false" ]]; then
                all_done=false
                break
            fi
        done

        [[ "$all_done" == true ]] && break

        # Show spinner for remaining reviewers
        if [[ "$AI_MODE" != true ]]; then
            local spinner="${spin_chars[$spin_idx]}"
            spin_idx=$(( (spin_idx + 1) % ${#spin_chars[@]} ))
            local elapsed=$((SECONDS - total_start))
            local status_line="  "

            for i in "${!pids[@]}"; do
                if [[ "${displayed[$i]}" == "false" ]]; then
                    status_line+="${CYAN}${spinner} ${names[$i]}${NC}  "
                fi
            done
            status_line+="${DIM}$(fmt_time $elapsed)${NC}"
            printf "\r%b" "$status_line"
        fi

        sleep 0.1
    done

    if [[ "$AI_MODE" != true ]]; then
        printf "\r%80s\r" ""
    fi

    TOTAL_TIME=$((SECONDS - total_start))

    # Summary
    if [[ "$AI_MODE" != true ]]; then
        echo ""
        echo "  ${DIM}──────────────────────────────────────────────────────────${NC}"
        local total=${#ACTIVE_REVIEWERS[@]}
        if [[ $failed -eq 0 ]]; then
            echo "  ${GREEN}${BOLD}${succeeded}/${total} passed${NC}  ${DIM}·${NC}  ${BOLD}$(fmt_time $TOTAL_TIME)${NC} ${DIM}(parallel)${NC}"
        else
            echo "  ${YELLOW}${BOLD}${succeeded}/${total} passed${NC}  ${DIM}·${NC}  ${RED}${BOLD}${failed} failed${NC}  ${DIM}·${NC}  ${BOLD}$(fmt_time $TOTAL_TIME)${NC} ${DIM}(parallel)${NC}"
        fi
        echo ""
    fi
}

# ── Banner ─────────────────────────────────────────────────────────────────
show_banner() {
    [[ "$AI_MODE" == true ]] && return
    echo ""
    echo "${PURPLE}${BOLD}     _____ _____  ${NC}"
    echo "${PURPLE}${BOLD}    / ____|  __ \\ ${NC}${DIM}  AI-Powered Code Review${NC}"
    echo "${PURPLE}${BOLD}   | |    | |__) |${NC}${DIM}  Three reviewers. One command.${NC}"
    echo "${PURPLE}${BOLD}   | |    |  _  / ${NC}"
    echo "${PURPLE}${BOLD}   | |____|  | \\ \\ ${NC}"
    echo "${PURPLE}${BOLD}    \\_____|  |  \\_\\${NC}"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    show_banner
    check_prerequisites
    gather_diff
    gather_context
    build_prompt
    run_and_stream
}

main "$@"
