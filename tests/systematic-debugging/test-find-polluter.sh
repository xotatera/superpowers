#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/skills/systematic-debugging/find-polluter.sh"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  echo "  [PASS] $1"
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
    fail "$description (expected output to contain: $needle)"
  fi
}

# Toy project: one top-level test, one nested test. A stubbed `npm` on PATH
# creates the pollution marker whenever any test runs, so the first test file
# executed is always identified as the polluter.
setup_project() {
  PROJECT="$TEST_ROOT/project"
  rm -rf "$PROJECT"
  mkdir -p "$PROJECT/src/feature" "$PROJECT/bin"
  echo "test('top')" > "$PROJECT/src/top.test.ts"
  echo "test('nested')" > "$PROJECT/src/feature/nested.test.ts"
  cat > "$PROJECT/bin/npm" <<'EOF'
#!/usr/bin/env bash
touch pollution.marker
EOF
  chmod +x "$PROJECT/bin/npm"
}

# run_polluter <pattern> — runs the script in the toy project with the stub
# npm first on PATH; captures combined output, never aborts on exit code.
run_polluter() {
  local pattern="$1"
  rm -f "$PROJECT/pollution.marker"
  (
    cd "$PROJECT"
    PATH="$PROJECT/bin:$PATH" "$SCRIPT_UNDER_TEST" 'pollution.marker' "$pattern" 2>&1
  ) || true
}

echo "Test: documented pattern finds nested test files (issue #2008)"
setup_project
OUTPUT="$(run_polluter 'src/**/*.test.ts')"
assert_contains "$OUTPUT" "FOUND POLLUTER" "documented pattern runs tests and detects pollution"

echo "Test: documented pattern also finds top-level test files"
setup_project
OUTPUT="$(run_polluter 'src/**/*.test.ts')"
assert_contains "$OUTPUT" "Found 2 test files" "src/**/*.test.ts matches src/top.test.ts and src/feature/nested.test.ts"

echo "Test: ./-prefixed pattern matches the same files"
setup_project
OUTPUT="$(run_polluter './src/**/*.test.ts')"
assert_contains "$OUTPUT" "Found 2 test files" "leading ./ on the pattern is accepted"

echo "Test: non-matching pattern reports an honest zero"
setup_project
OUTPUT="$(run_polluter 'nomatch/**/*.test.ts')"
assert_contains "$OUTPUT" "Found 0 test files" "empty result counts as 0, not 1"
assert_contains "$OUTPUT" "No polluter found" "empty result exits via the clean path"

echo "Test: a test path with a space is run as one path"
setup_project
rm -f "$PROJECT/src/top.test.ts" "$PROJECT/src/feature/nested.test.ts"
mkdir -p "$PROJECT/src/with space"
echo "test('spaced')" > "$PROJECT/src/with space/a b.test.ts"
cat > "$PROJECT/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> npm-args.log
touch pollution.marker
EOF
chmod +x "$PROJECT/bin/npm"
OUTPUT="$(run_polluter 'src/**/*.test.ts')"
assert_contains "$OUTPUT" "Testing: ./src/with space/a b.test.ts" "the whole spaced path is reported as one test"
FIRST_ARG="$(head -n 1 "$PROJECT/npm-args.log" 2>/dev/null || true)"
if [ "$FIRST_ARG" = "./src/with space/a b.test.ts" ]; then
  pass "npm test receives the whole spaced path as one argument"
else
  fail "npm test receives the whole spaced path as one argument (got: '$FIRST_ARG')"
fi

echo "Test: a test path with a glob character is not expanded"
setup_project
rm -f "$PROJECT/src/top.test.ts" "$PROJECT/src/feature/nested.test.ts"
echo "test('star')" > "$PROJECT/src/g*.test.ts"
echo "test('plain')" > "$PROJECT/src/gx.test.ts"
cat > "$PROJECT/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> npm-args.log
EOF
chmod +x "$PROJECT/bin/npm"
run_polluter 'src/*.test.ts' > /dev/null
RUNS="$(sort "$PROJECT/npm-args.log" 2>/dev/null | tr '\n' '|')"
if [ "$RUNS" = "./src/g*.test.ts|./src/gx.test.ts|" ]; then
  pass "each test file runs exactly once, by its own name"
else
  fail "each test file runs exactly once, by its own name (got: '$RUNS')"
fi

echo "Test: a test path with a newline is run as one path"
setup_project
rm -f "$PROJECT/src/top.test.ts" "$PROJECT/src/feature/nested.test.ts"
NL_FILE="$PROJECT/src/nl"$'\n'"name.test.ts"
echo "test('newline')" > "$NL_FILE"
cat > "$PROJECT/bin/npm" <<'EOF'
#!/usr/bin/env bash
if [ -f "$2" ]; then echo found >> npm-args.log; else echo missing >> npm-args.log; fi
EOF
chmod +x "$PROJECT/bin/npm"
OUTPUT="$(run_polluter 'src/*.test.ts')"
assert_contains "$OUTPUT" "Found 1 test files" "a newline in a name does not split it into two entries"
if [ "$(cat "$PROJECT/npm-args.log" 2>/dev/null)" = "found" ]; then
  pass "npm test receives the newline path as one existing file"
else
  fail "npm test receives the newline path as one existing file (got: '$(cat "$PROJECT/npm-args.log" 2>/dev/null | tr '\n' ' ')')"
fi

echo "Test: the printed follow-up commands quote a spaced path"
setup_project
rm -f "$PROJECT/src/top.test.ts" "$PROJECT/src/feature/nested.test.ts"
mkdir -p "$PROJECT/src/with space"
echo "test('spaced')" > "$PROJECT/src/with space/a b.test.ts"
OUTPUT="$(run_polluter 'src/**/*.test.ts')"
assert_contains "$OUTPUT" 'npm test ./src/with\ space/a\ b.test.ts' "the npm hint can be copied as one argument"
assert_contains "$OUTPUT" 'cat ./src/with\ space/a\ b.test.ts' "the cat hint can be copied as one argument"

echo "Test: tests inside node_modules are not run"
setup_project
mkdir -p "$PROJECT/node_modules/pkg/src" "$PROJECT/src/node_modules/inner"
echo "test('dep')" > "$PROJECT/node_modules/pkg/src/dep.test.ts"
echo "test('inner')" > "$PROJECT/src/node_modules/inner/inner.test.ts"
OUTPUT="$(run_polluter '**/*.test.ts')"
assert_contains "$OUTPUT" "Found 2 test files" "only the project's own two test files are found"

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All tests passed"
