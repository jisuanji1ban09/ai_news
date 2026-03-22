#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# AI Daily Poster PLUS Generation Script (Enhanced Version with Voiceover)
# Independent from the old 'daily-ai-poster' task
# Steps: Fetch News -> Parse Candidates -> Generate Top5 -> Refine Summaries -> Render Poster -> Generate Voiceover -> Send to Feishu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables (robust method)
if [ -f "$WORKSPACE/.env" ]; then
    set -a
    . "$WORKSPACE/.env"
    set +a
fi

# Configuration
MAX_ATTEMPTS=3  # Total attempts (1 initial + 2 retries)
ATTEMPT_NO=0
SKILL_DIR="$WORKSPACE/skills/daily-brief-to-poster"
SUMMARY_REFINER_DIR="$WORKSPACE/skills/summary-one-line-refiner"
AI_ROOT="${AI_ROOT:-$WORKSPACE/ai_news}"
DATE_STR=$(TZ="Asia/Shanghai" date +"%Y.%m.%d")
DATE_DIR=$(TZ="Asia/Shanghai" date +"%Y-%m-%d")
NOW_STR=$(TZ="Asia/Shanghai" date +"%Y-%m-%d %H:%M")

# Unified directories for today
TODAY_ROOT="$AI_ROOT/$DATE_DIR"
LOG_ROOT_DIR="$TODAY_ROOT/logs"
DATA_DIR="$TODAY_ROOT/data"
OUTPUT_DIR="$TODAY_ROOT/output"
TARGET_USER="${TARGET_USER:-user:ou_fe30fbdabcf5e38016c49c53f55abf76}"

FETCH_ERR_FILE="$DATA_DIR/fetch_errors.log"

# Paths for files
JSON_FILE="$DATA_DIR/daily_brief.json"
CANDIDATE_JSON_FILE="$DATA_DIR/candidates.json"
TOP5_JSON_FILE="$DATA_DIR/top5.json"
VOICEOVER_SCRIPT_FILE="$DATA_DIR/voice_script.txt"
SEND_SUMMARY_FILE="$DATA_DIR/send_summary_plus.txt"
RUN_LOG_DIR="$LOG_ROOT_DIR"
RUN_ID="$(TZ="Asia/Shanghai" date +"%Y%m%d-%H%M%S")-$$_$RANDOM"
RUN_LOG_FILE="$RUN_LOG_DIR/run.log"

# Create directories
mkdir -p "$DATA_DIR" "$OUTPUT_DIR" "$RUN_LOG_DIR"

# Redirect output to log file and terminal
exec > >(tee -a "$RUN_LOG_FILE") 2>&1

# Logging functions
log() {
    echo "[$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_step_start() {
    local step_name="$1"
    log "STEP status=start step=\"$step_name\" attempt=$ATTEMPT_NO run_id=$RUN_ID"
}

log_step_ok() {
    local step_name="$1"
    log "STEP status=ok step=\"$step_name\" attempt=$ATTEMPT_NO run_id=$RUN_ID"
}

log_step_fail() {
    local step_name="$1"
    local error_msg="$2"
    log "STEP status=fail step=\"$step_name\" attempt=$ATTEMPT_NO error=\"$error_msg\" run_id=$RUN_ID"
}

# Main execution loop
while [ $ATTEMPT_NO -lt $MAX_ATTEMPTS ]; do
    ATTEMPT_NO=$((ATTEMPT_NO + 1))
    log "=== Attempt ${ATTEMPT_NO}/${MAX_ATTEMPTS} ==="

    ERROR_MSG=""
    CURRENT_STEP=""

    # Clean up old artifacts at start of each attempt
    log "Cleaning up old artifacts for attempt $ATTEMPT_NO..."
    rm -f "$CANDIDATE_JSON_FILE" "$TOP5_JSON_FILE" "$JSON_FILE" "$VOICEOVER_SCRIPT_FILE" "$SEND_SUMMARY_FILE"

    # Step 1: Fetch News
    CURRENT_STEP="[1/8] Fetching AI news"
    log_step_start "$CURRENT_STEP"

    mkdir -p "$DATA_DIR"
    : > "$FETCH_ERR_FILE"

    # 6 targeted queries covering 5 mandatory news categories.
    # Query 2 uses --days 2 to compensate for Tavily indexing delay
    # on North American announcements (posted ~01:00-06:00 CST).
    NEWS_RAW=""
    FETCH_EXIT_CODE=0

    _fetch_query() {
        local query="$1"
        local n="$2"
        local days="$3"
        local result
        set +e
        result=$(node "$WORKSPACE/skills/tavily-search/scripts/search.mjs" \
            "$query" \
            --topic news --days "$days" -n "$n" 2>>"$FETCH_ERR_FILE")
        local code=$?
        set -e
        if [ $code -ne 0 ]; then
            log "WARNING: query failed (exit $code): $query"
            FETCH_EXIT_CODE=$code
        else
            NEWS_RAW="${NEWS_RAW}"$'\n'"${result}"
        fi
    }

    # Q1: Large model releases (core category)
    _fetch_query "AI large language model release launched today" 5 1
    # Q2: North American big tech with --days 2 to cover indexing delay
    _fetch_query "OpenAI Google Anthropic Meta AI announcement" 5 2
    # Q3: China domestic AI companies
    _fetch_query "China AI Baidu ByteDance Alibaba Tencent news" 4 1
    # Q4: AI product and application deployment
    _fetch_query "AI product launch application deployment" 4 1
    # Q5: Chip, GPU, infrastructure, funding
    _fetch_query "AI chip GPU infrastructure investment funding" 4 1
    # Q6: Policy and regulation
    _fetch_query "AI policy regulation government law" 4 1

    if [ -z "$(echo "$NEWS_RAW" | tr -d '[:space:]')" ]; then
        ERROR_MSG="All Tavily queries returned empty results. Check $FETCH_ERR_FILE"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi

    log_step_ok "$CURRENT_STEP"
    log "Fetch error log: $FETCH_ERR_FILE"

    # Step 2: Parse Candidates
    CURRENT_STEP="[2/8] Parsing candidates"
    log_step_start "$CURRENT_STEP"

    export NEWS_RAW NOW_STR DATE_DIR CANDIDATE_JSON_FILE
    set +e
    python3 <<'PYEOF'
import json, os, re
from urllib.parse import urlparse

raw_text = os.environ.get("NEWS_RAW", "")
output_json = os.environ.get("CANDIDATE_JSON_FILE", "")

title_re = re.compile(r'^-\s+\*\*(.+?)\*\*(?:\s+\(relevance:\s*(\d+)%\))?')
url_re = re.compile(r'^https?://', re.IGNORECASE)

def infer_source(url):
    if not url: return "Unknown"
    host = urlparse(url).netloc.lower().split(":")[0]
    if host.startswith("www."): host = host[4:]
    return host.split(".")[0].replace("-", " ").title() or "Unknown"

def infer_category(text):
    if any(k in text for k in ["openai", "google", "microsoft", "anthropic"]): return "bigtech"
    if any(k in text for k in ["funding", "raised", "acquisition"]): return "funding_mna"
    if any(k in text for k in ["chip", "gpu", "semiconductor"]): return "chip_infrastructure"
    if any(k in text for k in ["policy", "regulation", "law"]): return "regulation_policy"
    return "general_ai"

candidates = []
i = 0
lines = raw_text.splitlines()
while i < len(lines) and len(candidates) < 20:
    line = lines[i].strip()
    m = title_re.match(line)
    if not m:
        i += 1
        continue
    title = m.group(1).strip()
    url = ""
    summary = ""
    i += 1
    while i < len(lines):
        cur = lines[i].strip()
        if not cur or title_re.match(cur): break
        if url_re.match(cur):
            if not url: url = cur
        else:
            summary += " " + cur
        i += 1

    if len(summary) > 200: summary = summary[:197] + "..."
    candidates.append({
        "id": str(len(candidates) + 1),
        "title": title,
        "source": infer_source(url),
        "url": url,
        "summary_cn": summary.strip(),
        "category": infer_category(title + " " + summary),
        "importance_score": 60 + int(m.group(2)) * 0.35 if m.group(2) else 60
    })

with open(output_json, "w", encoding="utf-8") as f:
    json.dump(candidates, f, ensure_ascii=False, indent=2)
print(f"Parsed {len(candidates)} candidates")
PYEOF
    PY_EXIT_CODE=$?
    set -e

    if [ $PY_EXIT_CODE -ne 0 ] || [ ! -f "$CANDIDATE_JSON_FILE" ]; then
        ERROR_MSG="Candidate parsing failed (exit: $PY_EXIT_CODE, file missing: $CANDIDATE_JSON_FILE)"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi
    CANDIDATE_COUNT=$(python3 -c "import json,sys; data=json.load(open('$CANDIDATE_JSON_FILE')); print(len(data))" 2>/dev/null || echo "0")
    if [ "$CANDIDATE_COUNT" -lt 8 ]; then
        ERROR_MSG="Too few candidates parsed: $CANDIDATE_COUNT (need >= 8). Check $FETCH_ERR_FILE"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi
    log "Parsed candidates: $CANDIDATE_COUNT"
    log_step_ok "$CURRENT_STEP"

    # Step 3: Generate Top5 JSON (Robust JSON parsing & validation)
    exit 0
    CURRENT_STEP="[3/8] Generating Top5 JSON"
    log_step_start "$CURRENT_STEP"

    export DATE_STR JSON_FILE CANDIDATE_JSON_FILE TOP5_JSON_FILE
    set +e
    python3 <<'PYEOF'
import json
import os
import re
import subprocess
import string
import uuid
import unicodedata
from json import JSONDecoder, JSONDecodeError

date_str = os.environ.get('DATE_STR', '')
json_file = os.environ.get('JSON_FILE', '')
candidate_json_file = os.environ.get('CANDIDATE_JSON_FILE', '')
top5_json_file = os.environ.get('TOP5_JSON_FILE', '')
TITLE_MAX_CHARS = 22
SUMMARY_MAX_CHARS = 34

def has_chinese(text: str) -> bool:
    return bool(re.search(r'[\u4e00-\u9fff]', text or ""))

def needs_cn_fallback(items):
    # If any item lacks Chinese in title or summary, trigger fallback translation.
    for it in items:
        if not has_chinese(str(it.get("title", ""))) or not has_chinese(str(it.get("summary", ""))):
            return True
    return False

def fallback_translate_to_cn(items):
    """Use openclaw agent to rewrite all items into Simplified Chinese JSON."""
    translate_prompt = f"""你是中文科技编辑。请把下面 items 改写为中文海报文案，并严格输出 JSON 数组。

硬约束：
1) 所有 title、summary 必须是简体中文（专有名词可保留英文，如 OpenAI、GPU）。
2) title 要尽量短；summary 要尽量短且信息完整。
3) summary 必须补充 title 没有的新信息，不能复述 title。
4) 仅输出 JSON 数组，不要解释，不要 markdown。

输入 items:
{json.dumps(items, ensure_ascii=False, indent=2)}
"""
    isolated_session_id = f"isolated-{uuid.uuid4().hex[:12]}"
    cmd = [
        "openclaw", "agent", "--session-id", isolated_session_id, "--json", "--channel", "no",
        "--timeout", "180", "--thinking", "low", "--verbose", "off",
        "--message", translate_prompt
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    stdout_text = result.stdout or ""
    ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
    cleaned_stdout = ansi_escape.sub('', stdout_text)
    decoder = JSONDecoder()

    for i in range(len(cleaned_stdout)):
        if cleaned_stdout[i] != '{' and cleaned_stdout[i] != '[':
            continue
        try:
            obj, _ = decoder.raw_decode(cleaned_stdout[i:])
            if isinstance(obj, dict) and "payloads" in obj and obj["payloads"]:
                txt = obj["payloads"][0].get("text", "")
                if isinstance(txt, str):
                    for j in range(len(txt)):
                        if txt[j] in "[{":
                            try:
                                arr, _ = decoder.raw_decode(txt[j:])
                                if isinstance(arr, list):
                                    return arr
                            except JSONDecodeError:
                                continue
            if isinstance(obj, list):
                return obj
        except JSONDecodeError:
            continue
    raise RuntimeError("Fallback translation returned no valid JSON array")


def calc_visual_length(text):
    if not text:
        return 0.0
    total = 0.0
    for ch in str(text):
        code = ord(ch)
        if ch.isspace():
            total += 0.32
        elif (
            0x4E00 <= code <= 0x9FFF
            or 0x3400 <= code <= 0x4DBF
            or 0x3000 <= code <= 0x303F
            or 0xFF00 <= code <= 0xFFEF
            or unicodedata.east_asian_width(ch) in {"F", "W"}
        ):
            total += 1.0
        elif "A" <= ch <= "Z":
            total += 0.72
        elif "a" <= ch <= "z":
            total += 0.62
        elif "0" <= ch <= "9":
            total += 0.58
        elif ch in string.punctuation:
            total += 0.35
        else:
            total += 0.70
    return round(total, 2)


def smart_truncate_by_visual_length(text, max_visual_len):
    if max_visual_len <= 0:
        return ""
    out = []
    acc = 0.0
    for ch in str(text):
        w = calc_visual_length(ch)
        if acc + w > max_visual_len:
            break
        out.append(ch)
        acc += w
    return "".join(out).rstrip()


def compress_item_to_visual_limits(title, summary):
    """LLM-first compression, then caller applies visual-length fallback truncation."""
    prompt = f"""你是中文科技编辑。请压缩下面文案并输出 JSON。

硬约束：
1) 仅输出 JSON：{{"title":"...","summary":"..."}}
2) title 与 summary 按视觉宽度尽量紧凑
3) summary 不能复述 title，需补充新信息
4) 目标：title_visual_len<=22, summary_visual_len<=34, combined<=52
5) 简体中文输出（专有名词可保留英文）

输入：
title: {title}
summary: {summary}
"""
    isolated_session_id = f"isolated-{uuid.uuid4().hex[:12]}"
    cmd = [
        "openclaw", "agent", "--session-id", isolated_session_id, "--json", "--channel", "no",
        "--timeout", "120", "--thinking", "low", "--verbose", "off",
        "--message", prompt
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    text = (result.stdout or "") + "\n" + (result.stderr or "")
    ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
    cleaned = ansi_escape.sub('', text)
    decoder = JSONDecoder()

    # Try direct JSON objects from the stream.
    for i in range(len(cleaned)):
        if cleaned[i] != '{':
            continue
        try:
            obj, _ = decoder.raw_decode(cleaned[i:])
        except JSONDecodeError:
            continue
        if isinstance(obj, dict) and "title" in obj and "summary" in obj:
            return str(obj["title"]).strip(), str(obj["summary"]).strip()
        if isinstance(obj, dict) and "payloads" in obj and obj["payloads"]:
            payload_text = obj["payloads"][0].get("text", "")
            if isinstance(payload_text, str):
                for j in range(len(payload_text)):
                    if payload_text[j] != '{':
                        continue
                    try:
                        inner, _ = decoder.raw_decode(payload_text[j:])
                    except JSONDecodeError:
                        continue
                    if isinstance(inner, dict) and "title" in inner and "summary" in inner:
                        return str(inner["title"]).strip(), str(inner["summary"]).strip()
    return title, summary


def enforce_visual_limits(title, summary):
    """Enforce visual weighted limits with fallback truncation order."""
    was_trimmed = False
    title = re.sub(r"\s+", " ", str(title)).strip()
    summary = re.sub(r"\s+", " ", str(summary)).strip()

    # Hard character limits requested by workflow.
    if len(title) > TITLE_MAX_CHARS:
        title = title[:TITLE_MAX_CHARS]
        was_trimmed = True
    if len(summary) > SUMMARY_MAX_CHARS:
        summary = summary[:SUMMARY_MAX_CHARS]
        was_trimmed = True

    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    c_len = round(t_len + s_len, 2)

    # First truncate summary.
    if s_len > 34 or c_len > 52:
        allowed_summary = min(34, 52 - t_len)
        summary = smart_truncate_by_visual_length(summary, allowed_summary)
        was_trimmed = True

    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    c_len = round(t_len + s_len, 2)

    # Then truncate title.
    if t_len > 22 or c_len > 52:
        allowed_title = min(22, 52 - s_len)
        title = smart_truncate_by_visual_length(title, allowed_title)
        was_trimmed = True

    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    c_len = round(t_len + s_len, 2)
    ok = bool(
        title
        and summary
        and len(title) <= TITLE_MAX_CHARS
        and len(summary) <= SUMMARY_MAX_CHARS
        and t_len <= 22
        and s_len <= 34
        and c_len <= 52
    )
    return title, summary, t_len, s_len, c_len, was_trimmed, ok

# Load candidates
with open(candidate_json_file, 'r', encoding='utf-8') as f:
    candidates = json.load(f)

prompt = f"""你是「AI 每日资讯编辑」，负责从候选新闻中筛选 Top5，并生成用于海报展示的结构化内容。

========================
【核心任务】
========================
从候选新闻中选择最重要的 5 条，并输出 JSON：

{{
  "date": "YYYY.MM.DD",
  "template": "a/b/c",
  "items": [
    {{
      "title": "...",
      "summary": "..."
    }}
  ]
}}

========================
【标题与摘要 强制分工规则】
========================

【title（标题）】
- 用一句话说明“谁 + 做了什么 / 发生了什么”
- 只描述事件本身
- 不写分析、不写意义、不写评价
- 视觉加权长度目标：title_visual_len <= 22

【summary（摘要）】
summary 不是摘要，而是“标题之外的补充信息句”

必须满足：
1. 不能复述 title（禁止同义改写 / 扩写 / 换词重复）
2. 必须提供“标题中没有的新信息”
3. 优先补充：
   - 行业影响
   - 背后原因
   - 商业意义
   - 关键数字
   - 未来趋势
4. 必须让读者“多获得一层信息”

========================
【严格禁止（违反即重写）】
========================

以下情况一律视为不合格：

- 用不同说法重复标题
- “某公司宣布...，该公司表示...”（结构重复）
- summary 只是 title 的扩写
- summary 和 title 主语 + 动作一致
- 没有新增信息

========================
【自检机制（必须执行）】
========================

对每一条数据生成后，执行检查：

1. summary 是否只是 title 改写？ → 是 → 重写
2. summary 是否提供新信息？ → 否 → 重写
3. 删除 summary 后是否信息损失？ → 否 → 重写

不允许输出未通过自检的内容。

========================
【模板选择规则】
========================

根据新闻整体风格选择：
- a：偏政策 / 宏观
- b：偏公司 / 产品（默认）
- c：偏技术 / 科研

========================
【输出要求】
========================

1. 仅输出 JSON
2. 不要解释
3. 不要附加任何说明
4. 不要出现 ``` 或 markdown
5. items 必须为 5 条
6. title 和 summary 必须为简体中文（专有名词可保留英文）
7. 视觉加权长度目标：
   - title_visual_len <= 22
   - summary_visual_len <= 34
   - title_visual_len + summary_visual_len <= 52

========================
【候选新闻】
========================
{json.dumps(candidates, ensure_ascii=False, indent=2)}
"""
# Generate a unique session ID for an isolated session
isolated_session_id = f"isolated-{uuid.uuid4().hex[:12]}"
cmd = [
    "openclaw", "agent", "--session-id", isolated_session_id, "--json", "--channel", "no",
    "--timeout", "180", "--thinking", "low", "--verbose", "off",
    "--message", prompt
]
print(f"DEBUG: Using isolated session: {isolated_session_id}")

result = subprocess.run(cmd, capture_output=True, text=True)
stdout_text = result.stdout or ""
stderr_text = result.stderr or ""

# Remove ANSI control codes
ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
cleaned_stdout = ansi_escape.sub('', stdout_text)

# Filter out plugin registration logs and other non-JSON lines
lines = cleaned_stdout.splitlines()
filtered_lines = []
for line in lines:
    # Skip lines that look like plugin logs or system messages
    if line.strip().startswith('[plugins]') or line.strip().startswith('Process still running') or line.strip().startswith('[diagnostic]'):
        continue
    filtered_lines.append(line)
filtered_stdout = '\n'.join(filtered_lines)

# Try to parse JSON envelope using raw_decode to find first valid JSON object
decoder = JSONDecoder()
envelope = None
payload_text = ""

# Scan for JSON objects (prefer scanning from the end to find the actual JSON result)
found_envelope = False
# Strategy 1: Scan from the end to find the last JSON object (usually the actual result)
for i in range(len(filtered_stdout) - 1, -1, -1):
    if filtered_stdout[i] == '{':
        try:
            candidate, idx = decoder.raw_decode(filtered_stdout[i:])
            # Priority 1: Envelope with payloads
            if isinstance(candidate, dict) and "payloads" in candidate:
                envelope = candidate
                found_envelope = True
                break
            # Priority 2: Direct result with top5 and daily_brief
            elif isinstance(candidate, dict) and "top5" in candidate and "daily_brief" in candidate:
                envelope = candidate
                found_envelope = True
                break
            # Priority 3: Direct result with date/template/items
            elif isinstance(candidate, dict) and "items" in candidate and "template" in candidate:
                envelope = candidate
                found_envelope = True
                break
        except JSONDecodeError:
            continue

# Strategy 2: If not found from end, scan from start (fallback)
if not found_envelope:
    for i in range(len(filtered_stdout)):
        if filtered_stdout[i] == '{':
            try:
                candidate, idx = decoder.raw_decode(filtered_stdout[i:])
                # Priority 1: Envelope with payloads
                if isinstance(candidate, dict) and "payloads" in candidate:
                    envelope = candidate
                    found_envelope = True
                    break
                # Priority 2: Direct result with top5 and daily_brief
                elif isinstance(candidate, dict) and "top5" in candidate and "daily_brief" in candidate:
                    envelope = candidate
                    found_envelope = True
                    break
                # Priority 3: Direct result with date/template/items
                elif isinstance(candidate, dict) and "items" in candidate and "template" in candidate:
                    envelope = candidate
                    found_envelope = True
                    break
            except JSONDecodeError:
                continue

if not found_envelope:
    raise RuntimeError(f"No valid JSON object (envelope or direct result) found in LLM response. filtered_stdout preview: {filtered_stdout[:500] if filtered_stdout else 'EMPTY'}")

# Extract payload_text from envelope
if "payloads" in envelope and len(envelope["payloads"]) > 0:
    payload_text = envelope["payloads"][0].get("text", "")
    # If payload_text is a string that looks like a JSON string (quoted), try to decode it
    if isinstance(payload_text, str) and payload_text.startswith('"') and payload_text.endswith('"'):
        try:
            payload_text = json.loads(payload_text)
        except JSONDecodeError:
            pass
elif "top5" in envelope and "daily_brief" in envelope:
    # Direct result, use envelope as llm_result
    llm_result = envelope
    payload_text = "" # Not needed
elif "items" in envelope and "template" in envelope:
    # Direct result in simplified schema
    llm_result = envelope
    payload_text = "" # Not needed
else:
    raise RuntimeError(f"Unexpected envelope structure: {list(envelope.keys())}")

# Parse payload_text if not direct result
if payload_text:
    if isinstance(payload_text, dict):
        llm_result = payload_text
    elif isinstance(payload_text, str):
        # Try to find JSON object in payload_text (in case it's wrapped in noise)
        llm_result = None
        for i in range(len(payload_text)):
            if payload_text[i] == '{':
                try:
                    llm_result, idx = decoder.raw_decode(payload_text[i:])
                    break
                except JSONDecodeError:
                    continue
        if llm_result is None:
            raise RuntimeError(f"No valid JSON object found in payload_text. Preview: {payload_text[:500]}")
    else:
        raise RuntimeError(f"Unexpected payload_text type: {type(payload_text)}")
else:
    # Already set llm_result in direct result branch
    pass

# Validate and normalize
# Support both schemas:
# 1) {"top5": [...], "daily_brief": {...}}
# 2) {"date": "...", "template": "...", "items": [...]}
if "top5" in llm_result and "daily_brief" in llm_result:
    top5 = llm_result["top5"]
    daily_brief = llm_result["daily_brief"]
elif "items" in llm_result and "template" in llm_result:
    top5 = llm_result["items"]
    daily_brief = {
        "date": llm_result.get("date", date_str),
        "template": llm_result.get("template", "b"),
        "items": llm_result["items"],
    }
else:
    raise RuntimeError(f"Missing required keys in LLM response. Keys: {list(llm_result.keys())}")

# Validate top5
if not isinstance(top5, list):
    raise RuntimeError(f"top5 is not a list: {type(top5)}")
if len(top5) != 5:
    raise RuntimeError(f"Expected 5 items in top5, got {len(top5)}")

# Validate and normalize items
items = []
for i, item in enumerate(top5):
    if not isinstance(item, dict):
        raise RuntimeError(f"top5 item {i} is not a dict: {type(item)}")
    
    title = item.get("short_title", "").strip()
    summary = item.get("short_summary", "").strip()
    
    # Fallback logic with FORCE fill
    if not title:
        title = item.get("title", "").strip()
    # Force title: if still empty, use ID as placeholder (should not happen)
    if not title:
        title = f"News {i+1}"
    
    if not summary:
        summary = item.get("summary", "").strip()
    if not summary:
        summary = item.get("summary_cn", "").strip()
    # FORCE fill summary: if still empty, use a generic placeholder
    if not summary:
        summary = "AI 行业最新动态，请关注后续更新。"
    
    title = re.sub(r"\s+", " ", title).strip()
    summary = re.sub(r"\s+", " ", summary).strip()

    # LLM-first compression, then visual fallback truncation.
    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    c_len = round(t_len + s_len, 2)
    if t_len > 22 or s_len > 34 or c_len > 52:
        title, summary = compress_item_to_visual_limits(title, summary)
        title = re.sub(r"\s+", " ", title).strip()
        summary = re.sub(r"\s+", " ", summary).strip()

    orig_title = title
    orig_summary = summary
    orig_t_len = calc_visual_length(orig_title)
    orig_s_len = calc_visual_length(orig_summary)
    orig_c_len = round(orig_t_len + orig_s_len, 2)
    title, summary, t_len, s_len, c_len, was_trimmed, ok = enforce_visual_limits(title, summary)
    print(
        f"VISUAL_CHECK item={i+1} "
        f"orig_title={orig_title!r} orig_summary={orig_summary!r} "
        f"orig_title_visual_len={orig_t_len} orig_summary_visual_len={orig_s_len} orig_combined_visual_len={orig_c_len} "
        f"trimmed={was_trimmed} "
        f"final_title={title!r} final_summary={summary!r} "
        f"title_visual_len={t_len} summary_visual_len={s_len} combined_visual_len={c_len}"
    )
    if not ok:
        raise RuntimeError(
            f"Visual length validation failed for item {i+1}: "
            f"title={t_len}, summary={s_len}, combined={c_len}"
        )
    
    # Final check: ensure non-empty
    if not title or not summary:
        raise RuntimeError(f"top5 item {i} has empty title/summary after force fill: title='{title}', summary='{summary}'")
    
    items.append({
        "title": title,
        "summary": summary
    })

# Ensure daily_brief structure
daily_brief["date"] = date_str
template = str(daily_brief.get("template", "b")).strip().lower()
if template not in ["a", "b", "c"]:
    template = "b"
daily_brief["template"] = template
daily_brief["items"] = items

if len(daily_brief["items"]) != 5:
    raise RuntimeError(f"Final items count mismatch: {len(daily_brief['items'])}")

# Chinese fallback: force all items into Chinese if LLM returned English lines.
if needs_cn_fallback(daily_brief["items"]):
    translated_items = fallback_translate_to_cn(daily_brief["items"])
    if not isinstance(translated_items, list) or len(translated_items) != 5:
        raise RuntimeError("Fallback translation failed: items count is not 5")
    normalized = []
    for i, item in enumerate(translated_items):
        if not isinstance(item, dict):
            raise RuntimeError(f"Fallback translation item {i} is not dict")
        title = re.sub(r"\s+", " ", str(item.get("title", ""))).strip()
        summary = re.sub(r"\s+", " ", str(item.get("summary", ""))).strip()
        t_len = calc_visual_length(title)
        s_len = calc_visual_length(summary)
        c_len = round(t_len + s_len, 2)
        if t_len > 22 or s_len > 34 or c_len > 52:
            title, summary = compress_item_to_visual_limits(title, summary)
            title = re.sub(r"\s+", " ", title).strip()
            summary = re.sub(r"\s+", " ", summary).strip()
        orig_title = title
        orig_summary = summary
        orig_t_len = calc_visual_length(orig_title)
        orig_s_len = calc_visual_length(orig_summary)
        orig_c_len = round(orig_t_len + orig_s_len, 2)
        title, summary, t_len, s_len, c_len, was_trimmed, ok = enforce_visual_limits(title, summary)
        print(
            f"VISUAL_CHECK_FALLBACK item={i+1} "
            f"orig_title={orig_title!r} orig_summary={orig_summary!r} "
            f"orig_title_visual_len={orig_t_len} orig_summary_visual_len={orig_s_len} orig_combined_visual_len={orig_c_len} "
            f"trimmed={was_trimmed} "
            f"final_title={title!r} final_summary={summary!r} "
            f"title_visual_len={t_len} summary_visual_len={s_len} combined_visual_len={c_len}"
        )
        if not ok:
            raise RuntimeError(
                f"Visual length validation failed in fallback item {i+1}: "
                f"title={t_len}, summary={s_len}, combined={c_len}"
            )
        if not title or not summary:
            raise RuntimeError(f"Fallback translation item {i} empty title/summary")
        if not has_chinese(title) or not has_chinese(summary):
            raise RuntimeError(f"Fallback translation item {i} still not Chinese")
        normalized.append({"title": title, "summary": summary})

    daily_brief["items"] = normalized
    top5 = normalized

# Write output files
with open(top5_json_file, "w", encoding="utf-8") as f:
    json.dump(top5, f, ensure_ascii=False, indent=2)
with open(json_file, "w", encoding="utf-8") as f:
    json.dump(daily_brief, f, ensure_ascii=False, indent=2)

print(f"Generated Top5 JSON: {top5_json_file}")
print(f"Generated daily_brief: {json_file}")
PYEOF
    PY_EXIT_CODE=$?
    set -e

    if [ $PY_EXIT_CODE -ne 0 ] || [ ! -f "$TOP5_JSON_FILE" ] || [ ! -f "$JSON_FILE" ]; then
        ERROR_MSG="Top5 JSON generation failed (exit: $PY_EXIT_CODE, files missing)"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi
    log_step_ok "$CURRENT_STEP"

    # Step 4: Refine overflowing summaries (best-effort; never blocks rendering)
    CURRENT_STEP="[4/8] Refining long summaries"
    log_step_start "$CURRENT_STEP"

    set +e
    REFINER_OUTPUT=$(python3 "$SUMMARY_REFINER_DIR/scripts/refine_summaries.py" \
        --brief "$JSON_FILE" \
        --project-root "$SKILL_DIR" \
        --max-retries-per-item 5 2>&1)
    REFINER_CODE=$?
    set -e

    if [ $REFINER_CODE -ne 0 ]; then
        log "WARNING: Summary refiner failed (non-blocking). Continue rendering. details: $REFINER_OUTPUT"
    else
        log "Summary refiner result: $REFINER_OUTPUT"
    fi
    log_step_ok "$CURRENT_STEP"

    # Step 5: Render Poster
    CURRENT_STEP="[5/8] Rendering poster"
    log_step_start "$CURRENT_STEP"

    cd "$SKILL_DIR"
    set +e
    OUTPUT=$(python3 scripts/openclaw_render.py --input "$JSON_FILE" 2>&1)
    RENDER_CODE=$?
    set -e

    if [ $RENDER_CODE -ne 0 ] || ! echo "$OUTPUT" | grep -q "MEDIA:"; then
        ERROR_MSG="Render failed (exit: $RENDER_CODE): $OUTPUT"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi

    IMAGE_PATH=$(echo "$OUTPUT" | grep "MEDIA:" | sed 's/MEDIA://')
    if [ ! -f "$IMAGE_PATH" ]; then
        ERROR_MSG="Image file not found: $IMAGE_PATH"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi

    log_step_ok "$CURRENT_STEP"
    log "Poster generated: $IMAGE_PATH"
# Ensure final poster is placed at the unified output location with a stable name
if [ -f "$IMAGE_PATH" ]; then
    cp -f "$IMAGE_PATH" "$OUTPUT_DIR/poster.png"
    IMAGE_PATH="$OUTPUT_DIR/poster.png"
    log "Poster copied to unified path: $IMAGE_PATH"
fi

    # Step 6: Generate Voiceover Script
    CURRENT_STEP="[6/8] Generating voiceover script"
    log_step_start "$CURRENT_STEP"

    # Ensure DATE_STR is in Chinese full-date format (cross-platform: macOS/Linux).
    export DATE_STR="$(python3 - <<'PY'
import os
import re
from datetime import datetime

raw = os.environ.get("DATE_STR", "").strip()
m = re.match(r"^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})$", raw)
if m:
    y, mo, d = map(int, m.groups())
    print(f"{y}年{mo}月{d}日")
else:
    try:
        dt = datetime.now()
        print(f"{dt.year}年{dt.month}月{dt.day}日")
    except Exception:
        print(raw)
PY
)"
    export TOP5_JSON_FILE VOICEOVER_SCRIPT_FILE
    set +e
    python3 "$WORKSPACE/scripts/generate_voiceover.py"
    VOICEOVER_CODE=$?
    set -e

    if [ $VOICEOVER_CODE -ne 0 ] || [ ! -f "$VOICEOVER_SCRIPT_FILE" ]; then
        ERROR_MSG="Voiceover generation failed (exit: $VOICEOVER_CODE)"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi

    log_step_ok "$CURRENT_STEP"
    log "Voiceover script generated: $VOICEOVER_SCRIPT_FILE"

    # Step 7: Prepare Message Content
    CURRENT_STEP="[7/8] Preparing message content"
    log_step_start "$CURRENT_STEP"

    VOICEOVER_TEXT=$(cat "$VOICEOVER_SCRIPT_FILE")

    cat > "$SEND_SUMMARY_FILE" <<VOICEOVER_EOF
AI 每日资讯｜$DATE_STR

$VOICEOVER_TEXT
VOICEOVER_EOF

    log_step_ok "$CURRENT_STEP"

    # Step 8: Send to Feishu
    CURRENT_STEP="[8/8] Sending to Feishu"
    log_step_start "$CURRENT_STEP"

    SENT_AT=$(TZ="Asia/Shanghai" date +"%Y-%m-%d %H:%M:%S")

    # 8.1 Send image first with retry, then send text.
    FEISHU_IMAGE_CODE=1
    IMAGE_SEND_MAX_RETRIES=3
    IMAGE_SEND_ATTEMPT=1
    while [ $IMAGE_SEND_ATTEMPT -le $IMAGE_SEND_MAX_RETRIES ]; do
        log "Feishu image send attempt ${IMAGE_SEND_ATTEMPT}/${IMAGE_SEND_MAX_RETRIES}"
        set +e
        openclaw message send \
            --channel feishu \
            --target "$TARGET_USER" \
            --message "AI 每日资讯｜$DATE_STR" \
            --media "$IMAGE_PATH"
        FEISHU_IMAGE_CODE=$?
        set -e

        if [ $FEISHU_IMAGE_CODE -eq 0 ]; then
            break
        fi

        if [ $IMAGE_SEND_ATTEMPT -lt $IMAGE_SEND_MAX_RETRIES ]; then
            sleep $((IMAGE_SEND_ATTEMPT * 2))
        fi
        IMAGE_SEND_ATTEMPT=$((IMAGE_SEND_ATTEMPT + 1))
    done

    if [ $FEISHU_IMAGE_CODE -ne 0 ]; then
        ERROR_MSG="Feishu image send failed after ${IMAGE_SEND_MAX_RETRIES} attempts (exit: $FEISHU_IMAGE_CODE)"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi

    set +e
    openclaw message send \
        --channel feishu \
        --target "$TARGET_USER" \
        --message "AI 每日资讯｜$DATE_STR\n\n$VOICEOVER_TEXT"
    FEISHU_TEXT_CODE=$?
    set -e

    if [ $FEISHU_TEXT_CODE -ne 0 ]; then
        ERROR_MSG="Feishu text send failed (exit: $FEISHU_TEXT_CODE)"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi

    log_step_ok "$CURRENT_STEP"
    log "=== SUCCESS ==="
    log "Sent to: $TARGET_USER"
    log "Poster: $IMAGE_PATH"
    log "Voiceover: $VOICEOVER_SCRIPT_FILE"
    log "Run ID: $RUN_ID"
    exit 0
done

# All retries failed
log "=== FAILED ==="
log "Final error: $ERROR_MSG"

# Send failure notification (robust: do not fail if notification fails)
set +e
openclaw message send \
    --channel feishu \
    --target "$TARGET_USER" \
    --message "❌ AI 每日资讯增强版任务失败\n📅 日期：$DATE_STR\n🔴 错误：$ERROR_MSG\n📝 日志：$RUN_LOG_FILE"
NOTIFY_CODE=$?
set -e

if [ $NOTIFY_CODE -ne 0 ]; then
    log "WARNING: Failed to send failure notification (exit: $NOTIFY_CODE). Check logs manually."
else
    log "Failure notification sent."
fi

exit 1
