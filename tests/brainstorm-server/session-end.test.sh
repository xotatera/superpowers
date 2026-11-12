#!/usr/bin/env bash
# Brainstorm servers stop when the Claude Code session that started them
# ends: start-server.sh registers each session directory under its owner's
# PID, and hooks/session-end stops what that owner registered.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
START="$REPO_ROOT/skills/brainstorming/scripts/start-server.sh"
STOP="$REPO_ROOT/skills/brainstorming/scripts/stop-server.sh"
HOOK="$REPO_ROOT/hooks/session-end"

PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "    $2"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
export XDG_RUNTIME_DIR="$T/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
REGISTRY="$XDG_RUNTIME_DIR/superpowers-brainstorm-$(id -u)"
SERVERS=()
cleanup() {
  for dir in "${SERVERS[@]}"; do bash "$STOP" "$dir" >/dev/null 2>&1; done
  rm -rf "$T"
}
trap cleanup EXIT

start_server() {
  local out dir
  out="$(bash "$START" --project-dir "$T/project" --background 2>/dev/null)"
  dir="$(printf '%s' "$out" | node -e 'const s=JSON.parse(require("fs").readFileSync(0,"utf8")); console.log(s.state_dir.replace(/\/state$/, ""))' 2>/dev/null)"
  SERVERS+=("$dir")
  printf '%s\n' "$dir"
}

server_pid() { cat "$1/state/server.pid" 2>/dev/null; }
owner_of() { grep -lxF "$1" "$REGISTRY"/* 2>/dev/null | head -1 | xargs -r basename; }

echo "--- registration ---"
dir="$(start_server)"
owner="$(owner_of "$dir")"
if [[ -n "$owner" && "$owner" =~ ^[0-9]+$ ]]; then
  ok "start-server.sh registers the session directory under its owner's PID"
else
  bad "start-server.sh registers the session directory under its owner's PID" "registry: $(ls -la "$REGISTRY" 2>&1)"
fi
if [[ "$(stat -c %a "$REGISTRY" 2>/dev/null)" == 700 && "$(stat -c %a "$REGISTRY/$owner" 2>/dev/null)" == 600 ]]; then
  ok "the registry is owner-only (directory 700, file 600)"
else
  bad "the registry is owner-only (directory 700, file 600)" "$(stat -c '%a %n' "$REGISTRY" "$REGISTRY/$owner" 2>&1)"
fi

echo "--- session end ---"
pid="$(server_pid "$dir")"
CLAUDE_PID=999999999 bash "$HOOK" </dev/null >"$T/out-other" 2>&1
if kill -0 "$pid" 2>/dev/null; then
  ok "a session end for another Claude process leaves the server running"
else
  bad "a session end for another Claude process leaves the server running" "server $pid gone"
fi
printf '{"session_id":"s","reason":"clear"}' | CLAUDE_PID="$owner" bash "$HOOK" >"$T/out-clear" 2>&1
if kill -0 "$pid" 2>/dev/null && [[ -f "$REGISTRY/$owner" ]]; then
  ok "a /clear leaves the owner's servers running and registered"
else
  bad "a /clear leaves the owner's servers running and registered" "server $pid or registry gone"
fi
printf '{"session_id":"s","reason":"prompt_input_exit"}' | CLAUDE_PID="$owner" bash "$HOOK" >"$T/out-own" 2>&1
for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if ! kill -0 "$pid" 2>/dev/null; then
  ok "the owner's session end stops its server"
else
  bad "the owner's session end stops its server" "server $pid still running"
fi
if [[ ! -e "$REGISTRY/$owner" && ! -s "$T/out-own" ]]; then
  ok "the owner's registry file is removed and the hook prints nothing"
else
  bad "the owner's registry file is removed and the hook prints nothing" "$(cat "$T/out-own")"
fi

echo "--- stop-server.sh ---"
dir2="$(start_server)"
owner2="$(owner_of "$dir2")"
bash "$STOP" "$dir2" >/dev/null 2>&1
if ! grep -qxF "$dir2" "$REGISTRY/$owner2" 2>/dev/null; then
  ok "stop-server.sh removes its directory from the registry"
else
  bad "stop-server.sh removes its directory from the registry" "$(cat "$REGISTRY/$owner2")"
fi

echo "--- concurrent unregister ---"
dir3="$(start_server)"
owner3="$(owner_of "$dir3")"
# A stale or concurrent stop's fixed-name temp file must not block this one.
mkdir -p "$REGISTRY/$owner3.tmp"
bash "$STOP" "$dir3" >/dev/null 2>&1
if ! grep -qxF "$dir3" "$REGISTRY/$owner3" 2>/dev/null; then
  ok "unregister does not depend on a shared temp file name"
else
  bad "unregister does not depend on a shared temp file name" "$(cat "$REGISTRY/$owner3")"
fi
rmdir "$REGISTRY/$owner3.tmp" 2>/dev/null

echo "--- nothing registered ---"
rm -rf "$REGISTRY"
if CLAUDE_PID=12345 bash "$HOOK" </dev/null >"$T/out-none" 2>&1 && [[ ! -s "$T/out-none" ]]; then
  ok "a missing registry exits 0 silently"
else
  bad "a missing registry exits 0 silently" "$(cat "$T/out-none")"
fi

if grep -q '"SessionEnd"' "$REPO_ROOT/hooks/hooks.json" && grep -q 'session-end' "$REPO_ROOT/hooks/hooks.json"; then
  ok "hooks.json runs session-end on SessionEnd"
else
  bad "hooks.json runs session-end on SessionEnd" "not registered"
fi

if node -e 'const h=require(process.argv[1]).hooks.SessionEnd[0].hooks[0]; process.exit(h.timeout===15?0:1)' "$REPO_ROOT/hooks/hooks.json"; then
  ok "the SessionEnd hook declares a 15 s timeout"
else
  bad "the SessionEnd hook declares a 15 s timeout" "$(grep -n timeout "$REPO_ROOT/hooks/hooks.json")"
fi

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ] || exit 1
