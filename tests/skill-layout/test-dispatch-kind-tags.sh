#!/usr/bin/env bash
# Every pasted dispatch template starts its prompt with exactly one kind tag,
# `<!-- superpowers-kind: <kind> -->`, which the lab's side log reads; the
# diagnosis skill tells the controller to tag its by-path dispatches; and the
# plan task template carries the per-task fields line.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILURES=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

# The prompt's first line: the first line inside the first fence, or, when
# the fence holds a `prompt: |` block, the first line after it.
first_prompt_line() {
  awk '
    /^```/ { if (infence) exit; infence = 1; next }
    infence && !seen { first = $0; seen = 1 }
    infence && /^[[:space:]]*prompt: \|[[:space:]]*$/ { want = 1; next }
    infence && want { sub(/^[[:space:]]+/, ""); print; done = 1; exit }
    END { if (!done && seen) print first }
  ' "$1"
}

check() {
  local file="$1" kind="$2"
  local path="$REPO_ROOT/$file"
  local line count
  line="$(first_prompt_line "$path")"
  count="$(grep -c 'superpowers-kind:' "$path")"
  if [[ "$line" == "<!-- superpowers-kind: $kind -->" && "$count" -eq 1 ]]; then
    pass "$file starts its prompt with the $kind tag"
  else
    fail "$file starts its prompt with the $kind tag (first line: '$line', tags: $count)"
  fi
}

echo "Dispatch kind tags"
check skills/brainstorming/builder-check-prompt.md builder-check
check skills/subagent-driven-development/implementer-prompt.md implementer
check skills/subagent-driven-development/task-reviewer-prompt.md task-review
check skills/subagent-driven-development/re-review-prompt.md re-review
check skills/requesting-code-review/code-reviewer.md code-review

if grep -qF '<!-- superpowers-kind: diagnosis-<' "$REPO_ROOT/skills/diagnosing-superpowers/SKILL.md"; then
  pass "diagnosing-superpowers tells the controller to tag each dispatch"
else
  fail "diagnosing-superpowers tells the controller to tag each dispatch"
fi

echo "Plan fields"
if grep -qF '**Size:** S|M|L · **Risk:** low|medium|high · **Owns:**' "$REPO_ROOT/skills/writing-plans/SKILL.md"; then
  pass "the plan task template carries the fields line"
else
  fail "the plan task template carries the fields line"
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then echo "$FAILURES failure(s)"; exit 1; fi
echo "All tests passed"
