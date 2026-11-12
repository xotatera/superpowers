#!/usr/bin/env bash
# Fast tests for start-server.sh shell-only platform decisions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
START_SCRIPT="$REPO_ROOT/skills/brainstorming/scripts/start-server.sh"

TEST_DIR="${TMPDIR:-/tmp}/brainstorm-start-test-$$"
passed=0
failed=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  passed=$((passed + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "    $2"
  failed=$((failed + 1))
}

make_fake_uname() {
  local fake_bin="$1"
  cat > "$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
  echo "MINGW64_NT-10.0"
else
  /usr/bin/uname "$@"
fi
EOF
  chmod +x "$fake_bin/uname"
}

echo ""
echo "--- start-server.sh platform detection ---"

mkdir -p "$TEST_DIR/fake-bin" "$TEST_DIR/project"
make_fake_uname "$TEST_DIR/fake-bin"

cat > "$TEST_DIR/fake-bin/node" <<'EOF'
#!/usr/bin/env bash
echo "CAPTURED_OWNER_PID=${BRAINSTORM_OWNER_PID:-__UNSET__}"
printf 'CAPTURED_ARGV=%s\n' "$@"
exit 0
EOF
chmod +x "$TEST_DIR/fake-bin/node"

captured=$(
  PATH="$TEST_DIR/fake-bin:$PATH" \
    MSYSTEM="" \
    bash "$START_SCRIPT" --project-dir "$TEST_DIR/project" --foreground 2>/dev/null || true
)
owner_pid_value=$(echo "$captured" | grep "CAPTURED_OWNER_PID=" | head -1 | sed 's/CAPTURED_OWNER_PID=//')

if [[ "$owner_pid_value" == "" || "$owner_pid_value" == "__UNSET__" ]]; then
  pass "clears BRAINSTORM_OWNER_PID when uname reports a Windows-like shell"
else
  fail "clears BRAINSTORM_OWNER_PID when uname reports a Windows-like shell" \
       "expected empty or unset, got '$owner_pid_value'"
fi

if echo "$captured" | grep -Eq '^CAPTURED_ARGV=--brainstorm-server-id=[A-Za-z0-9_-]{32,64}$'; then
  pass "passes shell-safe server instance id argv"
else
  fail "passes shell-safe server instance id argv" \
       "expected exact --brainstorm-server-id=<safe id> argv line, got: $captured"
fi

server_id_file=$(find "$TEST_DIR/project/.superpowers/brainstorm" -name server-instance-id -print 2>/dev/null | head -1)
server_id_value=""
if [[ -n "$server_id_file" ]]; then
  server_id_value="$(tr -d '\r\n' < "$server_id_file")"
fi
if [[ "$server_id_value" =~ ^[A-Za-z0-9_-]{32,64}$ ]]; then
  pass "writes shell-safe server-instance-id state file"
else
  fail "writes shell-safe server-instance-id state file" \
       "expected valid id in state, got '$server_id_value'"
fi

rm -rf "$TEST_DIR/project"/*

cat > "$TEST_DIR/fake-bin/node" <<'EOF'
#!/usr/bin/env bash
echo "FOREGROUND_MODE=true"
exit 0
EOF
chmod +x "$TEST_DIR/fake-bin/node"

captured=$(
  PATH="$TEST_DIR/fake-bin:$PATH" \
    MSYSTEM="" \
    bash "$START_SCRIPT" --project-dir "$TEST_DIR/project" 2>/dev/null || true
)

if echo "$captured" | grep -q "FOREGROUND_MODE=true"; then
  pass "auto-foregrounds when uname reports a Windows-like shell"
else
  fail "auto-foregrounds when uname reports a Windows-like shell" \
       "expected foreground node path, got: $captured"
fi

echo ""
echo "--- start-server.sh relative --project-dir ---"

cat > "$TEST_DIR/fake-bin/node" <<'EOF'
#!/usr/bin/env bash
echo "CAPTURED_BRAINSTORM_DIR=${BRAINSTORM_DIR:-__UNSET__}"
exit 0
EOF
chmod +x "$TEST_DIR/fake-bin/node"

# The script cds into its own directory before starting the server, so a
# relative --project-dir must be resolved against the caller's cwd first.
# Covers an existing dir and a not-yet-created one, both with spaces.
for relative_dir in "." "new project dir"; do
  caller_dir="$TEST_DIR/caller with space"
  rm -rf "$caller_dir"
  mkdir -p "$caller_dir"
  expected_root="$(cd "$caller_dir" && pwd)"
  if [[ "$relative_dir" != "." ]]; then
    expected_root="$expected_root/$relative_dir"
  fi

  captured=$(
    cd "$caller_dir" &&
      PATH="$TEST_DIR/fake-bin:$PATH" \
        MSYSTEM="" \
        bash "$START_SCRIPT" --project-dir "$relative_dir" --foreground 2>&1 || true
  )
  brainstorm_dir=$(echo "$captured" | grep "CAPTURED_BRAINSTORM_DIR=" | head -1 | sed 's/CAPTURED_BRAINSTORM_DIR=//')

  case "$brainstorm_dir" in
    "$expected_root/.superpowers/brainstorm/"*)
      pass "--project-dir '$relative_dir' gives the server an absolute session dir under the caller's cwd" ;;
    *)
      fail "--project-dir '$relative_dir' gives the server an absolute session dir under the caller's cwd" \
           "expected prefix '$expected_root/.superpowers/brainstorm/', got: $captured" ;;
  esac

  if [[ -n "$brainstorm_dir" && -f "$brainstorm_dir/state/server.pid" ]]; then
    pass "--project-dir '$relative_dir' writes server.pid into the project session dir"
  else
    fail "--project-dir '$relative_dir' writes server.pid into the project session dir" \
         "no server.pid under '$brainstorm_dir/state', output: $captured"
  fi
done

echo ""
echo "--- start-server.sh default /tmp session dir ---"

# Without --project-dir the session lives under /tmp. Its name must not be
# guessable (another local account could create it first and plant a
# state/server.pid), and the script must create it itself, owner-only.
captured=$(
  PATH="$TEST_DIR/fake-bin:$PATH" \
    MSYSTEM="" \
    bash "$START_SCRIPT" --foreground 2>&1 || true
)
tmp_session_dir=$(echo "$captured" | grep "CAPTURED_BRAINSTORM_DIR=" | head -1 | sed 's/CAPTURED_BRAINSTORM_DIR=//')

if [[ "$tmp_session_dir" == /tmp/brainstorm-* && -d "$tmp_session_dir" ]]; then
  pass "default session dir is created under /tmp/brainstorm-*"
else
  fail "default session dir is created under /tmp/brainstorm-*" "got: $captured"
fi

if [[ -n "$tmp_session_dir" && ! "$tmp_session_dir" =~ ^/tmp/brainstorm-[0-9]+-[0-9]+$ ]]; then
  pass "default session dir name is not <pid>-<epoch>"
else
  fail "default session dir name is not <pid>-<epoch>" "got: '$tmp_session_dir'"
fi

if [[ -n "$tmp_session_dir" && "$(stat -c %a "$tmp_session_dir" 2>/dev/null)" == "700" ]]; then
  pass "default session dir is owner-only (700) (regression check: umask 077 already gave this)"
else
  fail "default session dir is owner-only (700) (regression check: umask 077 already gave this)" "mode: $(stat -c %a "$tmp_session_dir" 2>/dev/null)"
fi

if [[ "$tmp_session_dir" == /tmp/brainstorm-* ]]; then
  rm -rf "$tmp_session_dir"
fi

echo ""
echo "--- start-server.sh never signals a PID it did not start ---"

# Plant a state/server.pid naming a process this test owns, in the session
# directory the script would pick if its name were guessable (<pid>-<epoch>),
# then let the script run. The planted process must survive.
cat > "$TEST_DIR/fake-bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%s" ]]; then echo 1700000000; else /usr/bin/date "$@"; fi
EOF
chmod +x "$TEST_DIR/fake-bin/date"
plant_project="$TEST_DIR/plant project"
rm -rf "$plant_project"
mkdir -p "$plant_project"
sleep 300 &
sleeper=$!
gate="$TEST_DIR/gate"
launcher_pid_file="$TEST_DIR/launcher.pid"
rm -f "$gate" "$launcher_pid_file"
mkfifo "$gate"
(
  PATH="$TEST_DIR/fake-bin:$PATH" MSYSTEM="" \
    bash -c 'echo $$ > "$1"; read -r _ < "$2"; exec bash "$3" --project-dir "$4" --foreground' \
    _ "$launcher_pid_file" "$gate" "$START_SCRIPT" "$plant_project" >/dev/null 2>&1
) &
launcher=$!
until [[ -s "$launcher_pid_file" ]]; do sleep 0.05; done
planted_state="$plant_project/.superpowers/brainstorm/$(cat "$launcher_pid_file")-1700000000/state"
mkdir -p "$planted_state"
echo "$sleeper" > "$planted_state/server.pid"
echo go > "$gate"
wait "$launcher"
if kill -0 "$sleeper" 2>/dev/null; then
  pass "a planted state/server.pid is never signalled"
else
  fail "a planted state/server.pid is never signalled" "the planted process $sleeper was killed"
fi
kill "$sleeper" 2>/dev/null
wait "$sleeper" 2>/dev/null
rm -f "$TEST_DIR/fake-bin/date"

echo ""
echo "--- start-server.sh project session files stay out of git ---"

ignore_project="$TEST_DIR/ignore project"
rm -rf "$ignore_project"
mkdir -p "$ignore_project"
PATH="$TEST_DIR/fake-bin:$PATH" MSYSTEM="" \
  bash "$START_SCRIPT" --project-dir "$ignore_project" --foreground >/dev/null 2>&1 || true
if [[ "$(cat "$ignore_project/.superpowers/brainstorm/.gitignore" 2>/dev/null)" == "*" ]]; then
  pass "writes .superpowers/brainstorm/.gitignore ignoring everything (the key file lives there)"
else
  fail "writes .superpowers/brainstorm/.gitignore ignoring everything (the key file lives there)" \
       "got: '$(cat "$ignore_project/.superpowers/brainstorm/.gitignore" 2>/dev/null)'"
fi
printf 'custom\n' > "$ignore_project/.superpowers/brainstorm/.gitignore"
PATH="$TEST_DIR/fake-bin:$PATH" MSYSTEM="" \
  bash "$START_SCRIPT" --project-dir "$ignore_project" --foreground >/dev/null 2>&1 || true
if [[ "$(cat "$ignore_project/.superpowers/brainstorm/.gitignore")" == "custom" ]]; then
  pass "an existing .superpowers/brainstorm/.gitignore is not overwritten"
else
  fail "an existing .superpowers/brainstorm/.gitignore is not overwritten" "it was rewritten"
fi

echo ""
echo "--- start-server.sh error output is valid JSON ---"

is_json() {
  node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))' <<<"$1" 2>/dev/null
}

captured=$(bash "$START_SCRIPT" 'bad"arg\x' 2>/dev/null || true)
if is_json "$captured"; then
  pass "an unknown argument with a quote and a backslash still yields valid JSON"
else
  fail "an unknown argument with a quote and a backslash still yields valid JSON" "got: $captured"
fi

cat > "$TEST_DIR/fake-bin/node" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"server-started"}'
exit 0
EOF
chmod +x "$TEST_DIR/fake-bin/node"
quote_project="$TEST_DIR/quote\"project"
rm -rf "$quote_project"
mkdir -p "$quote_project"
captured=$(
  PATH="$TEST_DIR/fake-bin:$PATH" MSYSTEM="" \
    bash "$START_SCRIPT" --project-dir "$quote_project" --background 2>/dev/null || true
)
if echo "$captured" | grep -q "Server started but was killed" && is_json "$captured"; then
  pass "the killed-server retry message is valid JSON for a project dir containing a quote"
else
  fail "the killed-server retry message is valid JSON for a project dir containing a quote" "got: $captured"
fi

echo ""
echo "--- Results: $passed passed, $failed failed ---"
if [[ $failed -gt 0 ]]; then
  exit 1
fi
