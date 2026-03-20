#!/usr/bin/env bash
set -euo pipefail

# WorkClaws worker node lifecycle manager.
# Handles enrollment, capability registration, heartbeat, assignment
# pull/execute/submit, and settlement claim against the WorkClaws platform API.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# --- defaults ---
PLATFORM_URL="${WORKCLAWS_PLATFORM_URL:-}"
ENROLLMENT_TOKEN="${WORKCLAWS_ENROLLMENT_TOKEN:-}"
NODE_ID="${WORKCLAWS_NODE_ID:-}"
MAX_CONCURRENCY="${WORKCLAWS_MAX_CONCURRENCY:-2}"
REGION="${WORKCLAWS_REGION:-auto}"
TIER="${WORKCLAWS_TIER:-standard}"
HEARTBEAT_INTERVAL="${WORKCLAWS_HEARTBEAT_INTERVAL:-30}"
POLL_WAIT="${WORKCLAWS_POLL_WAIT:-20}"

CRED_DIR="${HOME}/.openclaw"
CRED_FILE="${CRED_DIR}/workclaws-credentials.json"

# --- helpers ---

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[workclaws] $*"; }

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
  node -e "
    const c = JSON.parse(require('fs').readFileSync('$CRED_FILE','utf8'));
    process.stdout.write(String(c['$key'] || ''));
  " 2>/dev/null
}

write_cred() {
  ensure_cred_dir
  local json="$1"
  echo "$json" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

get_access_token() {
  read_cred access_token || die "No stored access token. Run 'enroll' first."
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
  # generate deterministic node ID from hostname + user
  echo "node_oc_$(echo "${HOSTNAME:-$(hostname)}:${USER:-unknown}" | shasum -a 256 | cut -c1-12)"
}

api_call() {
  local method="$1" path="$2"
  shift 2
  local token
  token=$(get_access_token)
  local trace_id="trc_$(date +%s)_$$"
  curl -sf -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "X-Trace-Id: $trace_id" \
    "$@" \
    "${PLATFORM_URL}${path}"
}

# --- capability introspection ---

discover_capabilities() {
  node -e "
const fs = require('fs');
const path = require('path');

const caps = {
  core_tools: [],
  skills: [],
  models: [],
  extensions: [],
  channels: [],
  tool_profile: 'full',
  platform: { os: process.platform, arch: process.arch }
};

// Detect installed skills
const skillsDir = path.resolve('skills');
if (fs.existsSync(skillsDir)) {
  caps.skills = fs.readdirSync(skillsDir)
    .filter(d => {
      const p = path.join(skillsDir, d, 'SKILL.md');
      return fs.existsSync(p);
    });
}

// Detect extensions
const extDir = path.resolve('extensions');
if (fs.existsSync(extDir)) {
  caps.extensions = fs.readdirSync(extDir)
    .filter(d => {
      const manifest = path.join(extDir, d, 'openclaw.plugin.json');
      const pkg = path.join(extDir, d, 'package.json');
      return fs.existsSync(manifest) || fs.existsSync(pkg);
    });
}

// Core tools (known from OpenClaw tool catalog)
const knownTools = [
  'read','write','edit','apply_patch','exec','process',
  'web_search','web_fetch','memory_search','memory_get',
  'sessions_list','sessions_history','sessions_send','sessions_spawn',
  'sessions_yield','subagents','session_status',
  'browser','canvas','message','cron','gateway','nodes',
  'agents_list','image','tts'
];
caps.core_tools = knownTools;

// Detect models from models.json if present
const modelsJson = path.join(process.env.HOME || '', '.openclaw', 'models.json');
if (fs.existsSync(modelsJson)) {
  try {
    const mc = JSON.parse(fs.readFileSync(modelsJson, 'utf8'));
    if (mc.providers) {
      for (const [provider, cfg] of Object.entries(mc.providers)) {
        if (cfg && cfg.models && Array.isArray(cfg.models)) {
          for (const m of cfg.models) {
            const entry = { provider, model_id: m.id || m.name || '' };
            const traits = [];
            if (m.reasoning) traits.push('reasoning');
            if (m.input && m.input.includes('image')) traits.push('vision');
            if (entry.model_id.toLowerCase().includes('codex') ||
                entry.model_id.toLowerCase().includes('code')) traits.push('coding');
            if (traits.length) entry.traits = traits;
            if (m.contextWindow) entry.context_window = m.contextWindow;
            caps.models.push(entry);
          }
        }
      }
    }
  } catch {}
}

// Detect channels from config
const configDir = path.join(process.env.HOME || '', '.openclaw');
const configFile = path.join(configDir, 'config.yaml');
const channelNames = [
  'whatsapp','telegram','discord','slack','signal','imessage',
  'googlechat','matrix','msteams','irc','line','feishu',
  'mattermost','nostr','twitch','webchat','zalo'
];
// Simplified: report all channels from extensions that exist
caps.channels = caps.extensions
  .filter(e => channelNames.includes(e))
  .concat(['webchat']); // webchat is always available

process.stdout.write(JSON.stringify(caps, null, 2));
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
  resp=$(curl -sf -X POST \
    -H "X-Enrollment-Token: $ENROLLMENT_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Trace-Id: trc_enroll_$(date +%s)" \
    -d "{\"node_id\": \"$nid\"}" \
    "${PLATFORM_URL}/v1/nodes/enroll") || die "Enrollment request failed"

  write_cred "$resp"
  info "Enrolled successfully. Credentials stored in $CRED_FILE"
  echo "$resp" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log('Node ID:', d.node_id); console.log('Token expires in:', d.expires_in, 'seconds');"
}

cmd_register() {
  require_platform_url

  local nid
  nid=$(get_node_id)
  local owner_id="${USER:-unknown}"

  info "Discovering capabilities ..."
  local caps
  caps=$(discover_capabilities)

  local skill_ids
  skill_ids=$(echo "$caps" | node -e "
    const c = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    const ids = c.skills.map(s => JSON.stringify(s));
    process.stdout.write('[' + ids.join(',') + ']');
  ")

  info "Registering node $nid with $(echo "$caps" | node -e "const c=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(c.skills.length + ' skills, ' + c.models.length + ' models, ' + c.extensions.length + ' extensions');") ..."

  local body
  body=$(node -e "
    const caps = JSON.parse(process.argv[1]);
    const body = {
      node_id: process.argv[2],
      owner_id: process.argv[3],
      capabilities: caps,
      max_concurrency: parseInt(process.argv[4], 10),
      labels: { region: process.argv[5], tier: process.argv[6] }
    };
    process.stdout.write(JSON.stringify(body));
  " "$caps" "$nid" "$owner_id" "$MAX_CONCURRENCY" "$REGION" "$TIER")

  local resp
  resp=$(api_call POST /v1/nodes/register -d "$body") || die "Registration failed"
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
    \"max_concurrency\": $MAX_CONCURRENCY,
    \"active_assignments\": []
  }"
}

cmd_pull() {
  require_platform_url
  local nid
  nid=$(get_node_id)
  api_call GET "/v1/assignments/pull?node_id=${nid}&limit=1&wait_seconds=${POLL_WAIT}"
}

cmd_ack() {
  require_platform_url
  local assignment_id="$1"
  local nid
  nid=$(get_node_id)
  local idem_key="idem_ack_${assignment_id}_$(date +%s)"

  api_call POST "/v1/assignments/${assignment_id}/ack" \
    -H "X-Idempotency-Key: $idem_key" \
    -d "{\"node_id\": \"$nid\", \"accepted\": true, \"reason\": null}"
}

cmd_submit_receipt() {
  require_platform_url
  local assignment_id="$1" task_id="$2" outcome="$3" result_ref="$4"
  local quality_score="${5:-0}"
  local error_code="${6:-null}"
  local nid
  nid=$(get_node_id)
  local receipt_id="rcp_$(date +%s)_$$"
  local idem_key="idem_${receipt_id}_v1"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ "$error_code" != "null" ]]; then
    error_code="\"$error_code\""
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
      \"result_ref\": \"$result_ref\",
      \"error_code\": $error_code,
      \"started_at\": \"$now\",
      \"finished_at\": \"$now\",
      \"reported_at\": \"$now\",
      \"version\": 1
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
  info "Node: $nid"
  info "Platform: $PLATFORM_URL"
  info "Credentials: $([ -f "$CRED_FILE" ] && echo 'stored' || echo 'not found')"

  info ""
  info "Capabilities snapshot:"
  discover_capabilities | node -e "
    const c = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    console.log('  Skills:     ', c.skills.length, '(' + c.skills.slice(0,5).join(', ') + (c.skills.length > 5 ? ', ...' : '') + ')');
    console.log('  Models:     ', c.models.length);
    console.log('  Extensions: ', c.extensions.length);
    console.log('  Core Tools: ', c.core_tools.length);
    console.log('  Channels:   ', c.channels.length, '(' + c.channels.join(', ') + ')');
    console.log('  Platform:   ', c.platform.os + '/' + c.platform.arch);
  "
}

cmd_start() {
  require_platform_url
  local nid
  nid=$(get_node_id)

  info "Starting worker loop for node $nid ..."
  info "  Platform:       $PLATFORM_URL"
  info "  Max concurrency: $MAX_CONCURRENCY"
  info "  Heartbeat:       every ${HEARTBEAT_INTERVAL}s"
  info "  Poll wait:       ${POLL_WAIT}s"

  cmd_register

  local last_heartbeat=0
  local active_count=0

  while true; do
    local now
    now=$(date +%s)

    # heartbeat
    if (( now - last_heartbeat >= HEARTBEAT_INTERVAL )); then
      cmd_heartbeat >/dev/null 2>&1 && info "Heartbeat OK" || info "Heartbeat failed (will retry)"
      last_heartbeat=$now
    fi

    # pull if capacity available
    if (( active_count < MAX_CONCURRENCY )); then
      local pull_result
      pull_result=$(cmd_pull 2>/dev/null || echo '{"assignments":[]}')

      local has_assignments
      has_assignments=$(echo "$pull_result" | node -e "
        const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
        process.stdout.write(String((d.assignments || []).length > 0));
      " 2>/dev/null || echo "false")

      if [[ "$has_assignments" == "true" ]]; then
        local asg_id task_id payload_ref
        asg_id=$(echo "$pull_result" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); process.stdout.write(d.assignments[0].assignment_id);")
        task_id=$(echo "$pull_result" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); process.stdout.write(d.assignments[0].task_id);")
        payload_ref=$(echo "$pull_result" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); process.stdout.write(d.assignments[0].payload_ref || '');")

        info "Assignment received: $asg_id (task: $task_id)"
        cmd_ack "$asg_id" >/dev/null 2>&1 && info "ACK sent" || info "ACK failed"
        active_count=$((active_count + 1))

        # Execute in background
        (
          execute_task "$asg_id" "$task_id" "$payload_ref"
          active_count=$((active_count - 1))
        ) &
      fi
    fi

    sleep 2
  done
}

execute_task() {
  local asg_id="$1" task_id="$2" payload_ref="$3"
  info "Executing task $task_id ..."

  local start_time
  start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Download and parse task payload, then execute via openclaw agent
  local result_ref="local://results/${task_id}.json"
  local outcome="success"
  local quality_score=85
  local error_code="null"

  if command -v openclaw &>/dev/null; then
    local task_prompt=""
    if [[ -n "$payload_ref" ]]; then
      task_prompt=$(curl -sf "$payload_ref" 2>/dev/null | node -e "
        try {
          const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
          process.stdout.write(d.prompt || d.description || JSON.stringify(d));
        } catch { process.stdout.write(''); }
      " 2>/dev/null || true)
    fi

    if [[ -n "$task_prompt" ]]; then
      local agent_result
      if agent_result=$(openclaw agent --message "$task_prompt" --print 2>&1); then
        outcome="success"
        quality_score=90
        echo "$agent_result" > "/tmp/workclaws_result_${task_id}.json"
        result_ref="local://results/${task_id}.json"
      else
        outcome="failure"
        quality_score=0
        error_code="TOOL_EXECUTION_FAILED"
      fi
    else
      outcome="failure"
      quality_score=0
      error_code="PAYLOAD_DOWNLOAD_FAILED"
    fi
  else
    outcome="failure"
    quality_score=0
    error_code="OPENCLAW_NOT_AVAILABLE"
  fi

  info "Task $task_id completed: $outcome"
  cmd_submit_receipt "$asg_id" "$task_id" "$outcome" "$result_ref" "$quality_score" "$error_code" \
    >/dev/null 2>&1 && info "Receipt submitted for $task_id" || info "Receipt submission failed for $task_id"
}

# --- main ---

cmd="${1:-help}"
shift || true

case "$cmd" in
  enroll)      cmd_enroll ;;
  register)    cmd_register ;;
  heartbeat)   cmd_heartbeat ;;
  pull)        cmd_pull ;;
  ack)         cmd_ack "$@" ;;
  submit)      cmd_submit_receipt "$@" ;;
  settlements) cmd_settlements ;;
  claim)       cmd_claim "$@" ;;
  status)      cmd_status ;;
  start)       cmd_start ;;
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
    echo "  submit <assignment_id> <task_id> <outcome> <result_ref> [quality_score] [error_code]"
    echo "  settlements   List approved settlements"
    echo "  claim <id>    Claim a settlement"
    exit 1
    ;;
esac
