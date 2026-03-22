#!/usr/bin/env bash
set -euo pipefail

# WorkClaws worker node lifecycle manager.
# Handles enrollment, capability registration, heartbeat, assignment
# pull/execute/submit, and settlement claim against the WorkClaws platform API.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Try to locate the openclaw repo root (bundled or workspace install)
if [[ -d "$SKILL_DIR/../../src" ]]; then
  OPENCLAW_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
elif [[ -n "${OPENCLAW_ROOT:-}" ]]; then
  : # already set
else
  OPENCLAW_ROOT="$(cd "$SKILL_DIR" && pwd)"
fi
export OPENCLAW_ROOT

# --- defaults (production: yesclaw.ai; override for local dev) ---
PLATFORM_URL="${WORKCLAWS_PLATFORM_URL:-https://yesclaw.ai/api/admin/proxy}"
ENROLLMENT_TOKEN="${WORKCLAWS_ENROLLMENT_TOKEN:-}"
NODE_ID="${WORKCLAWS_NODE_ID:-}"
MAX_CONCURRENCY="${WORKCLAWS_MAX_CONCURRENCY:-2}"
REGION="${WORKCLAWS_REGION:-auto}"
TIER="${WORKCLAWS_TIER:-standard}"
HEARTBEAT_INTERVAL="${WORKCLAWS_HEARTBEAT_INTERVAL:-30}"
POLL_WAIT="${WORKCLAWS_POLL_WAIT:-20}"
# WORKCLAWS_DEBUG=1 — print HTTP / loop details to stderr
# Token refresh: transient network / 5xx on /v1/nodes/token/refresh
TOKEN_REFRESH_RETRIES="${WORKCLAWS_TOKEN_REFRESH_RETRIES:-5}"
TOKEN_REFRESH_BACKOFF="${WORKCLAWS_TOKEN_REFRESH_BACKOFF:-3}"
# Per API call: how many (refresh + replay request) cycles on repeated 401
API_401_REFRESH_ROUNDS="${WORKCLAWS_API_401_REFRESH_ROUNDS:-5}"
ACK_RETRIES="${WORKCLAWS_ACK_RETRIES:-5}"
ACK_BACKOFF="${WORKCLAWS_ACK_BACKOFF:-2}"

# Result uploads and input attachment downloads use BFF-issued OSS presigned URLs only — no OSS keys on the worker.

CRED_DIR="${HOME}/.openclaw"
CRED_FILE="${CRED_DIR}/workclaws-credentials.json"
PENDING_DIR="${HOME}/.openclaw/pending_deliveries"

# --- helpers ---

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[workclaws] $*"; }

wc_ts() { date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date; }

debug() {
  if [[ "${WORKCLAWS_DEBUG:-0}" == "1" || "${WORKCLAWS_DEBUG:-}" == "true" ]]; then
    echo "[workclaws][debug][$(wc_ts)] $*" >&2
  fi
}

# Always to stderr — short lifecycle events (throttle higher layers to avoid spam)
trace() {
  echo "[workclaws][trace][$(wc_ts)] $*" >&2
}

require_platform_url() {
  [[ -n "$PLATFORM_URL" ]] || die "WORKCLAWS_PLATFORM_URL is not set"
}

ensure_cred_dir() {
  mkdir -p "$CRED_DIR"
  chmod 700 "$CRED_DIR"
}

read_cred() {
  local key="$1"
  [[ -f "$CRED_FILE" ]] || return 1
  python3 -c "
import json, sys
c = json.load(open('$CRED_FILE'))
v = c.get('$key', '')
sys.stdout.write(str(v))
  " 2>/dev/null
}

write_cred() {
  ensure_cred_dir
  local json="$1"
  echo "$json" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

get_access_token() {
  local tok
  tok=$(read_cred access_token 2>/dev/null || true)
  if [[ -z "$tok" ]]; then
    die "No stored access token. Run 'enroll' first."
  fi
  echo "$tok"
}

get_node_id() {
  if [[ -n "$NODE_ID" ]]; then
    echo "$NODE_ID"
    return
  fi
  local stored
  stored=$(read_cred node_id 2>/dev/null || true)
  if [[ -n "$stored" ]]; then
    echo "$stored"
    return
  fi
  echo "node_oc_$(echo "${HOSTNAME:-$(hostname)}:${USER:-unknown}" | sha256sum | cut -c1-12)"
}

json_val() {
  echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print($2)" 2>/dev/null
}

# Never fail the shell under "set -e" — invalid JSON or bad expr must not kill the worker loop.
json_val_raw() {
  echo "$1" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = $2
    sys.stdout.write(str(v) if v is not None else '')
except Exception:
    pass
" 2>/dev/null || true
}

# Make an authenticated API call.  Unwraps the {success, data} envelope.
# On 401, tries to refresh the token once and retry.
api_call() {
  local method="$1" path="$2"
  shift 2
  local token trace_id
  token=$(get_access_token)
  trace_id="trc_wk_$(date +%s)_$$"

  local tmpfile http_code raw
  tmpfile=$(mktemp /tmp/wc_api.XXXXXX)
  http_code=$(curl -sS -w '%{http_code}' -o "$tmpfile" -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "X-Trace-Id: $trace_id" \
    "$@" \
    "${PLATFORM_URL}${path}") || { rm -f "$tmpfile"; return 1; }
  raw=$(cat "$tmpfile")
  rm -f "$tmpfile"

  debug "api ${method} ${path} <- HTTP ${http_code} (${#raw} byte body)"

  # On 401: repeatedly try refresh + replay until success or refresh fails / max rounds
  if [[ "$http_code" == "401" ]]; then
    local round=0
    while [[ "$http_code" == "401" && round -lt "$API_401_REFRESH_ROUNDS" ]]; do
      round=$((round + 1))
      trace "api ${method} ${path} HTTP 401 — token refresh round ${round}/${API_401_REFRESH_ROUNDS}"
      if ! try_refresh_token; then
        trace "token refresh aborted (invalid refresh token, re-enroll, or platform error)"
        break
      fi
      token=$(get_access_token)
      tmpfile=$(mktemp /tmp/wc_api.XXXXXX)
      http_code=$(curl -sS -w '%{http_code}' -o "$tmpfile" -X "$method" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "X-Trace-Id: $trace_id" \
        "$@" \
        "${PLATFORM_URL}${path}") || { rm -f "$tmpfile"; return 1; }
      raw=$(cat "$tmpfile")
      rm -f "$tmpfile"
      debug "api ${method} ${path} (after refresh, round $round) <- HTTP ${http_code} (${#raw} byte body)"
    done
  fi

  if [[ "$http_code" -ge 400 ]]; then
    trace "api ${method} ${path} FAILED http=${http_code} body=${raw:0:400}"
    echo "$raw" >&2
    return 1
  fi

  # Unwrap envelope: extract .data if present
  if ! python3 -c "
import sys, json
r = json.loads(sys.stdin.read())
if r.get('success') == False:
    sys.stderr.write('[workclaws] API error: ' + json.dumps(r.get('error', r)) + '\n')
    sys.exit(1)
d = r.get('data', r)
sys.stdout.write(json.dumps(d))
" <<< "$raw"; then
    trace "api ${method} ${path} envelope parse or success=false (see stderr above)"
    return 1
  fi
}

# Make an unauthenticated API call (for enroll, task detail without token, etc.)
api_call_noauth() {
  local method="$1" path="$2"
  shift 2
  local trace_id="trc_wk_$(date +%s)_$$"
  local tmpfile http_code raw
  tmpfile=$(mktemp /tmp/wc_api.XXXXXX)
  http_code=$(curl -sS -w '%{http_code}' -o "$tmpfile" -X "$method" \
    -H "Content-Type: application/json" \
    -H "X-Trace-Id: $trace_id" \
    "$@" \
    "${PLATFORM_URL}${path}") || { rm -f "$tmpfile"; return 1; }
  raw=$(cat "$tmpfile")
  rm -f "$tmpfile"

  debug "api_noauth ${method} ${path} <- HTTP ${http_code} (${#raw} byte body)"

  if [[ "$http_code" -ge 400 ]]; then
    trace "api_noauth ${method} ${path} FAILED http=${http_code} body=${raw:0:400}"
    echo "$raw" >&2
    return 1
  fi

  if ! python3 -c "
import sys, json
r = json.loads(sys.stdin.read())
if r.get('success') == False:
    sys.stderr.write('[workclaws] API error: ' + json.dumps(r.get('error', r)) + '\n')
    sys.exit(1)
d = r.get('data', r)
sys.stdout.write(json.dumps(d))
" <<< "$raw"; then
    trace "api_noauth ${method} ${path} envelope parse or success=false (see stderr above)"
    return 1
  fi
}

try_refresh_token() {
  local nid
  nid=$(get_node_id)

  info "Access token expired or rejected, refreshing ..."
  local tmpfile http_code raw a rt
  for ((a = 1; a <= TOKEN_REFRESH_RETRIES; a++)); do
    # Re-read on every attempt — server rotates the refresh token on each successful call
    rt=$(read_cred refresh_token 2>/dev/null || true)
    [[ -n "$rt" ]] || { trace "no refresh_token in $CRED_FILE — run enroll again"; return 1; }

    tmpfile=$(mktemp /tmp/wc_api.XXXXXX)
    if ! http_code=$(curl -sS -w '%{http_code}' -o "$tmpfile" -X POST \
      -H "Content-Type: application/json" \
      -d "{\"node_id\": \"$nid\", \"refresh_token\": \"$rt\"}" \
      "${PLATFORM_URL}/v1/nodes/token/refresh"); then
      rm -f "$tmpfile"
      info "Token refresh request failed (network?) attempt $a/$TOKEN_REFRESH_RETRIES — retry in ${TOKEN_REFRESH_BACKOFF}s"
      sleep "$TOKEN_REFRESH_BACKOFF"
      continue
    fi
    raw=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [[ "$http_code" == "200" ]]; then
      # Write new tokens atomically: write to tmp then rename to avoid partial-write corruption
      if python3 -c "
import sys, json, os, tempfile
r = json.loads(sys.stdin.read())
if not r.get('success') or not r.get('data'):
    sys.exit(1)
d = r['data']
if 'access_token' not in d or 'refresh_token' not in d:
    sys.stderr.write('refresh response missing token fields\n')
    sys.exit(1)
cred_file = '$CRED_FILE'
try:
    old = json.load(open(cred_file))
except:
    old = {}
old['access_token'] = d['access_token']
old['refresh_token'] = d['refresh_token']
old['expires_in'] = d.get('expires_in', 3600)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cred_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(old, f, indent=2)
os.replace(tmp, cred_file)
" <<< "$raw"; then
        chmod 600 "$CRED_FILE"
        info "Token refreshed"
        return 0
      fi
      # 200 but save failed — the server already rotated the token.
      # The old rt is now invalid. If save failed due to a parsing bug,
      # retrying with the same rt won't help; re-read in case a partial
      # write did land, otherwise we must give up.
      trace "token refresh: 200 received but failed to persist tokens (attempt $a/$TOKEN_REFRESH_RETRIES)"
      sleep "$TOKEN_REFRESH_BACKOFF"
      continue
    fi

    # Permanent rejection — do not spin
    if [[ "$http_code" == "401" || "$http_code" == "403" || "$http_code" == "400" ]]; then
      trace "token/refresh rejected http=$http_code body=${raw:0:400}"
      return 1
    fi

    info "Token refresh HTTP $http_code (attempt $a/$TOKEN_REFRESH_RETRIES), retry in ${TOKEN_REFRESH_BACKOFF}s"
    sleep "$TOKEN_REFRESH_BACKOFF"
  done

  trace "token refresh exhausted after $TOKEN_REFRESH_RETRIES attempts"
  return 1
}

# --- capability introspection ---

discover_capabilities() {
  python3 -c "
import os, json, pathlib

caps = {
    'core_tools': [
  'read','write','edit','apply_patch','exec','process',
  'web_search','web_fetch','memory_search','memory_get',
  'sessions_list','sessions_history','sessions_send','sessions_spawn',
  'sessions_yield','subagents','session_status',
  'browser','canvas','message','cron','gateway','nodes',
  'agents_list','image','tts'
    ],
    'skills': [],
    'models': [],
    'extensions': [],
    'channels': ['webchat'],
    'tool_profile': 'full',
    'platform': {'os': os.uname().sysname.lower(), 'arch': os.uname().machine}
}

root = os.environ.get('OPENCLAW_ROOT', os.getcwd())

skills_dir = os.path.join(root, 'skills')
if os.path.isdir(skills_dir):
    caps['skills'] = [
        d for d in sorted(os.listdir(skills_dir))
        if os.path.isfile(os.path.join(skills_dir, d, 'SKILL.md'))
    ]

ext_dir = os.path.join(root, 'extensions')
if os.path.isdir(ext_dir):
    caps['extensions'] = [
        d for d in sorted(os.listdir(ext_dir))
        if os.path.isfile(os.path.join(ext_dir, d, 'openclaw.plugin.json'))
           or os.path.isfile(os.path.join(ext_dir, d, 'package.json'))
    ]

models_json = os.path.join(os.environ.get('HOME', ''), '.openclaw', 'models.json')
if os.path.isfile(models_json):
    try:
        mc = json.load(open(models_json))
        for prov, cfg in (mc.get('providers') or {}).items():
            for m in (cfg or {}).get('models', []):
                entry = {'provider': prov, 'model_id': m.get('id') or m.get('name', '')}
                traits = []
                if m.get('reasoning'): traits.append('reasoning')
                inp = m.get('input', '')
                if isinstance(inp, str) and 'image' in inp: traits.append('vision')
                if isinstance(inp, list) and 'image' in inp: traits.append('vision')
                mid = entry['model_id'].lower()
                if 'codex' in mid or 'code' in mid: traits.append('coding')
                if traits: entry['traits'] = traits
                if m.get('contextWindow'): entry['context_window'] = m['contextWindow']
                caps['models'].append(entry)
    except:
        pass

channel_names = {'whatsapp','telegram','discord','slack','signal','imessage',
                 'googlechat','matrix','msteams','irc','line','feishu','mattermost','webchat'}
caps['channels'] = [e for e in caps['extensions'] if e in channel_names] + ['webchat']

print(json.dumps(caps, indent=2))
" 2>/dev/null
}

# --- commands ---

cmd_enroll() {
  require_platform_url
  [[ -n "$ENROLLMENT_TOKEN" ]] || die "WORKCLAWS_ENROLLMENT_TOKEN is required for enrollment"

  local nid
  nid=$(get_node_id)
  info "Enrolling node $nid with platform at $PLATFORM_URL ..."

  local resp
  resp=$(curl -sS -X POST \
    -H "X-Enrollment-Token: $ENROLLMENT_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Trace-Id: trc_enroll_$(date +%s)" \
    -d "{\"node_id\": \"$nid\"}" \
    "${PLATFORM_URL}/v1/nodes/enroll") || die "Enrollment request failed"

  ensure_cred_dir
  python3 -c "
import sys, json
r = json.loads(sys.stdin.read())
if not r.get('success') or not r.get('data'):
    sys.stderr.write('Enrollment rejected: ' + json.dumps(r) + '\n')
    sys.exit(1)
d = r['data']
out = {
    'node_id': d.get('node_id', '$nid'),
    'access_token': d['access_token'],
    'refresh_token': d['refresh_token'],
    'expires_in': d.get('expires_in', 3600),
    'token_type': d.get('token_type', 'Bearer')
}
with open('$CRED_FILE', 'w') as f:
    json.dump(out, f, indent=2)
print('Node ID:', out['node_id'])
print('Token expires in:', out['expires_in'], 'seconds')
" <<< "$resp" || die "Could not parse enrollment response"
  chmod 600 "$CRED_FILE"
  info "Enrolled successfully. Credentials stored in $CRED_FILE"
}

cmd_register() {
  require_platform_url

  local nid
  nid=$(get_node_id)
  local owner_id="${USER:-unknown}"

  info "Discovering capabilities ..."
  local caps
  caps=$(discover_capabilities)

  local n_skills n_models n_extensions
  n_skills=$(echo "$caps" | python3 -c "import sys,json; c=json.load(sys.stdin); print(len(c.get('skills',[])))")
  n_models=$(echo "$caps" | python3 -c "import sys,json; c=json.load(sys.stdin); print(len(c.get('models',[])))")
  n_extensions=$(echo "$caps" | python3 -c "import sys,json; c=json.load(sys.stdin); print(len(c.get('extensions',[])))")
  info "Registering node $nid with $n_skills skills, $n_models models, $n_extensions extensions ..."

  local body
  body=$(python3 -c "
import sys, json
caps = json.loads(sys.argv[1])
body = {
    'node_id': sys.argv[2],
    'owner_id': sys.argv[3],
    'capabilities': caps,
    'max_concurrency': int(sys.argv[4]),
    'labels': {'region': sys.argv[5], 'tier': sys.argv[6]}
}
sys.stdout.write(json.dumps(body))
  " "$caps" "$nid" "$owner_id" "$MAX_CONCURRENCY" "$REGION" "$TIER")

  local resp
  if ! resp=$(api_call POST /v1/nodes/register -d "$body"); then
    info "Registration failed (access token invalid/expired and refresh not possible — run enroll again if this persists)"
    return 1
  fi
  info "Registered successfully"
  echo "$resp"
}

cmd_heartbeat() {
  require_platform_url
  local nid
  nid=$(get_node_id)

  api_call POST /v1/nodes/heartbeat -d "{
    \"node_id\": \"$nid\",
    \"status\": \"ready\",
    \"health_score\": 95,
    \"current_load\": 0,
    \"max_concurrency\": $MAX_CONCURRENCY
  }"
}

cmd_pull() {
  require_platform_url
  local nid
  nid=$(get_node_id)
  debug "pull assignments node_id=${nid} GET ${PLATFORM_URL}/v1/assignments/pull?node_id=${nid}"
  api_call GET "/v1/assignments/pull?node_id=${nid}"
}

cmd_ack() {
  require_platform_url
  local assignment_id="$1"
  local nid
  nid=$(get_node_id)
  local idem_key="idem_ack_${assignment_id}_$(date +%s)"

  api_call POST "/v1/assignments/${assignment_id}/ack" \
    -H "X-Idempotency-Key: $idem_key" \
    -d "{\"node_id\": \"$nid\", \"accepted\": true}"
}

# ACK must succeed before we run the task; otherwise the same assignment stays issuable and the next pull spawns duplicates.
# One idempotency key for all attempts in this burst (safe retries).
ack_assignment_or_give_up() {
  local asg_id="$1" nid idem_key
  require_platform_url
  nid=$(get_node_id)
  idem_key="idem_ack_${asg_id}_$$"
  local a
  for ((a = 1; a <= ACK_RETRIES; a++)); do
    if api_call POST "/v1/assignments/${asg_id}/ack" \
      -H "X-Idempotency-Key: $idem_key" \
      -d "{\"node_id\": \"$nid\", \"accepted\": true}" >/dev/null 2>&1; then
      return 0
    fi
    trace "ACK $asg_id failed attempt $a/$ACK_RETRIES, retry in ${ACK_BACKOFF}s"
    sleep "$ACK_BACKOFF"
  done
  return 1
}

cmd_submit_receipt() {
  require_platform_url
  local assignment_id="$1" task_id="$2" outcome="$3" result_ref="${4:-}"
  local quality_score="${5:-0}"
  local error_code="${6:-}"
  local nid
  nid=$(get_node_id)
  local receipt_id="rcp_$(date +%s)_$$"
  local idem_key="idem_${receipt_id}_v1"

  local error_json="null"
  if [[ -n "$error_code" && "$error_code" != "null" ]]; then
    error_json="\"$error_code\""
  fi

  local result_json="null"
  if [[ -n "$result_ref" ]]; then
    result_json="\"$result_ref\""
  fi

  api_call POST /v1/receipts \
    -H "X-Idempotency-Key: $idem_key" \
    -d "{
      \"receipt_id\": \"$receipt_id\",
      \"assignment_id\": \"$assignment_id\",
      \"task_id\": \"$task_id\",
      \"node_id\": \"$nid\",
      \"idempotency_key\": \"$idem_key\",
      \"outcome\": \"$outcome\",
      \"quality_score\": $quality_score,
      \"result_ref\": $result_json,
      \"error_code\": $error_json
    }"
}

cmd_settlements() {
  require_platform_url
  local nid
  nid=$(get_node_id)
  api_call GET "/v1/settlements?node_id=${nid}&status=approved&limit=50"
}

cmd_claim() {
  require_platform_url
  local settlement_id="$1"
  local nid
  nid=$(get_node_id)
  local claim_ref="claim_$(date +%Y%m%d)_$$"

  api_call POST "/v1/settlements/${settlement_id}/claim" \
    -d "{
      \"node_id\": \"$nid\",
      \"claim_channel\": \"wallet_internal\",
      \"claim_ref\": \"$claim_ref\"
    }"
}

cmd_status() {
  require_platform_url
  local nid
  nid=$(get_node_id)
  info "Node:        $nid"
  info "Platform:    $PLATFORM_URL"
  info "Credentials: $([ -f "$CRED_FILE" ] && echo 'stored' || echo 'not found')"

  info ""
  info "Capabilities snapshot:"
  discover_capabilities | python3 -c "
import sys, json
c = json.load(sys.stdin)
sl = c.get('skills', [])
print('  Skills:     ', len(sl), '(' + ', '.join(sl[:5]) + (', ...' if len(sl) > 5 else '') + ')')
print('  Models:     ', len(c.get('models', [])))
print('  Extensions: ', len(c.get('extensions', [])))
print('  Core Tools: ', len(c.get('core_tools', [])))
ch = c.get('channels', [])
print('  Channels:   ', len(ch), '(' + ', '.join(ch) + ')')
print('  Platform:   ', c.get('platform', {}).get('os', '?') + '/' + c.get('platform', {}).get('arch', '?'))
"
}

cmd_check_cancel() {
  local task_id="$1"
  local resp
  resp=$(api_call GET "/v1/tasks/${task_id}/state" 2>/dev/null) || return 1
  local state
  state=$(json_val_raw "$resp" "d.get('state', d.get('data',{}).get('state',''))")
  [[ "$state" == "cancelled" ]]
}

fetch_task_detail() {
  local task_id="$1"
  api_call GET "/v1/tasks/${task_id}"
}

# Zip a directory (single top-level folder inside the archive). Returns 0 if zip created.
make_delivery_zip() {
  local src_dir="$1"
  local zip_path="$2"
  rm -f "$zip_path"
  [[ -d "$src_dir" ]] || return 1
  local base parent
  base=$(basename "$src_dir")
  parent=$(dirname "$src_dir")
  if command -v zip &>/dev/null; then
    (cd "$parent" && zip -rq "$zip_path" "$base") && [[ -s "$zip_path" ]] && return 0
  fi
  python3 -c "
import sys, os, zipfile
src, zpath = sys.argv[1], sys.argv[2]
src = os.path.abspath(src)
if not os.path.isdir(src):
    sys.exit(1)
parent = os.path.dirname(src)
with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as zf:
    for dirpath, _, filenames in os.walk(src):
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            arc = os.path.relpath(fp, parent)
            zf.write(fp, arc)
" "$src_dir" "$zip_path" && [[ -s "$zip_path" ]]
}

# Upload result zip via BFF presigned PUT (same idea as portal attachment upload).
# POST /api/worker/task/:taskId/result-upload-url → PUT bytes to OSS. Prints object_key on success.
upload_result() {
  local zip_path="$1" task_id="$2"
  local token ct bff_url filesize tmp raw http_code upload_url object_key put_body put_code put_err

  ct="application/zip"
  filesize=$(stat -c%s "$zip_path" 2>/dev/null || stat -f%z "$zip_path" 2>/dev/null || echo "0")
  if [[ "${filesize:-0}" -le 0 ]]; then
    trace "upload_result: missing or empty zip: $zip_path"
    return 1
  fi

  token=$(get_access_token)
  bff_url="${WORKCLAWS_PORTAL_URL:-https://yesclaw.ai}/api/worker/task/${task_id}/result-upload-url"
  debug "upload_result presign task_id=${task_id} size=${filesize} url=${bff_url}"

  tmp=$(mktemp /tmp/wc_ru_presign.XXXXXX)
  if ! http_code=$(curl -sS -w '%{http_code}' -o "$tmp" -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"file_size\":${filesize},\"content_type\":\"${ct}\"}" \
    "$bff_url"); then
    rm -f "$tmp"
    return 1
  fi
  raw=$(cat "$tmp")
  rm -f "$tmp"

  if [[ "$http_code" -ge 400 ]]; then
    trace "result-upload-url HTTP $http_code body=${raw:0:500}"
    return 1
  fi

  if ! upload_url=$(printf '%s' "$raw" | python3 -c "
import sys, json
r = json.loads(sys.stdin.read())
d = r.get('data') or {}
u = d.get('upload_url', '')
if not r.get('success') or not u:
    sys.stderr.write('[workclaws] result-upload-url unexpected: ' + json.dumps(r)[:500] + '\n')
    sys.exit(1)
sys.stdout.write(u)
"); then
    return 1
  fi
  if ! object_key=$(printf '%s' "$raw" | python3 -c "
import sys, json
r = json.loads(sys.stdin.read())
d = r.get('data') or {}
k = d.get('object_key', '')
if not k:
    sys.exit(1)
sys.stdout.write(k)
"); then
    return 1
  fi

  put_body=$(mktemp /tmp/wc_ru_put_out.XXXXXX)
  put_err=$(mktemp /tmp/wc_ru_put_err.XXXXXX)
  if ! put_code=$(curl -sS -w '%{http_code}' -o "$put_body" -X PUT \
    -H "Content-Type: ${ct}" \
    --data-binary "@${zip_path}" \
    "$upload_url" 2>"$put_err"); then
    trace "upload_result PUT curl failed: $(cat "$put_err")"
    rm -f "$put_body" "$put_err"
    return 1
  fi
  if [[ -s "$put_err" ]]; then
    trace "upload_result PUT stderr: $(cat "$put_err")"
  fi
  rm -f "$put_err"

  if [[ "$put_code" -lt 200 || "$put_code" -ge 300 ]]; then
    trace "upload_result PUT HTTP $put_code body=$(head -c 400 "$put_body" 2>/dev/null || true)"
    rm -f "$put_body"
    return 1
  fi
  rm -f "$put_body"

  debug "upload_result OK object_key=${object_key}"
  echo "$object_key"
}

# Fetch presigned attachment download URLs from BFF.
# Requires a valid node access token. Prints JSON array to stdout.
# GET /api/worker/task/{task_id}/attachment-urls
fetch_attachment_urls() {
  local task_id="$1"
  local bff_url="${WORKCLAWS_PORTAL_URL:-https://yesclaw.ai}/api/worker/task/${task_id}/attachment-urls"
  local token
  token=$(get_access_token)
  debug "fetch_attachment_urls task_id=${task_id} url=${bff_url}"
  local tmpfile http_code raw
  tmpfile=$(mktemp /tmp/wc_att_urls.XXXXXX)
  http_code=$(curl -sS -w '%{http_code}' -o "$tmpfile" -X GET \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "$bff_url") || { rm -f "$tmpfile"; return 1; }
  raw=$(cat "$tmpfile")
  rm -f "$tmpfile"
  if [[ "$http_code" -ge 400 ]]; then
    trace "fetch_attachment_urls HTTP $http_code body=${raw:0:500}"
    return 1
  fi
  python3 -c "
import sys, json
r = json.loads(sys.stdin.read())
if r.get('success') and r.get('data'):
    sys.stdout.write(json.dumps(r['data'].get('attachments', [])))
else:
    sys.stderr.write('[workclaws] attachment-urls unexpected: ' + json.dumps(r)[:400] + '\n')
    sys.exit(1)
" <<< "$raw"
}

# --- session reporting ---

# Report a status message to the worker's persistent openclaw session.
REPORT_SESSION="${WORKCLAWS_REPORT_SESSION:-}"

report() {
  local msg="$1"
  if [[ -z "$REPORT_SESSION" ]] || ! command -v openclaw &>/dev/null; then
    return 0
  fi
  openclaw agent \
    --session-id "$REPORT_SESSION" \
    --message "[workclaws-worker] $msg" \
    --timeout 30 >/dev/null 2>&1 || true
}

# Report progress (0-100) to the platform for an assignment.
report_progress() {
  local asg_id="$1" pct="$2" msg="${3:-}"
  local msg_json="null"
  [[ -n "$msg" ]] && msg_json="\"$msg\""
  api_call POST "/v1/assignments/${asg_id}/progress" \
    -d "{\"progress\": $pct, \"message\": $msg_json}" >/dev/null 2>&1 || true
}

# --- pending delivery management ---

save_pending_delivery() {
  local asg_id="$1" task_id="$2" output_root="$3" title="$4" reward="$5" quality="${6:-90}"
  mkdir -p "$PENDING_DIR"
  python3 -c "
import json, sys, time
rec = {
    'assignment_id': sys.argv[1],
    'task_id': sys.argv[2],
    'output_root': sys.argv[3],
    'title': sys.argv[4],
    'reward': sys.argv[5],
    'quality_score': int(sys.argv[6]),
    'created_at': int(time.time()),
    'attempts': 0
}
path = sys.argv[7] + '/' + sys.argv[2] + '.json'
with open(path, 'w') as f:
    json.dump(rec, f, indent=2)
" "$asg_id" "$task_id" "$output_root" "$title" "$reward" "$quality" "$PENDING_DIR"
  info "Pending delivery saved: $PENDING_DIR/${task_id}.json"
}

retry_one_delivery() {
  local record_file="$1"
  local rec asg_id task_id output_root quality_score attempts
  rec=$(cat "$record_file")
  task_id=$(json_val_raw "$rec" "d['task_id']")
  asg_id=$(json_val_raw "$rec" "d['assignment_id']")
  output_root=$(json_val_raw "$rec" "d['output_root']")
  quality_score=$(json_val_raw "$rec" "d.get('quality_score', 90)")
  attempts=$(json_val_raw "$rec" "d.get('attempts', 0)")
  attempts=${attempts:-0}

  if [[ ! -d "$output_root" ]]; then
    info "Pending $task_id: output dir $output_root gone — dropping record"
    rm -f "$record_file"
    return 0
  fi

  local nfiles bundle_zip uploaded_url result_ref=""
  nfiles=$(find "$output_root" -type f 2>/dev/null | wc -l)
  nfiles=${nfiles// /}
  if [[ "${nfiles:-0}" -eq 0 ]]; then
    info "Pending $task_id: output dir empty — dropping record"
    rm -f "$record_file"
    return 0
  fi

  bundle_zip="/tmp/workclaws_bundle_${task_id}.zip"
  rm -f "$bundle_zip"
  if ! make_delivery_zip "$output_root" "$bundle_zip"; then
    info "Pending $task_id: zip failed (attempt $((attempts+1))) — will retry later"
    python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d['attempts'] = d.get('attempts',0) + 1
json.dump(d, open(f,'w'), indent=2)
" "$record_file"
    return 1
  fi

  uploaded_url=$(upload_result "$bundle_zip" "$task_id" || true)
  rm -f "$bundle_zip"
  if [[ -z "$uploaded_url" ]]; then
    info "Pending $task_id: upload failed (attempt $((attempts+1))) — will retry later"
    python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d['attempts'] = d.get('attempts',0) + 1
json.dump(d, open(f,'w'), indent=2)
" "$record_file"
    return 1
  fi

  result_ref="$uploaded_url"
  info "Pending $task_id: uploaded → $result_ref — submitting success receipt"
  if cmd_submit_receipt "$asg_id" "$task_id" "success" "$result_ref" "$quality_score" "" >/dev/null 2>&1; then
    info "Pending $task_id: receipt submitted — delivery complete"
    report "✅ 延迟交付完成: $task_id → $result_ref"
    rm -f "$record_file"
    rm -rf "$output_root"
  else
    info "Pending $task_id: receipt submission failed — will retry"
    python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d['attempts'] = d.get('attempts',0) + 1
d['result_ref'] = sys.argv[2]
json.dump(d, open(f,'w'), indent=2)
" "$record_file" "$result_ref"
    return 1
  fi
}

retry_pending_deliveries() {
  [[ -d "$PENDING_DIR" ]] || return 0
  local count=0 ok=0
  for f in "$PENDING_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    count=$((count + 1))
    retry_one_delivery "$f" && ok=$((ok + 1))
  done
  if (( count > 0 )); then
    info "Pending deliveries: $ok/$count succeeded"
  fi
}

cmd_retry_deliveries() {
  info "Retrying all pending deliveries in $PENDING_DIR ..."
  retry_pending_deliveries
}

# --- main execution logic ---

execute_task() {
  local asg_id="$1" task_id="$2"
  debug "execute_task begin assignment_id=${asg_id} task_id=${task_id}"
  info "Executing task $task_id ..."

  local cancel_flag="/tmp/workclaws_cancel_${task_id}"
  rm -f "$cancel_flag"

  # Background cancel-check loop
  (
    while true; do
      sleep 5
      if cmd_check_cancel "$task_id" 2>/dev/null; then
        touch "$cancel_flag"
        info "Task $task_id cancelled by user — signalling abort"
        break
      fi
      [[ -f "$cancel_flag" ]] && break
    done
  ) &
  local cancel_checker_pid=$!

  local outcome="success"
  local quality_score=85
  local error_code=""
  local result_ref=""

  report_progress "$asg_id" 5 "Fetching task detail"

  # 1) Fetch task detail (prompt + attachments)
  local task_detail task_prompt task_title task_attachments task_reward
  task_detail=$(fetch_task_detail "$task_id" 2>/dev/null || echo "{}")
  task_prompt=$(json_val_raw "$task_detail" "d.get('prompt','')")
  task_title=$(json_val_raw "$task_detail" "d.get('title','')")
  task_reward=$(json_val_raw "$task_detail" "d.get('reward','0')")
  task_attachments=$(json_val_raw "$task_detail" "json.dumps(d.get('attachments') or [])")

  if [[ -z "$task_prompt" || "$task_prompt" == "None" ]]; then
    info "Task $task_id: no prompt found, submitting failure"
    report "❌ 任务 $task_id 无法执行：缺少 prompt"
    outcome="failure"
    quality_score=0
    error_code="NO_TASK_PROMPT"
  else
    info "Task $task_id: title='$task_title', reward=$task_reward"
    report "🦞 接到任务: $task_title ($task_id, 报酬 $task_reward) — 开始执行"

    local output_root="${WORKCLAWS_OUTPUT_DIR:-/tmp}/workclaws_output_${task_id}"
    rm -rf "$output_root"
    mkdir -p "$output_root"

    # 2) Download attachments via BFF presigned URLs
    local attachment_dir="/tmp/workclaws_attachments_${task_id}"
    local attachment_info=""
    if [[ -n "$task_attachments" && "$task_attachments" != "[]" && "$task_attachments" != "null" && "$task_attachments" != "None" ]]; then
      mkdir -p "$attachment_dir"
      local att_urls_json
      att_urls_json=$(fetch_attachment_urls "$task_id" 2>/tmp/wc_att_err_${task_id} || echo "[]")
      [[ -s "/tmp/wc_att_err_${task_id}" ]] && trace "fetch_attachment_urls errors: $(cat /tmp/wc_att_err_${task_id})"
      rm -f "/tmp/wc_att_err_${task_id}"
      attachment_info=$(python3 -c "
import sys, json, os, urllib.request
att_urls = json.loads(sys.argv[1])
out_dir = sys.argv[2]
downloaded = []
for att in att_urls:
    name = att.get('name', '')
    dl_url = att.get('download_url', '')
    if not name:
        name = os.path.basename(att.get('object_key', '')) or 'attachment'
    if not dl_url:
        sys.stderr.write(f'No download_url for {name}, skipping\n')
        continue
    dest = os.path.join(out_dir, name)
    try:
        urllib.request.urlretrieve(dl_url, dest)
        downloaded.append(dest)
    except Exception as e:
        sys.stderr.write(f'Download failed for {name}: {e}\n')
print('\n'.join(downloaded))
" "$att_urls_json" "$attachment_dir" 2>/tmp/wc_att_dl_err_${task_id} || true)
      [[ -s "/tmp/wc_att_dl_err_${task_id}" ]] && trace "attachment download errors: $(cat /tmp/wc_att_dl_err_${task_id})"
      rm -f "/tmp/wc_att_dl_err_${task_id}"
      if [[ -n "$attachment_info" ]]; then
        local att_count
        att_count=$(echo "$attachment_info" | wc -l)
        info "Task $task_id: downloaded $att_count attachment(s)"
        report "📎 下载了 $att_count 个附件"
      fi
    fi

    report_progress "$asg_id" 20 "Preparing agent prompt"

    # 3) Build the agent message: task context + prompt + attachment paths
    local agent_message
    agent_message=$(python3 -c "
import sys
title = sys.argv[1]
prompt = sys.argv[2]
task_id = sys.argv[3]
reward = sys.argv[4]
att_paths = sys.argv[5] if len(sys.argv) > 5 else ''
out_dir = sys.argv[6] if len(sys.argv) > 6 else ''

parts = []
parts.append('你正在为 WorkClaws 平台执行一个任务。')
parts.append(f'任务ID: {task_id}')
parts.append(f'标题: {title}')
parts.append(f'报酬: {reward}')
parts.append('')
parts.append('用户需求:')
parts.append(prompt)

if att_paths.strip():
    parts.append('')
    parts.append('附件已下载到以下路径（如需要请读取）:')
    for p in att_paths.strip().split('\n'):
        if p.strip():
            parts.append(f'  {p.strip()}')

parts.append('')
parts.append('【交付要求】请将本次任务产生的所有可交付文件（图片 PNG/JPG/WebP/SVG、PDF、文档、音视频、代码等）保存到下面这个目录。')
parts.append('可使用子目录整理；最终交付物必须落在该路径下，不要仅在对答里描述而不写入文件。')
parts.append(out_dir)

print('\n'.join(parts))
" "$task_title" "$task_prompt" "$task_id" "$task_reward" "$attachment_info" "$output_root")

    # 4) Route to openclaw agent with a dedicated session per task
    local session_id="workclaws-${task_id}"
    local agent_timeout="${WORKCLAWS_AGENT_TIMEOUT:-300}"

    if command -v openclaw &>/dev/null; then
      report_progress "$asg_id" 30 "Executing via openclaw agent"
      info "Task $task_id: routing to openclaw agent (session=$session_id, timeout=${agent_timeout}s)"

      local result_file="/tmp/workclaws_result_${task_id}.json"
      openclaw agent \
        --session-id "$session_id" \
        --message "$agent_message" \
        --timeout "$agent_timeout" \
        --json > "$result_file" 2>/dev/null &
      local agent_pid=$!

      # Wait for agent completion or cancellation
      while kill -0 "$agent_pid" 2>/dev/null; do
        if [[ -f "$cancel_flag" ]]; then
          kill "$agent_pid" 2>/dev/null || true
          wait "$agent_pid" 2>/dev/null || true
          outcome="failure"
          quality_score=0
          error_code="TASK_CANCELLED_BY_USER"
          info "Task $task_id: agent killed due to cancellation"
          report "⏹️ 任务 $task_id 被用户取消"
          break
        fi
        sleep 2
      done

      if [[ -z "$error_code" ]]; then
        if wait "$agent_pid" 2>/dev/null; then
          outcome="success"
          quality_score=90
          info "Task $task_id: agent completed successfully"
        else
          outcome="failure"
          quality_score=0
          error_code="AGENT_EXECUTION_FAILED"
          info "Task $task_id: agent exited with error"
        fi
      fi

      report_progress "$asg_id" 80 "Packaging deliverables"

      # 5) Zip deliverable directory and upload — delivery must reach the user
      local delivery_pending=0
      if [[ "$outcome" == "success" ]]; then
        local nfiles bundle_zip uploaded_url upload_attempts=0 upload_max=3
        nfiles=$(find "$output_root" -type f 2>/dev/null | wc -l)
        nfiles=${nfiles// /}
        bundle_zip="/tmp/workclaws_bundle_${task_id}.zip"
        rm -f "$bundle_zip"
        if [[ "${nfiles:-0}" -gt 0 ]]; then
          if make_delivery_zip "$output_root" "$bundle_zip"; then
            while (( upload_attempts < upload_max )); do
              upload_attempts=$((upload_attempts + 1))
            uploaded_url=$(upload_result "$bundle_zip" "$task_id" || true)
            if [[ -n "$uploaded_url" ]]; then
              result_ref="$uploaded_url"
              info "Task $task_id: deliverables uploaded ($nfiles file(s)) → $result_ref"
              report "📦 已上传交付物压缩包 ($nfiles 个文件)"
              break
            fi
            info "Task $task_id: upload attempt $upload_attempts/$upload_max failed (see trace above), retrying in 5s ..."
              sleep 5
            done
          fi
          rm -f "$bundle_zip"
          if [[ -z "$result_ref" ]]; then
            delivery_pending=1
            info "Task $task_id: delivery failed (files exist in $output_root) — will NOT submit failure; queuing for retry"
            report "⚠️ 任务 $task_id 结果已生成但上传失败，排队等待重试"
            save_pending_delivery "$asg_id" "$task_id" "$output_root" "$task_title" "$task_reward" "$quality_score"
          fi
        else
          outcome="failure"
          quality_score=0
          error_code="NO_DELIVERABLES"
          info "Task $task_id: agent produced no files in $output_root — marking as failure"
          report "❌ 任务 $task_id 未产出任何交付文件"
        fi
      fi
      rm -f "$result_file"
    else
      info "Task $task_id: openclaw not available, submitting failure"
      outcome="failure"
      quality_score=0
      error_code="OPENCLAW_NOT_AVAILABLE"
    fi

    rm -rf "$attachment_dir"
    if (( delivery_pending == 0 )); then
      rm -rf "$output_root"
    fi
  fi

  # Stop the cancel-checker
  kill "$cancel_checker_pid" 2>/dev/null || true
  wait "$cancel_checker_pid" 2>/dev/null || true
  rm -f "$cancel_flag"

  # 6) Submit receipt — skip if delivery is pending (will retry later)
  if (( delivery_pending == 1 )); then
    info "Task $task_id: receipt deferred — pending delivery retry"
  else
    report_progress "$asg_id" 95 "Submitting receipt"
    info "Task $task_id: submitting receipt ($outcome)"
    cmd_submit_receipt "$asg_id" "$task_id" "$outcome" "$result_ref" "$quality_score" "$error_code" \
      >/dev/null 2>&1 && info "Receipt submitted for $task_id" || info "Receipt submission failed for $task_id"

    if [[ "$outcome" == "success" ]]; then
      report "✅ 任务完成: $task_title ($task_id) — 报酬 $task_reward"
    elif [[ "$error_code" != "TASK_CANCELLED_BY_USER" ]]; then
      report "❌ 任务失败: $task_title ($task_id) — 错误: $error_code"
    fi
  fi
}

cmd_start() {
  require_platform_url
  local nid
  nid=$(get_node_id)

  info "Starting worker loop for node $nid ..."
  info "  Platform:        $PLATFORM_URL"
  info "  Max concurrency: $MAX_CONCURRENCY"
  info "  Heartbeat:       every ${HEARTBEAT_INTERVAL}s"
  info "  Poll wait:       ${POLL_WAIT}s"
  info "  Report session:  ${REPORT_SESSION:-<none>}"

  local register_ok=0
  cmd_register && register_ok=1 || info "Registration failed (will retry on each heartbeat until OK)"
  report "🦞 Worker 启动: node=$nid, 并发=$MAX_CONCURRENCY, 等待接单..."

  local active_file="/tmp/workclaws_active_${nid}"
  local lock_file="/tmp/workclaws_lock_${nid}"
  echo "0" > "$active_file"
  touch "$lock_file"

  # Atomic read/modify of the active count using flock
  _active_read() { flock -s "$lock_file" cat "$active_file" 2>/dev/null || echo "0"; }
  _active_inc()  { flock "$lock_file" bash -c "n=\$(cat '$active_file' 2>/dev/null||echo 0); echo \$((n+1)) > '$active_file'"; }
  _active_dec()  { flock "$lock_file" bash -c "n=\$(cat '$active_file' 2>/dev/null||echo 1); echo \$((n>0?n-1:0)) > '$active_file'"; }

  local last_heartbeat=0
  local last_empty_pull_log=0

  while true; do
    local now active_count
    now=$(date +%s)
    active_count=$(_active_read)
    active_count=${active_count//[^0-9]/}
    [[ -n "$active_count" ]] || active_count=0

    if (( now - last_heartbeat >= HEARTBEAT_INTERVAL )); then
      local hb_status="ready"
      (( active_count >= MAX_CONCURRENCY )) && hb_status="busy"
      api_call POST /v1/nodes/heartbeat -d "{
        \"node_id\": \"$nid\",
        \"status\": \"$hb_status\",
        \"health_score\": 95,
        \"current_load\": $active_count,
        \"max_concurrency\": $MAX_CONCURRENCY
      }" >/dev/null 2>&1 && info "Heartbeat OK (load=$active_count)" || info "Heartbeat failed (will retry)"
      if (( register_ok == 0 )); then
        cmd_register && register_ok=1 && info "Registration succeeded after retry"
      fi
      retry_pending_deliveries
      last_heartbeat=$now
    fi

    if (( active_count < MAX_CONCURRENCY )); then
      local pull_result pull_err pull_ok=1
      pull_err=$(mktemp /tmp/wc_pull_err.XXXXXX)
      if pull_result=$(cmd_pull 2>"$pull_err"); then
        debug "pull success body_len=${#pull_result}"
        rm -f "$pull_err"
      else
        pull_ok=0
        trace "pull failed node=${nid} stderr=$(head -c 500 "$pull_err" | tr '\n' ' ')"
        rm -f "$pull_err"
        info "Assignment pull failed (treating as empty). Node: $nid — check credentials (enroll), WORKCLAWS_PLATFORM_URL, and platform logs. Set WORKCLAWS_DEBUG=1 for HTTP details."
        pull_result='{"assignments":[]}'
      fi

      local has_assignments asg_id task_id
      has_assignments=$(json_val_raw "$pull_result" "len(d.get('assignments',[]))>0")

      if [[ "$has_assignments" == "True" ]]; then
        asg_id=$(json_val_raw "$pull_result" "d['assignments'][0]['assignment_id']")
        task_id=$(json_val_raw "$pull_result" "d['assignments'][0]['task_id']")

        info "Assignment received: $asg_id (task: $task_id)"
        if ack_assignment_or_give_up "$asg_id"; then
          info "ACK OK — starting task $task_id"
          _active_inc
          (
            execute_task "$asg_id" "$task_id"
            _active_dec
          ) &
        else
          info "ACK failed after $ACK_RETRIES attempts for $asg_id — not executing (avoids duplicate workers); will retry on next pull"
        fi
      elif (( pull_ok == 1 && now - last_empty_pull_log >= 30 )); then
        info "Pull OK, queue empty (assignments=0, node=$nid). If you expected a task: confirm it is issued for this node_id, routing/skills match, and the worker is registered."
        last_empty_pull_log=$now
      fi
    fi

    sleep 2
  done
}

# --- main ---

cmd="${1:-help}"
shift || true

case "$cmd" in
  enroll)      cmd_enroll ;;
  register)    cmd_register || die "Registration failed" ;;
  heartbeat)   cmd_heartbeat ;;
  pull)        cmd_pull ;;
  ack)         cmd_ack "$@" ;;
  submit)      cmd_submit_receipt "$@" ;;
  settlements) cmd_settlements ;;
  claim)       cmd_claim "$@" ;;
  status)      cmd_status ;;
  start)       cmd_start ;;
  cancel-check) cmd_check_cancel "$@" && echo "cancelled" || echo "active" ;;
  retry-deliveries) cmd_retry_deliveries ;;
  capabilities) discover_capabilities ;;
  *)
    echo "Usage: workclaws-worker.sh <command>"
    echo ""
    echo "Commands:"
    echo "  enroll        Bootstrap enrollment (first time, needs WORKCLAWS_ENROLLMENT_TOKEN)"
    echo "  register      Register node capabilities with the platform"
    echo "  start         Start the worker loop (heartbeat + pull + execute)"
    echo "  status        Show node status and capability snapshot"
    echo "  capabilities  Dump discovered capabilities as JSON"
    echo "  heartbeat     Send a single heartbeat"
    echo "  pull          Pull one assignment"
    echo "  ack <id>      ACK an assignment"
    echo "  submit <assignment_id> <task_id> <outcome> [result_ref] [quality_score] [error_code]"
    echo "  cancel-check <task_id>  Check if a task has been cancelled"
    echo "  retry-deliveries        Retry uploading & submitting pending deliveries"
    echo "  settlements   List approved settlements"
    echo "  claim <id>    Claim a settlement"
    echo ""
    echo "Debug: set WORKCLAWS_DEBUG=1 for HTTP status/body sizes on stderr ([workclaws][debug])."
    echo "If pull always shows empty: verify assignment is issued for this node's id, not stuck in routed, and Bearer token is valid (re-enroll if needed)."
    exit 1
    ;;
esac
