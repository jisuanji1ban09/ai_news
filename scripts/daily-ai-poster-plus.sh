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

# Noise filter: drop titles containing these keywords
NOISE_PATTERNS = re.compile(
    r'\b(bitcoin|crypto|cryptocurrency|ethereum|stock|stocks|nasdaq|s&p|'
    r'forex|etf|dividend|earnings report|quarterly result|'
    r'war|iran|military|missile|shooting|accident|weather)\b',
    re.IGNORECASE
)

# Must contain at least one AI-related keyword to pass
AI_REQUIRED = re.compile(
    r'\b(ai|artificial intelligence|machine learning|deep learning|llm|'
    r'openai|anthropic|google|microsoft|meta|nvidia|baidu|bytedance|'
    r'alibaba|tencent|huawei|deepseek|gemini|chatgpt|claude|gpt|'
    r'model|agent|chip|gpu|semiconductor|robot|autonomous)\b',
    re.IGNORECASE
)

def infer_source(url):
    if not url: return "Unknown"
    host = urlparse(url).netloc.lower().split(":")[0]
    if host.startswith("www."): host = host[4:]
    return host.split(".")[0].replace("-", " ").title() or "Unknown"

def infer_category(text):
    t = text.lower()
    china_corps = ["baidu", "bytedance", "alibaba", "tencent", "huawei",
                   "xiaomi", "zhipu", "moonshot", "deepseek", "manus",
                   "wechat", "douyin", "kwai", "kuaishou", "iflytek"]
    if any(k in t for k in china_corps):
        return "china_ai"
    chip_primary = ["nvidia", "amd", "intel", "tsmc", "qualcomm",
                    "gpu", "tpu", "npu", "semiconductor", "chip",
                    "datacenter", "data center", "infrastructure",
                    "compute", "supercomputer"]
    if any(k in t for k in chip_primary):
        return "chip_infrastructure"
    funding_primary = ["funding", "raised", "raises", "series a", "series b",
                       "series c", "ipo", "acquisition", "acquires", "acquired",
                       "merger", "valuation", "invest", "venture"]
    if any(k in t for k in funding_primary):
        return "funding_mna"
    policy_primary = ["regulation", "regulator", "regulatory", "legislat",
                      "congress", "senate", "parliament", "government order",
                      "executive order", "ban", "banned", "lawsuit",
                      "antitrust", "gdpr", "compliance"]
    product_signal = ["launch", "release", "model", "product", "feature",
                      "update", "version", "deploy", "agent"]
    has_policy = any(k in t for k in policy_primary)
    has_product = any(k in t for k in product_signal)
    if has_policy and not has_product:
        return "regulation_policy"
    bigtech_corps = ["openai", "google", "anthropic", "microsoft", "meta",
                     "amazon", "apple", "tesla", "sam altman", "elon musk",
                     "sundar pichai", "satya nadella", "jensen huang"]
    if any(k in t for k in bigtech_corps):
        return "bigtech"
    return "general_ai"

def title_fingerprint(title):
    t = re.sub(r'\s*[-|:]\s*[A-Za-z0-9 \.]+$', '', title).strip()
    t = t.lower()
    t = re.sub(r'[^\w\s]', '', t)
    t = re.sub(r'\s+', ' ', t).strip()
    return frozenset(t.split())

def jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)

CATEGORY_BONUS = {
    "bigtech": 8,
    "china_ai": 7,
    "chip_infrastructure": 6,
    "funding_mna": 4,
    "regulation_policy": 4,
    "general_ai": 0,
}

# Parse all raw items
raw_items = []
i = 0
lines = raw_text.splitlines()
while i < len(lines):
    line = lines[i].strip()
    m = title_re.match(line)
    if not m:
        i += 1
        continue
    title = m.group(1).strip()
    relevance = int(m.group(2)) if m.group(2) else None
    url = ""
    summary = ""
    i += 1
    while i < len(lines):
        cur = lines[i].strip()
        if not cur or title_re.match(cur):
            break
        if url_re.match(cur):
            if not url:
                url = cur
        else:
            summary += " " + cur
        i += 1
    if len(summary) > 200:
        summary = summary[:197] + "..."
    raw_items.append({
        "title": title,
        "url": url,
        "summary": summary.strip(),
        "relevance": relevance,
    })

# Filter noise and non-AI content
filtered = []
for item in raw_items:
    combined = item["title"] + " " + item["summary"]
    if NOISE_PATTERNS.search(combined):
        continue
    if not AI_REQUIRED.search(combined):
        continue
    filtered.append(item)

# Dedup: URL-exact first, then near-duplicate title (Jaccard >= 0.65)
seen_urls = set()
seen_fingerprints = []
deduped = []
for item in filtered:
    url = item["url"]
    if url and url in seen_urls:
        continue
    fp = title_fingerprint(item["title"])
    is_dup = any(jaccard(fp, ex) >= 0.65 for ex in seen_fingerprints)
    if is_dup:
        continue
    if url:
        seen_urls.add(url)
    seen_fingerprints.append(fp)
    deduped.append(item)

# Score, sort and cap at 20
candidates = []
for item in deduped[:20]:
    combined = item["title"] + " " + item["summary"]
    category = infer_category(combined)
    base = 60 + (item["relevance"] * 0.35 if item["relevance"] is not None else 0)
    score = round(base + CATEGORY_BONUS.get(category, 0), 2)
    candidates.append({
        "id": str(len(candidates) + 1),
        "title": item["title"],
        "source": infer_source(item["url"]),
        "url": item["url"],
        "summary_cn": item["summary"],
        "category": category,
        "importance_score": score,
    })

candidates.sort(key=lambda x: x["importance_score"], reverse=True)
for idx, c in enumerate(candidates):
    c["id"] = str(idx + 1)

with open(output_json, "w", encoding="utf-8") as f:
    json.dump(candidates, f, ensure_ascii=False, indent=2)

category_counts = {}
for c in candidates:
    cat = c["category"]
    category_counts[cat] = category_counts.get(cat, 0) + 1
print(f"Parsed {len(candidates)} candidates after filter+dedup")
print(f"Category breakdown: {category_counts}")
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
    CURRENT_STEP="[3/8] Generating Top5 JSON"
    log_step_start "$CURRENT_STEP"

    export DATE_STR JSON_FILE CANDIDATE_JSON_FILE TOP5_JSON_FILE
    export BAILIAN_API_KEY BAILIAN_MODEL BAILIAN_BASE_URL
    export DATA_DIR RUN_ID

    set +e
    python3 <<'PYEOF'
import json
import os
import re
import string
import sys
import unicodedata
import urllib.request
import urllib.error
from json import JSONDecoder, JSONDecodeError

# ── 环境变量 ──────────────────────────────────────────────────
date_str          = os.environ.get("DATE_STR", "")
json_file         = os.environ.get("JSON_FILE", "")
candidate_json_file = os.environ.get("CANDIDATE_JSON_FILE", "")
top5_json_file    = os.environ.get("TOP5_JSON_FILE", "")
data_dir          = os.environ.get("DATA_DIR", "")
run_id            = os.environ.get("RUN_ID", "unknown")

api_key   = os.environ.get("BAILIAN_API_KEY") or \
            os.environ.get("DASHSCOPE_API_KEY") or \
            os.environ.get("ALIYUN_BAILIAN_API_KEY", "")
model     = os.environ.get("BAILIAN_MODEL", "qwen-plus")
api_url   = os.environ.get("BAILIAN_BASE_URL",
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
curl_timeout = int(os.environ.get("CURL_MAX_TIME", "180"))

TITLE_MAX_CHARS   = 22
SUMMARY_MAX_CHARS = 34

if not api_key:
    print("ERROR: 未找到百炼 API Key（BAILIAN_API_KEY / DASHSCOPE_API_KEY）",
          file=sys.stderr)
    sys.exit(1)

# ── 工具函数 ──────────────────────────────────────────────────
def clean_text(text: str) -> str:
    s = str(text or "")
    s = re.sub(r"https?://\S+", "", s)
    s = re.sub(r"[#*_`]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s.strip(" .,:;|/-_")

def calc_visual_length(text: str) -> float:
    total = 0.0
    for ch in str(text or ""):
        code = ord(ch)
        if ch.isspace():
            total += 0.32
        elif (0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF
              or 0x3000 <= code <= 0x303F or 0xFF00 <= code <= 0xFFEF
              or unicodedata.east_asian_width(ch) in {"F", "W"}):
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

def smart_truncate(text: str, max_vlen: float) -> str:
    out, acc = [], 0.0
    for ch in str(text or ""):
        w = calc_visual_length(ch)
        if acc + w > max_vlen:
            break
        out.append(ch)
        acc += w
    return "".join(out).rstrip()

def enforce_visual_limits(title: str, summary: str):
    title   = clean_text(title)
    summary = clean_text(summary)
    # 如果 summary 以 title 开头则去重
    if summary.startswith(title):
        summary = clean_text(summary[len(title):])
    if len(title)   > TITLE_MAX_CHARS:   title   = title[:TITLE_MAX_CHARS]
    if len(summary) > SUMMARY_MAX_CHARS: summary = summary[:SUMMARY_MAX_CHARS]
    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    if s_len > 34 or (t_len + s_len) > 52:
        summary = smart_truncate(summary, min(34, 52 - t_len))
    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    if t_len > 22 or (t_len + s_len) > 52:
        title = smart_truncate(title, min(22, 52 - s_len))
    return clean_text(title), clean_text(summary)

def extract_first_json(text: str):
    cleaned = re.sub(r"^```json\s*", "", text.strip(), flags=re.I)
    cleaned = re.sub(r"^```\s*",    "", cleaned,       flags=re.I)
    cleaned = re.sub(r"\s*```$",    "", cleaned)
    decoder = JSONDecoder()
    for i, ch in enumerate(cleaned):
        if ch not in "[{":
            continue
        try:
            obj, _ = decoder.raw_decode(cleaned[i:])
            return obj
        except JSONDecodeError:
            continue
    return None

def call_llm(prompt: str, step_label: str) -> dict:
    """调用百炼 OpenAI 兼容接口，返回解析后的 JSON dict。"""
    body = {
        "model": model,
        "messages": [
            {"role": "system",
             "content": "你是严谨的中文科技新闻编辑助手。所有输出必须是合法 JSON。"},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.2,
        "seed": 42,
        "stream": False,
        "response_format": {"type": "json_object"},
    }
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        api_url,
        data=body_bytes,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type":  "application/json",
        },
        method="POST",
    )
    # 落盘 prompt 供调试
    if data_dir:
        prompt_path = os.path.join(data_dir, f"step3_{step_label}_{run_id}.prompt.txt")
        with open(prompt_path, "w", encoding="utf-8") as f:
            f.write(prompt)

    try:
        with urllib.request.urlopen(req, timeout=curl_timeout) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body_err = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"百炼接口 HTTP {e.code}：{body_err[:500]}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"百炼接口连接失败：{e.reason}")

    # 落盘原始响应供调试
    if data_dir:
        resp_path = os.path.join(data_dir, f"step3_{step_label}_{run_id}.response.json")
        with open(resp_path, "w", encoding="utf-8") as f:
            f.write(raw)

    payload = json.loads(raw)
    content = (payload.get("choices", [{}])[0]
                      .get("message", {})
                      .get("content", ""))
    obj = extract_first_json(content)
    if obj is None:
        raise RuntimeError(
            f"[{step_label}] 模型返回中未找到合法 JSON。"
            f"内容预览：{content[:400]}"
        )
    return obj

# ── 读取候选 ──────────────────────────────────────────────────
with open(candidate_json_file, "r", encoding="utf-8") as f:
    candidates = json.load(f)

# 清洗 summary_cn 里的 markdown 噪声
for c in candidates:
    c["summary_cn"] = clean_text(c.get("summary_cn", ""))

# ── Sub-step A：LLM 选出 Top5（只返回 id）────────────────────
view_for_select = [
    {
        "id":            c["id"],
        "title":         c["title"],
        "source":        c["source"],
        "rank_score":    c["importance_score"],
        "category":      c["category"],
        "content":       c["summary_cn"],
    }
    for c in candidates
]

prompt_select = f"""请从下面的 AI 新闻候选中选出 Top5，并以 JSON 输出。

要求：
1. 只做选择，不翻译，不生成 title，不生成 summary。
2. 优先选择 rank_score 高、category 多样、信息完整的新闻。
3. 尽量覆盖以下类别（有则选，无则跳过）：
   bigtech、china_ai、chip_infrastructure、funding_mna、regulation_policy
4. 同一事件只选一条，不重复。
5. 输出必须是 JSON，不要 markdown，不要解释。
6. 输出格式：
{{
  "items": [
    {{"id": "1"}},
    {{"id": "2"}},
    {{"id": "3"}},
    {{"id": "4"}},
    {{"id": "5"}}
  ]
}}

候选新闻（共 {len(view_for_select)} 条）：
{json.dumps(view_for_select, ensure_ascii=False, indent=2)}
"""

result_select = call_llm(prompt_select, "A_select")
selected_ids = [str(row.get("id", "")) for row in result_select.get("items", [])]
if len(selected_ids) != 5:
    raise RuntimeError(f"Sub-step A：LLM 返回 {len(selected_ids)} 条，需要 5 条")

cand_map = {str(c["id"]): c for c in candidates}
top5_en = []
seen = set()
for sid in selected_ids:
    if sid in cand_map and sid not in seen:
        top5_en.append(cand_map[sid])
        seen.add(sid)
if len(top5_en) != 5:
    raise RuntimeError(f"Sub-step A：id 匹配后只得到 {len(top5_en)} 条")

print(f"Sub-step A OK: selected ids={selected_ids}")

# ── Sub-step B：LLM 翻译为中文事实稿 ─────────────────────────
view_for_translate = [
    {
        "id":       c["id"],
        "title_en": c["title"],
        "source":   c["source"],
        "content":  c["summary_cn"],
    }
    for c in top5_en
]

prompt_translate = f"""请将下面的 Top5 英文 AI 新闻翻译为中文标准事实稿，并以 JSON 输出。

要求：
1. 每条只生成一段中文标准事实稿，不生成 title，不生成 summary。
2. 中文表达自然、克制、资讯化。
3. 尽量保留关键事实：时间、公司、人物、金额、产品、动作、数字。
4. 不添加背景，不做评论，不延伸推断。
5. 输出必须是 JSON，不要 markdown，不要解释。
6. 输出格式：
{{
  "items": [
    {{"id": "1", "fact_cn": "..."}}
  ]
}}

输入：
{json.dumps(view_for_translate, ensure_ascii=False, indent=2)}
"""

result_translate = call_llm(prompt_translate, "B_translate")
facts_map = {str(item.get("id", "")): item.get("fact_cn", "")
             for item in result_translate.get("items", [])}
print(f"Sub-step B OK: translated {len(facts_map)} items")

# ── Sub-step C：LLM 校正事实稿 ───────────────────────────────
view_for_check = [
    {
        "id":       c["id"],
        "title_en": c["title"],
        "content_en": c["summary_cn"],
        "fact_cn":  facts_map.get(str(c["id"]), ""),
    }
    for c in top5_en
]

prompt_check = f"""请对下面的中文事实稿做事实校正，并以 JSON 输出。

要求：
1. 只校正事实完整性、措辞准确性、数字和主体是否遗漏。
2. 不扩写背景，不生成 title，不生成 summary。
3. 如原稿已经准确，可微调措辞，但不要明显改写主题。
4. 输出必须是 JSON，不要 markdown，不要解释。
5. 输出格式：
{{
  "items": [
    {{"id": "1", "fact_cn_checked": "..."}}
  ]
}}

输入：
{json.dumps(view_for_check, ensure_ascii=False, indent=2)}
"""

result_check = call_llm(prompt_check, "C_check")
checked_map = {str(item.get("id", "")): item.get("fact_cn_checked", "")
               for item in result_check.get("items", [])}
print(f"Sub-step C OK: checked {len(checked_map)} items")

# ── Sub-step D：LLM 生成 title 和 summary ────────────────────
view_for_title = [
    {
        "id":             c["id"],
        "fact_cn_checked": checked_map.get(str(c["id"]),
                           facts_map.get(str(c["id"]), "")),
    }
    for c in top5_en
]

prompt_title = f"""请基于下面校正后的中文事实稿，为每条新闻生成最终 title 和 summary，并以 JSON 输出。

要求：
1. title 与 summary 必须低重复，summary 必须补充 title 没有的新信息。
2. 中文表达自然、克制、资讯化。
3. title 必须点明主体，禁止使用"该公司""某公司""人工智能公司"等泛称。
4. title 不超过 22 个中文字符；summary 不超过 34 个中文字符。
5. title 和 summary 都必须是完整短句，不能出现残句。
6. 一条新闻只能表达一个主事件，不得并列混写两个信息点。
7. title 概括"谁做了什么"，summary 补充关键结果、数字或背景。
8. 不要照搬事实稿整句，不要写成评论句，不要使用夸张或判断性措辞。
9. 输出必须是 JSON，不要 markdown，不要解释。
10. 输出格式：
{{
  "items": [
    {{"id": "1", "title": "...", "summary": "..."}}
  ]
}}

输入：
{json.dumps(view_for_title, ensure_ascii=False, indent=2)}
"""

result_title = call_llm(prompt_title, "D_title")
title_items = result_title.get("items", [])
if len(title_items) != 5:
    raise RuntimeError(f"Sub-step D：返回 {len(title_items)} 条，需要 5 条")

print(f"Sub-step D OK: generated {len(title_items)} title+summary pairs")

# ── 最终拼装 ─────────────────────────────────────────────────
top5_map = {str(c["id"]): c for c in top5_en}
final_items  = []
brief_items  = []

for item in title_items:
    sid   = str(item.get("id", ""))
    title, summary = enforce_visual_limits(
        item.get("title", ""),
        item.get("summary", ""),
    )
    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    c_len = round(t_len + s_len, 2)
    print(f"VISUAL_CHECK id={sid} title_vlen={t_len} "
          f"summary_vlen={s_len} combined={c_len} "
          f"title={title!r} summary={summary!r}")
    if not title or not summary:
        raise RuntimeError(f"id={sid} title 或 summary 为空")
    src = top5_map.get(sid, {})
    final_items.append({
        "id":      sid,
        "title":   title,
        "summary": summary,
        "source":  src.get("source", ""),
        "url":     src.get("url", ""),
    })
    brief_items.append({"title": title, "summary": summary})

if len(final_items) != 5:
    raise RuntimeError(f"最终条目数量异常：{len(final_items)}")

# 写 top5.json
with open(top5_json_file, "w", encoding="utf-8") as f:
    json.dump(final_items, f, ensure_ascii=False, indent=2)

# 写 daily_brief.json
daily_brief = {
    "date":     date_str,
    "template": "b",
    "items":    brief_items,
}
with open(json_file, "w", encoding="utf-8") as f:
    json.dump(daily_brief, f, ensure_ascii=False, indent=2)

print(f"Step3 DONE: top5={top5_json_file}")
print(f"Step3 DONE: daily_brief={json_file}")
PYEOF
    PY_EXIT_CODE=$?
    set -e

    if [ $PY_EXIT_CODE -ne 0 ] || [ ! -f "$TOP5_JSON_FILE" ] || [ ! -f "$JSON_FILE" ]; then
        ERROR_MSG="Top5 JSON generation failed (exit: $PY_EXIT_CODE)"
        log_step_fail "$CURRENT_STEP" "$ERROR_MSG"
        continue
    fi
    log_step_ok "$CURRENT_STEP"

    # Step 4: Refine overflowing summaries (best-effort; never blocks rendering)
    exit 0
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
