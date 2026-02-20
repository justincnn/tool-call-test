#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# API Tool Call Probe
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
PASS=0
FAIL=0
SKIP=0

print_header() {
  echo
  printf "%b" "${GRAY_BG}                                                        ${RESET}\n"
  printf "%b\n" "${GRAY_BG}   🔧  API Tool Call Probe (OpenAI-Compatible)            ${RESET}"
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

extract_models_with_python() {
  python3 - <<'PY'
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data=json.loads(raw)
except Exception:
    sys.exit(0)
items=data.get("data", [])
for it in items:
    mid=it.get("id")
    if isinstance(mid,str) and mid.strip():
        print(mid.strip())
PY
}

parse_tool_call_result_with_python() {
  python3 - <<'PY'
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("INVALID_JSON")
    sys.exit(0)
try:
    data=json.loads(raw)
except Exception:
    print("INVALID_JSON")
    sys.exit(0)
choices=data.get("choices")
if not isinstance(choices,list) or not choices:
    print("NO_CHOICES")
    sys.exit(0)
msg=(choices[0] or {}).get("message") or {}
if not isinstance(msg,dict):
    print("NO_MESSAGE")
    sys.exit(0)
tc=msg.get("tool_calls")
if isinstance(tc,list) and len(tc)>0:
    first=tc[0] if isinstance(tc[0],dict) else {}
    fn=(first.get("function") or {}) if isinstance(first,dict) else {}
    name=fn.get("name","")
    print("PASS:"+str(name))
    sys.exit(0)
content=msg.get("content")
if isinstance(content,str) and "tool" in content.lower():
    print("SOFT_PASS")
    sys.exit(0)
print("FAIL")
PY
}

join_by_comma() {
  local IFS=","
  echo "$*"
}

pretty_divider() {
  printf "%b\n" "${BAR_BG}                                                        ${RESET}"
}

choose_models() {
  local -n all_models_ref=$1
  local -n selected_models_ref=$2

  echo
  print_section "可用模型列表"
  local i=1
  for m in "${all_models_ref[@]}"; do
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
    selected_models_ref=("${all_models_ref[@]}")
    return
  fi

  if [[ -z "$pick" ]]; then
    print_warn "未输入选择，默认全选。"
    selected_models_ref=("${all_models_ref[@]}")
    return
  fi

  local -a tmp_selected=()
  IFS=',' read -r -a idxs <<< "$pick"
  for raw_idx in "${idxs[@]}"; do
    local idx
    idx="$(echo "$raw_idx" | xargs)"
    if [[ "$idx" =~ ^[0-9]+$ ]]; then
      if (( idx >= 1 && idx <= ${#all_models_ref[@]} )); then
        tmp_selected+=("${all_models_ref[$((idx-1))]}")
      else
        print_warn "编号超出范围: $idx（已忽略）"
      fi
    else
      print_warn "无效编号: $idx（已忽略）"
    fi
  done

  if (( ${#tmp_selected[@]} == 0 )); then
    print_warn "未选中有效模型，默认全选。"
    selected_models_ref=("${all_models_ref[@]}")
  else
    selected_models_ref=("${tmp_selected[@]}")
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

  if [[ -z "$response" ]]; then
    echo ""
    return
  fi

  echo "$response"
}

probe_model_tool_call() {
  local base_url="$1"
  local api_key="$2"
  local model="$3"

  local endpoint="${base_url}/v1/chat/completions"
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

  local response http_code
  response="$(curl -sS --connect-timeout 20 --max-time 90 -w "\n%{http_code}" \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$endpoint" || true)"

  http_code="$(echo "$response" | tail -n1 | tr -d '\r')"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ ! "$http_code" =~ ^2 ]]; then
    echo "HTTP_FAIL|$http_code|$body"
    return
  fi

  local parsed
  parsed="$(echo "$body" | parse_tool_call_result_with_python)"

  case "$parsed" in
    PASS:*)
      local fn_name="${parsed#PASS:}"
      echo "PASS|$fn_name|$body"
      ;;
    SOFT_PASS)
      echo "SOFT_PASS||$body"
      ;;
    *)
      echo "FAIL||$body"
      ;;
  esac
}

save_result_line() {
  local model="$1"
  local status="$2"
  local detail="$3"
  printf "%s\t%s\t%s\n" "$model" "$status" "$detail" >> "$RESULTS_FILE"
}

render_summary_table() {
  echo
  pretty_divider
  printf "%b\n" "${BOLD}${CYAN}检测结果总览${RESET}"
  pretty_divider

  printf "%-38s | %-10s | %s\n" "MODEL" "RESULT" "DETAIL"
  printf "%.0s-" {1..90}
  echo

  while IFS=$'\t' read -r model status detail; do
    local status_colored="$status"
    case "$status" in
      PASS) status_colored="${GREEN}PASS${RESET}" ;;
      SOFT_PASS) status_colored="${YELLOW}SOFT_PASS${RESET}" ;;
      FAIL) status_colored="${RED}FAIL${RESET}" ;;
      SKIP) status_colored="${DIM}SKIP${RESET}" ;;
      *) status_colored="$status" ;;
    esac

    printf "%-38s | %-19b | %s\n" "$model" "$status_colored" "$detail"
  done < "$RESULTS_FILE"

  pretty_divider
  printf "%b\n" "${BOLD}总计:${RESET} $TOTAL    ${GREEN}PASS:${PASS}${RESET}    ${YELLOW}SOFT_PASS:${SKIP}${RESET}    ${RED}FAIL:${FAIL}${RESET}"
  pretty_divider
  echo
}

main() {
  require_cmd curl
  require_cmd python3

  print_header
  print_section "输入连接信息"

  local default_url
  default_url="${API_BASE_URL:-}"
  local default_key
  default_key="${API_KEY:-}"

  local base_url api_key
  base_url="$(prompt_with_default "请输入 API Base URL（例如 https://api.openai.com）" "$default_url")"
  api_key="$(prompt_with_default "请输入 API Key" "$default_key")"

  base_url="$(trim_trailing_slash "$base_url")"

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

  mapfile -t models < <(echo "$model_json" | extract_models_with_python)

  if (( ${#models[@]} == 0 )); then
    print_err "模型清单为空或返回格式不兼容。"
    exit 1
  fi

  print_ok "成功获取 ${#models[@]} 个模型。"

  local -a selected=()
  choose_models models selected

  if (( ${#selected[@]} == 0 )); then
    print_err "未选择任何模型。"
    exit 1
  fi

  print_section "开始探测 Tool Call"
  RESULTS_FILE="$(mktemp)"

  for m in "${selected[@]}"; do
    TOTAL=$((TOTAL+1))
    printf "%b\n" "${DIM}→ 测试模型:${RESET} $m"

    local result_line status detail raw
    raw="$(probe_model_tool_call "$base_url" "$api_key" "$m")"

    status="$(echo "$raw" | cut -d'|' -f1)"
    detail="$(echo "$raw" | cut -d'|' -f2)"

    case "$status" in
      PASS)
        PASS=$((PASS+1))
        print_ok "$m 支持 tool call（function: ${detail:-unknown}）"
        save_result_line "$m" "PASS" "function=${detail:-unknown}"
        ;;
      SOFT_PASS)
        SKIP=$((SKIP+1))
        print_warn "$m 返回内容疑似提及工具，但未严格返回 tool_calls"
        save_result_line "$m" "SOFT_PASS" "content hints tool usage"
        ;;
      HTTP_FAIL)
        FAIL=$((FAIL+1))
        print_err "$m 请求失败（HTTP ${detail:-unknown}）"
        save_result_line "$m" "FAIL" "http=${detail:-unknown}"
        ;;
      *)
        FAIL=$((FAIL+1))
        print_err "$m 未检测到有效 tool_calls"
        save_result_line "$m" "FAIL" "no tool_calls"
        ;;
    esac
  done

  render_summary_table
  rm -f "$RESULTS_FILE"

  print_section "完成"
  print_ok "探测结束。"
}

main "$@"
