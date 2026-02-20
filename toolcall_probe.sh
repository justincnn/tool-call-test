#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# API Capability Probe
# Supports: macOS / Linux (bash)
# =========================================================

if [[ -t 1 ]]; then
  BOLD="$(printf '\033[1m')"
  DIM="$(printf '\033[2m')"
  RESET="$(printf '\033[0m')"
  BLUE="$(printf '\033[34m')"
  CYAN="$(printf '\033[36m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  RED="$(printf '\033[31m')"
  GRAY_BG="$(printf '\033[48;5;236m')"
  BAR_BG="$(printf '\033[48;5;238m')"
else
  BOLD=""
  DIM=""
  RESET=""
  BLUE=""
  CYAN=""
  GREEN=""
  YELLOW=""
  RED=""
  GRAY_BG=""
  BAR_BG=""
fi

RESULTS_FILE=""
TOTAL=0

LAST_HTTP_CODE=""
LAST_BODY=""

print_header() {
  echo
  printf "%b" "${GRAY_BG}                                                        ${RESET}\n"
  printf "%b\n" "${GRAY_BG}   🔧  API Capability Probe (OpenAI-Compatible)           ${RESET}"
  printf "%b" "${GRAY_BG}                                                        ${RESET}\n"
  echo
}

print_section() {
  printf "%b\n" "${BOLD}${BLUE}▶ $1${RESET}"
}

print_ok() {
  printf "%b\n" "${GREEN}✓${RESET} $1"
}

print_warn() {
  printf "%b\n" "${YELLOW}⚠${RESET} $1"
}

print_err() {
  printf "%b\n" "${RED}✗${RESET} $1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print_err "缺少依赖命令: $1"
    exit 1
  fi
}

trim_trailing_slash() {
  local input="$1"
  echo "${input%/}"
}

normalize_base_url() {
  local url="$1"
  url="$(trim_trailing_slash "$url")"
  if [[ "$url" =~ /v1$ ]]; then
    echo "${url%/v1}"
  else
    echo "$url"
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default_val="$2"
  local input
  if [[ -n "$default_val" ]]; then
    read -r -p "$prompt [$default_val]: " input
    echo "${input:-$default_val}"
  else
    read -r -p "$prompt: " input
    echo "$input"
  fi
}

pretty_divider() {
  printf "%b\n" "${BAR_BG}                                                        ${RESET}"
}

extract_models_with_python() {
  python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data=json.loads(raw)
except Exception:
    sys.exit(0)
for it in data.get("data", []):
    mid=it.get("id")
    if isinstance(mid,str) and mid.strip():
        print(mid.strip())
'
}

parse_chat_tool_result_with_python() {
  python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("FAIL")
    sys.exit(0)
try:
    data=json.loads(raw)
except Exception:
    print("FAIL")
    sys.exit(0)
choices=data.get("choices")
if not isinstance(choices,list) or not choices:
    print("FAIL")
    sys.exit(0)
msg=(choices[0] or {}).get("message") or {}
if not isinstance(msg,dict):
    print("FAIL")
    sys.exit(0)
tc=msg.get("tool_calls")
if isinstance(tc,list) and len(tc)>0:
    first=tc[0] if isinstance(tc[0],dict) else {}
    fn=(first.get("function") or {}) if isinstance(first,dict) else {}
    name=fn.get("name","unknown")
    print("PASS:"+str(name))
    sys.exit(0)
content=msg.get("content")
if isinstance(content,str) and "tool" in content.lower():
    print("SOFT_PASS")
    sys.exit(0)
print("FAIL")
'
}

parse_chat_basic_with_python() {
  python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("FAIL")
    sys.exit(0)
try:
    data=json.loads(raw)
except Exception:
    print("FAIL")
    sys.exit(0)
choices=data.get("choices")
if isinstance(choices,list) and len(choices)>0:
    print("PASS")
else:
    print("FAIL")
'
}

parse_responses_basic_with_python() {
  python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("FAIL")
    sys.exit(0)
try:
    data=json.loads(raw)
except Exception:
    print("FAIL")
    sys.exit(0)
if isinstance(data.get("id"),str) and data.get("id"):
    print("PASS")
    sys.exit(0)
out=data.get("output")
if isinstance(out,list):
    print("PASS")
    sys.exit(0)
print("FAIL")
'
}

choose_models() {
  CHOSEN_MODELS=()

  echo
  print_section "可用模型列表"
  local i=1
  for m in "${MODELS[@]}"; do
    printf "%b\n" "  ${DIM}[$i]${RESET} $m"
    i=$((i+1))
  done

  echo
  echo "选择方式："
  echo "  1) all（全选）"
  echo "  2) 输入编号（逗号分隔），例如: 1,3,5"

  local pick
  read -r -p "请输入选择: " pick
  pick="$(echo "$pick" | tr '[:upper:]' '[:lower:]' | xargs)"

  if [[ "$pick" == "all" || "$pick" == "1" ]]; then
    CHOSEN_MODELS=("${MODELS[@]}")
    return
  fi

  if [[ -z "$pick" ]]; then
    print_warn "未输入选择，默认全选。"
    CHOSEN_MODELS=("${MODELS[@]}")
    return
  fi

  local -a tmp_selected=()
  IFS=',' read -r -a idxs <<< "$pick"
  for raw_idx in "${idxs[@]}"; do
    local idx
    idx="$(echo "$raw_idx" | xargs)"
    if [[ "$idx" =~ ^[0-9]+$ ]]; then
      if (( idx >= 1 && idx <= ${#MODELS[@]} )); then
        tmp_selected+=("${MODELS[$((idx-1))]}")
      else
        print_warn "编号超出范围: $idx（已忽略）"
      fi
    else
      print_warn "无效编号: $idx（已忽略）"
    fi
  done

  if (( ${#tmp_selected[@]} == 0 )); then
    print_warn "未选中有效模型，默认全选。"
    CHOSEN_MODELS=("${MODELS[@]}")
  else
    CHOSEN_MODELS=("${tmp_selected[@]}")
  fi
}

fetch_models() {
  local base_url="$1"
  local api_key="$2"

  local endpoint="${base_url}/v1/models"
  local response
  response="$(curl -sS --connect-timeout 20 --max-time 60 \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    "$endpoint" || true)"

  echo "$response"
}

request_json() {
  local endpoint="$1"
  local api_key="$2"
  local payload="$3"
  local max_time="$4"

  local response
  response="$(curl -sS --connect-timeout 20 --max-time "$max_time" -w "\n%{http_code}" \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$endpoint" || true)"

  LAST_HTTP_CODE="$(echo "$response" | tail -n1 | tr -d '\r')"
  LAST_BODY="$(echo "$response" | sed '$d')"
}

request_stream_raw() {
  local endpoint="$1"
  local api_key="$2"
  local payload="$3"
  local max_time="$4"

  local response
  response="$(curl -sS --no-buffer --connect-timeout 20 --max-time "$max_time" -w "\n%{http_code}" \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$endpoint" || true)"

  LAST_HTTP_CODE="$(echo "$response" | tail -n1 | tr -d '\r')"
  LAST_BODY="$(echo "$response" | sed '$d')"
}

is_http_2xx() {
  local code="$1"
  [[ "$code" =~ ^2 ]]
}

probe_chat_completion() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local payload
  payload=$(cat <<JSON
{
  "model": "$model",
  "messages": [
    {"role": "user", "content": "请回复 ok"}
  ],
  "temperature": 0
}
JSON
)

  request_json "${base_url}/v1/chat/completions" "$api_key" "$payload" 60
  if ! is_http_2xx "$LAST_HTTP_CODE"; then
    echo "N|http=${LAST_HTTP_CODE:-unknown}"
    return
  fi

  local parsed
  parsed="$(echo "$LAST_BODY" | parse_chat_basic_with_python)"
  if [[ "$parsed" == "PASS" ]]; then
    echo "Y|ok"
  else
    echo "N|invalid_response"
  fi
}

probe_stream_support() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local payload
  payload=$(cat <<JSON
{
  "model": "$model",
  "messages": [
    {"role": "user", "content": "请简单回复 hi"}
  ],
  "stream": true,
  "temperature": 0
}
JSON
)

  request_stream_raw "${base_url}/v1/chat/completions" "$api_key" "$payload" 60
  if ! is_http_2xx "$LAST_HTTP_CODE"; then
    echo "N|http=${LAST_HTTP_CODE:-unknown}"
    return
  fi

  if echo "$LAST_BODY" | grep -q "data:"; then
    echo "Y|sse_data_found"
  else
    echo "N|no_sse_marker"
  fi
}

probe_tool_call() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local payload
  payload=$(cat <<JSON
{
  "model": "$model",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "请调用工具 get_time 来获取当前时间。不要直接回答时间。"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_time",
        "description": "获取当前时间",
        "parameters": {
          "type": "object",
          "properties": {
            "timezone": {"type": "string", "description": "IANA 时区"}
          },
          "required": ["timezone"]
        }
      }
    }
  ],
  "tool_choice": "auto",
  "temperature": 0
}
JSON
)

  request_json "${base_url}/v1/chat/completions" "$api_key" "$payload" 90
  if ! is_http_2xx "$LAST_HTTP_CODE"; then
    echo "N|http=${LAST_HTTP_CODE:-unknown}"
    return
  fi

  local parsed
  parsed="$(echo "$LAST_BODY" | parse_chat_tool_result_with_python)"
  case "$parsed" in
    PASS:*)
      echo "Y|${parsed#PASS:}"
      ;;
    SOFT_PASS)
      echo "~|content_hints_tool"
      ;;
    *)
      echo "N|no_tool_calls"
      ;;
  esac
}

probe_responses_support() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local payload
  payload=$(cat <<JSON
{
  "model": "$model",
  "input": "请回复 ok"
}
JSON
)

  request_json "${base_url}/v1/responses" "$api_key" "$payload" 60
  if ! is_http_2xx "$LAST_HTTP_CODE"; then
    echo "N|http=${LAST_HTTP_CODE:-unknown}"
    return
  fi

  local parsed
  parsed="$(echo "$LAST_BODY" | parse_responses_basic_with_python)"
  if [[ "$parsed" == "PASS" ]]; then
    echo "Y|ok"
  else
    echo "N|invalid_response"
  fi
}

probe_search_support() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local payload
  payload=$(cat <<JSON
{
  "model": "$model",
  "input": "请搜索今天的科技新闻并给一条标题。",
  "tools": [
    {"type": "web_search_preview"}
  ]
}
JSON
)

  request_json "${base_url}/v1/responses" "$api_key" "$payload" 75
  if ! is_http_2xx "$LAST_HTTP_CODE"; then
    echo "N|http=${LAST_HTTP_CODE:-unknown}"
    return
  fi

  echo "Y|ok"
}

probe_reasoning_support() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local payload
  payload=$(cat <<JSON
{
  "model": "$model",
  "input": "比较 17*19 与 18*18 的大小并说明理由。",
  "reasoning": {"effort": "medium"}
}
JSON
)

  request_json "${base_url}/v1/responses" "$api_key" "$payload" 75
  if ! is_http_2xx "$LAST_HTTP_CODE"; then
    echo "N|http=${LAST_HTTP_CODE:-unknown}"
    return
  fi

  echo "Y|ok"
}

probe_structured_output_support() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local payload
  payload=$(cat <<JSON
{
  "model": "$model",
  "messages": [
    {"role": "user", "content": "输出一个 JSON：字段 ok 为布尔值。"}
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "simple_flag",
      "schema": {
        "type": "object",
        "properties": {
          "ok": {"type": "boolean"}
        },
        "required": ["ok"],
        "additionalProperties": false
      }
    }
  },
  "temperature": 0
}
JSON
)

  request_json "${base_url}/v1/chat/completions" "$api_key" "$payload" 75
  if ! is_http_2xx "$LAST_HTTP_CODE"; then
    echo "N|http=${LAST_HTTP_CODE:-unknown}"
    return
  fi

  local parsed
  parsed="$(echo "$LAST_BODY" | parse_chat_basic_with_python)"
  if [[ "$parsed" == "PASS" ]]; then
    echo "Y|ok"
  else
    echo "N|invalid_response"
  fi
}

save_result_line() {
  local model="$1"
  local chat="$2"
  local stream="$3"
  local resp="$4"
  local tool="$5"
  local search="$6"
  local reasoning="$7"
  local structured="$8"
  local notes="$9"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$model" "$chat" "$stream" "$resp" "$tool" "$search" "$reasoning" "$structured" "$notes" >> "$RESULTS_FILE"
}

count_supported_by_column() {
  local col="$1"
  awk -F '\t' -v c="$col" '$c=="Y"{n++} END{print n+0}' "$RESULTS_FILE"
}

print_models_by_col_value() {
  local col="$1"
  local val="$2"
  local icon="$3"
  local color="$4"
  local has_items=0
  while IFS=$'\t' read -r model chat stream resp tool search reasoning structured notes; do
    local candidate=""
    case "$col" in
      2) candidate="$chat" ;;
      3) candidate="$stream" ;;
      4) candidate="$resp" ;;
      5) candidate="$tool" ;;
      6) candidate="$search" ;;
      7) candidate="$reasoning" ;;
      8) candidate="$structured" ;;
      *) candidate="" ;;
    esac

    if [[ "$candidate" == "$val" ]]; then
      has_items=1
      printf "  %b%-1s%b %-34s %s\n" "$color" "$icon" "$RESET" "$model" "$notes"
    fi
  done < "$RESULTS_FILE"

  if (( has_items == 0 )); then
    printf "  ${DIM}- 无${RESET}\n"
  fi
}

render_summary() {
  local chat_yes stream_yes resp_yes tool_yes search_yes reasoning_yes structured_yes
  chat_yes="$(count_supported_by_column 2)"
  stream_yes="$(count_supported_by_column 3)"
  resp_yes="$(count_supported_by_column 4)"
  tool_yes="$(count_supported_by_column 5)"
  search_yes="$(count_supported_by_column 6)"
  reasoning_yes="$(count_supported_by_column 7)"
  structured_yes="$(count_supported_by_column 8)"

  echo
  pretty_divider
  printf "%b\n" "${BOLD}${CYAN}最终 Result 分类${RESET}"
  pretty_divider

  printf "%b\n" "${BOLD}Result 1 · 能力摘要${RESET}"
  printf "  %-18s %s/%s\n" "chat_completions" "$chat_yes" "$TOTAL"
  printf "  %-18s %s/%s\n" "stream" "$stream_yes" "$TOTAL"
  printf "  %-18s %s/%s\n" "responses" "$resp_yes" "$TOTAL"
  printf "  %-18s %s/%s\n" "tool_call(strict)" "$tool_yes" "$TOTAL"
  printf "  %-18s %s/%s\n" "web_search" "$search_yes" "$TOTAL"
  printf "  %-18s %s/%s\n" "reasoning" "$reasoning_yes" "$TOTAL"
  printf "  %-18s %s/%s\n" "structured_output" "$structured_yes" "$TOTAL"
  echo

  printf "%b\n" "${BOLD}Result 2 · 接口支持分类${RESET}"
  printf "%b\n" "${CYAN}- 同时支持 chat_completions + responses${RESET}"
  awk -F '\t' '$2=="Y" && $4=="Y" {printf "  ✓ %-34s %s\n", $1, $9; hit=1} END{if(!hit) print "  - 无"}' "$RESULTS_FILE"
  printf "%b\n" "${CYAN}- 仅支持 chat_completions${RESET}"
  awk -F '\t' '$2=="Y" && $4!="Y" {printf "  ✓ %-34s %s\n", $1, $9; hit=1} END{if(!hit) print "  - 无"}' "$RESULTS_FILE"
  printf "%b\n" "${CYAN}- 仅支持 responses${RESET}"
  awk -F '\t' '$2!="Y" && $4=="Y" {printf "  ✓ %-34s %s\n", $1, $9; hit=1} END{if(!hit) print "  - 无"}' "$RESULTS_FILE"
  printf "%b\n" "${CYAN}- 两者都不支持${RESET}"
  awk -F '\t' '$2!="Y" && $4!="Y" {printf "  ✗ %-34s %s\n", $1, $9; hit=1} END{if(!hit) print "  - 无"}' "$RESULTS_FILE"
  echo

  printf "%b\n" "${BOLD}Result 3 · 模型能力矩阵${RESET}"
  printf "%-24s | %-4s | %-6s | %-4s | %-6s | %-6s | %-9s | %-10s\n" "MODEL" "CHAT" "STREAM" "RESP" "TOOL" "SEARCH" "REASONING" "STRUCTURED"
  printf "%.0s-" {1..112}
  echo
  while IFS=$'\t' read -r model chat stream resp tool search reasoning structured notes; do
    printf "%-24s | %-4s | %-6s | %-4s | %-6s | %-6s | %-9s | %-10s\n" "$model" "$chat" "$stream" "$resp" "$tool" "$search" "$reasoning" "$structured"
  done < "$RESULTS_FILE"
  echo

  printf "%b\n" "${BOLD}Result 4 · 按能力分类（支持）${RESET}"
  printf "%b\n" "${CYAN}- chat_completions${RESET}"
  print_models_by_col_value 2 "Y" "✓" "$GREEN"
  printf "%b\n" "${CYAN}- stream${RESET}"
  print_models_by_col_value 3 "Y" "✓" "$GREEN"
  printf "%b\n" "${CYAN}- responses${RESET}"
  print_models_by_col_value 4 "Y" "✓" "$GREEN"
  printf "%b\n" "${CYAN}- tool_call（严格）${RESET}"
  print_models_by_col_value 5 "Y" "✓" "$GREEN"
  printf "%b\n" "${CYAN}- tool_call（软支持）${RESET}"
  print_models_by_col_value 5 "~" "⚠" "$YELLOW"
  printf "%b\n" "${CYAN}- web_search${RESET}"
  print_models_by_col_value 6 "Y" "✓" "$GREEN"
  printf "%b\n" "${CYAN}- reasoning${RESET}"
  print_models_by_col_value 7 "Y" "✓" "$GREEN"
  printf "%b\n" "${CYAN}- structured_output(json_schema)${RESET}"
  print_models_by_col_value 8 "Y" "✓" "$GREEN"

  pretty_divider
  echo
}

main() {
  require_cmd curl
  require_cmd python3

  print_header
  print_section "输入连接信息"

  local default_url="${API_BASE_URL:-}"
  local default_key="${API_KEY:-}"

  local base_url api_key
  base_url="$(prompt_with_default "请输入 API Base URL（例如 https://api.openai.com）" "$default_url")"
  api_key="$(prompt_with_default "请输入 API Key" "$default_key")"

  base_url="$(normalize_base_url "$base_url")"

  if [[ -z "$base_url" || -z "$api_key" ]]; then
    print_err "URL 或 Key 不能为空。"
    exit 1
  fi

  print_section "拉取模型清单"
  local model_json
  model_json="$(fetch_models "$base_url" "$api_key")"

  if [[ -z "$model_json" ]]; then
    print_err "无法拉取模型清单。请检查 URL、Key 或网络。"
    exit 1
  fi

  MODELS=()
  while IFS= read -r model_line; do
    [[ -n "$model_line" ]] && MODELS+=("$model_line")
  done < <(echo "$model_json" | extract_models_with_python)

  if (( ${#MODELS[@]} == 0 )); then
    print_err "模型清单为空或返回格式不兼容。"
    exit 1
  fi

  print_ok "成功获取 ${#MODELS[@]} 个模型。"
  choose_models

  if (( ${#CHOSEN_MODELS[@]} == 0 )); then
    print_err "未选择任何模型。"
    exit 1
  fi

  RESULTS_FILE="$(mktemp)"

  print_section "开始探测模型能力（chat / stream / responses / tool / search / reasoning）"

  for m in "${CHOSEN_MODELS[@]}"; do
    TOTAL=$((TOTAL+1))
    printf "%b\n" "${DIM}→ 测试模型:${RESET} $m"

    local chat_raw stream_raw resp_raw tool_raw search_raw reasoning_raw structured_raw
    local chat_status stream_status resp_status tool_status search_status reasoning_status structured_status
    local chat_detail stream_detail resp_detail tool_detail search_detail reasoning_detail structured_detail

    chat_raw="$(probe_chat_completion "$base_url" "$api_key" "$m")"
    stream_raw="$(probe_stream_support "$base_url" "$api_key" "$m")"
    resp_raw="$(probe_responses_support "$base_url" "$api_key" "$m")"
    tool_raw="$(probe_tool_call "$base_url" "$api_key" "$m")"
    search_raw="$(probe_search_support "$base_url" "$api_key" "$m")"
    reasoning_raw="$(probe_reasoning_support "$base_url" "$api_key" "$m")"
    structured_raw="$(probe_structured_output_support "$base_url" "$api_key" "$m")"

    chat_status="${chat_raw%%|*}"; chat_detail="${chat_raw#*|}"
    stream_status="${stream_raw%%|*}"; stream_detail="${stream_raw#*|}"
    resp_status="${resp_raw%%|*}"; resp_detail="${resp_raw#*|}"
    tool_status="${tool_raw%%|*}"; tool_detail="${tool_raw#*|}"
    search_status="${search_raw%%|*}"; search_detail="${search_raw#*|}"
    reasoning_status="${reasoning_raw%%|*}"; reasoning_detail="${reasoning_raw#*|}"
    structured_status="${structured_raw%%|*}"; structured_detail="${structured_raw#*|}"

    local notes="chat=${chat_detail};stream=${stream_detail};resp=${resp_detail};tool=${tool_detail};search=${search_detail};reasoning=${reasoning_detail};structured=${structured_detail}"
    save_result_line "$m" "$chat_status" "$stream_status" "$resp_status" "$tool_status" "$search_status" "$reasoning_status" "$structured_status" "$notes"

    print_ok "$m => chat:${chat_status} stream:${stream_status} responses:${resp_status} tool:${tool_status} search:${search_status} reasoning:${reasoning_status} structured:${structured_status}"
  done

  render_summary
  rm -f "$RESULTS_FILE"

  print_section "完成"
  print_ok "探测结束。"
}

main "$@"
