#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/skills/writing-skills/render-graphs.js"
# Resolve the real binary: version-manager shims (mise, asdf) can't find node
# under the empty PATH used for the missing-Graphviz case.
NODE_BIN="$(node -p 'process.execPath')"

PASSES=0
FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  echo "  [PASS] $1"
  PASSES=$((PASSES + 1))
}

fail() {
  echo "  [FAIL] $1"
  FAILURES=$((FAILURES + 1))
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local description="$3"

  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    pass "$description"
  else
    fail "$description"
    echo "    expected to find: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local description="$3"

  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    fail "$description"
    echo "    did not expect to find: $needle"
  else
    pass "$description"
  fi
}

fixture="$TEST_ROOT/fixture-skill"
mkdir -p "$fixture" "$TEST_ROOT/empty-path"
cat >"$fixture/SKILL.md" <<'EOF'
---
name: fixture-skill
---

# Fixture Skill

```dot
digraph fixture_graph {
  start -> end;
}
```
EOF

echo "Writing-skills render-graphs tests"

# Use real Graphviz when present; otherwise a stand-in `dot` that emits
# minimal SVG, so the script's own behaviour is still tested.
RENDER_PATH="$PATH"
if ! command -v dot >/dev/null 2>&1; then
  mkdir -p "$TEST_ROOT/stub-bin"
  cat >"$TEST_ROOT/stub-bin/dot" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then exit 0; fi
cat >/dev/null
echo '<svg xmlns="http://www.w3.org/2000/svg"></svg>'
STUB
  chmod +x "$TEST_ROOT/stub-bin/dot"
  RENDER_PATH="$TEST_ROOT/stub-bin:$PATH"
fi

missing_dot_output="$(PATH="$TEST_ROOT/empty-path" "$NODE_BIN" "$SCRIPT_UNDER_TEST" "$fixture" 2>&1)"
missing_dot_status=$?

if [[ "$missing_dot_status" -ne 0 ]]; then
  pass "missing Graphviz exits non-zero"
else
  fail "missing Graphviz exits non-zero"
fi
assert_contains "$missing_dot_output" "Error: graphviz (dot) not found." "missing Graphviz reports install guidance"
assert_contains "$missing_dot_output" "package manager" "install guidance is not limited to brew and apt"
assert_not_contains "$missing_dot_output" "ReferenceError: require is not defined" "script runs as an ES module"

render_output="$(PATH="$RENDER_PATH" "$NODE_BIN" "$SCRIPT_UNDER_TEST" "$fixture" 2>&1)"
render_status=$?

if [[ "$render_status" -eq 0 ]]; then
  pass "fixture diagram renders"
else
  fail "fixture diagram renders"
  printf '%s\n' "$render_output"
fi

assert_contains "$render_output" "Found 1 diagram(s)" "reports discovered diagram"
assert_contains "$render_output" "Rendered: fixture_graph.svg" "reports rendered SVG"

out_dir="$(printf '%s\n' "$render_output" | sed -n 's/^Output: \(.*\)\/$/\1/p')"
if [[ -n "$out_dir" && -f "$out_dir/fixture_graph.svg" ]]; then
  pass "writes SVG output to the printed directory"
else
  fail "writes SVG output to the printed directory"
fi

if [[ -n "$out_dir" && -f "$out_dir/fixture_graph.svg" ]] && grep -Fq "<svg" "$out_dir/fixture_graph.svg"; then
  pass "SVG output has SVG markup"
else
  fail "SVG output has SVG markup"
fi

if [[ ! -e "$fixture/diagrams" && "$out_dir" != "$fixture"* ]]; then
  pass "by default nothing is written inside the skill directory"
else
  fail "by default nothing is written inside the skill directory"
fi
node_tmp="$("$NODE_BIN" -p 'require("os").tmpdir()')"
if [[ -n "$out_dir" && "$out_dir" == "$node_tmp"/render-graphs-* ]]; then
  pass "by default output goes to a fresh temporary directory"
  rm -rf "$out_dir"
else
  fail "by default output goes to a fresh temporary directory (got: '$out_dir')"
fi

chosen="$TEST_ROOT/chosen out"
out_output="$(PATH="$RENDER_PATH" "$NODE_BIN" "$SCRIPT_UNDER_TEST" "$fixture" --out "$chosen" 2>&1)"
if [[ -f "$chosen/fixture_graph.svg" ]]; then
  pass "--out writes into the chosen directory"
else
  fail "--out writes into the chosen directory"
  printf '%s\n' "$out_output"
fi

echo
echo "Results: $PASSES passed, $FAILURES failed"

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
