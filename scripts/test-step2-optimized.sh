#!/bin/bash

# Step2 测试（百炼 5 步版）
# 目标：
# 1) 程序先做去重 + 基础排序 + 候选压缩，得到更干净的英文候选池。
# 2) LLM 从候选池中选 Top5。
# 3) LLM 将 Top5 翻译为中文标准事实稿。
# 4) LLM 对中文事实稿做校正。
# 5) LLM 生成最终 title 和 summary。
#
# 设计原则：
# - 不修改主流程，只提供 Step2 的独立测试入口。
# - 对每一步都落盘 prompt / request / response / parsed JSON，便于网页端对照调试。
# - 使用阿里云百炼 OpenAI 兼容接口：
#   POST https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions
# - 使用 response_format={"type":"json_object"} 强制结构化 JSON 输出。

set -Eeuo pipefail
IFS=$'\n\t'

log() {
  echo "[$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] $*"
}

trap 'code=$?; log "FATAL: line=$LINENO command=${BASH_COMMAND:-unknown} exit_code=$code"; exit $code' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$WORKSPACE/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$WORKSPACE/.env"
  set +a
fi

DATE_DIR="$(TZ='Asia/Shanghai' date '+%Y-%m-%d')"
RUN_TS="$(TZ='Asia/Shanghai' date '+%Y%m%d-%H%M%S')"
DATE_STR="$(TZ='Asia/Shanghai' date '+%Y.%m.%d')"

DATA_DIR="$WORKSPACE/ai_news/$DATE_DIR/data"
LOG_DIR="$WORKSPACE/ai_news/$DATE_DIR/logs"
LOG_FILE="$LOG_DIR/test-step2-${RUN_TS}.log"
mkdir -p "$DATA_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# 模型与接口配置。
# 优先读取 .env 里的百炼专用变量，便于直接在 .env 中动态切换。
MODEL_NAME="${BAILIAN_MODEL:-${MODEL_NAME:-qwen-plus}}"
API_URL="${BAILIAN_BASE_URL:-${API_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions}}"
CURL_MAX_TIME="${CURL_MAX_TIME:-180}"
MAX_CANDIDATES="${MAX_CANDIDATES:-15}"
CONTENT_LIMIT="${CONTENT_LIMIT:-320}"
STOP_AFTER_STEP="${STOP_AFTER_STEP:-0}"

# API Key 优先读取 .env 里的 BAILIAN_API_KEY，同时兼容旧变量名。
API_KEY="${BAILIAN_API_KEY:-${DASHSCOPE_API_KEY:-${ALIYUN_BAILIAN_API_KEY:-}}}"

INPUT_FILE="${1:-}"
if [ -z "$INPUT_FILE" ]; then
  INPUT_FILE="$(find "$WORKSPACE/ai_news" -type f -name 'step1_filtered_[0-9]*.json' | sort | tail -n 1 || true)"
fi

if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
  log "ERROR: 找不到 step1_filtered_[0-9]*.json，请先执行 Step1 测试。"
  exit 1
fi

CANDIDATES_FILE="$DATA_DIR/step2_candidates_${RUN_TS}.json"
TOP5_EN_FILE="$DATA_DIR/step2_top5_en_${RUN_TS}.json"
FACTS_FILE="$DATA_DIR/step2_facts_${RUN_TS}.json"
CHECKED_FILE="$DATA_DIR/step2_checked_${RUN_TS}.json"
TOP5_FILE="$DATA_DIR/step2_top5_${RUN_TS}.json"
BRIEF_FILE="$DATA_DIR/step2_daily_brief_${RUN_TS}.json"
REPORT_FILE="$DATA_DIR/step2_report_${RUN_TS}.txt"

STEP2_PROMPT_FILE="$DATA_DIR/step2_prompt2_select_${RUN_TS}.txt"
STEP2_REQUEST_FILE="$DATA_DIR/step2_prompt2_select_${RUN_TS}.request.json"
STEP2_RESPONSE_FILE="$DATA_DIR/step2_prompt2_select_${RUN_TS}.response.json"
STEP2_PARSED_FILE="$DATA_DIR/step2_prompt2_select_${RUN_TS}.parsed.json"

STEP3_PROMPT_FILE="$DATA_DIR/step2_prompt3_translate_${RUN_TS}.txt"
STEP3_REQUEST_FILE="$DATA_DIR/step2_prompt3_translate_${RUN_TS}.request.json"
STEP3_RESPONSE_FILE="$DATA_DIR/step2_prompt3_translate_${RUN_TS}.response.json"
STEP3_PARSED_FILE="$DATA_DIR/step2_prompt3_translate_${RUN_TS}.parsed.json"

STEP4_PROMPT_FILE="$DATA_DIR/step2_prompt4_check_${RUN_TS}.txt"
STEP4_REQUEST_FILE="$DATA_DIR/step2_prompt4_check_${RUN_TS}.request.json"
STEP4_RESPONSE_FILE="$DATA_DIR/step2_prompt4_check_${RUN_TS}.response.json"
STEP4_PARSED_FILE="$DATA_DIR/step2_prompt4_check_${RUN_TS}.parsed.json"

STEP5_PROMPT_FILE="$DATA_DIR/step2_prompt5_title_summary_${RUN_TS}.txt"
STEP5_REQUEST_FILE="$DATA_DIR/step2_prompt5_title_summary_${RUN_TS}.request.json"
STEP5_RESPONSE_FILE="$DATA_DIR/step2_prompt5_title_summary_${RUN_TS}.response.json"
STEP5_PARSED_FILE="$DATA_DIR/step2_prompt5_title_summary_${RUN_TS}.parsed.json"

log "========== Step2 Test (Bailian 5-Step): START =========="
log "WORKSPACE: $WORKSPACE"
log "INPUT_FILE: $INPUT_FILE"
log "MODEL_NAME: $MODEL_NAME"
log "API_URL: $API_URL"
log "CURL_MAX_TIME: $CURL_MAX_TIME"
log "MAX_CANDIDATES: $MAX_CANDIDATES"
log "CONTENT_LIMIT: $CONTENT_LIMIT"
log "STOP_AFTER_STEP: $STOP_AFTER_STEP"

# Step1：程序做去重 + 基础排序 + 候选压缩。
log "[Step 1/5] 去重 + 基础排序 + 候选压缩"
export INPUT_FILE CANDIDATES_FILE MAX_CANDIDATES CONTENT_LIMIT
python3 <<'PYEOF'
import json
import os
import re
from urllib.parse import urlparse

input_file = os.environ["INPUT_FILE"]
output_file = os.environ["CANDIDATES_FILE"]
max_candidates = int(os.environ["MAX_CANDIDATES"])
content_limit = int(os.environ["CONTENT_LIMIT"])

SOURCE_BONUS = {
    "reuters.com": 9,
    "techcrunch.com": 7,
    "wsj.com": 7,
    "bloomberg.com": 6,
    "ft.com": 6,
    "theverge.com": 5,
    "wired.com": 5,
    "forbes.com": 4,
    "washingtonpost.com": 4,
    "cnbc.com": 4,
}

NOISE_PATTERNS = [
    r"https?://\S+",
    r"Copyright ©?\s*\d{4}.*",
    r"Our best stories.*",
    r"Make us preferred on Google.*",
    r"Health Brief from .*",
    r"AI & Tech Brief from .*",
    r"### More from .*",
    r"## Small Business Technology News #\d+[^.]*",
    r"Image \d+: ",
    r"Top Women Wealth Advisors.*",
    r"Strong Northern Lights Tonight.*",
]


def clean_text(text: str) -> str:
    s = str(text or "")
    for pattern in NOISE_PATTERNS:
        s = re.sub(pattern, " ", s, flags=re.I)
    s = re.sub(r"[#*_`>-]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s.strip(" .,:;|/-_")


def canonical_url(url: str) -> str:
    parsed = urlparse(str(url or ""))
    host = parsed.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    path = parsed.path.rstrip("/")
    return f"{host}{path}"


def infer_source(url: str, host: str = "") -> str:
    if host:
        source = str(host).lower()
    else:
        parsed = urlparse(str(url or ""))
        source = parsed.netloc.lower()
    if source.startswith("www."):
        source = source[4:]
    return source


def normalize_title(title: str) -> str:
    t = clean_text(title)
    t = re.sub(r"\s*[-|]\s*(Reuters|WSJ|Forbes|CNN|TechCrunch|CNBC|Bloomberg|The Washington Post).*$", "", t, flags=re.I)
    t = t.lower()
    t = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def compress_content(content: str) -> str:
    c = clean_text(content)
    if not c:
        return ""
    parts = [p.strip() for p in re.split(r"(?<=[.!?。！？])\s+", c) if p.strip()]
    picked = []
    for part in parts:
        if len(part) < 18:
            continue
        picked.append(part)
        if len(" ".join(picked)) >= 220:
            break
    compact = " ".join(picked) if picked else c
    compact = re.sub(r"\s+", " ", compact).strip()
    return compact[:content_limit].rstrip()


with open(input_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

raw_results = payload.get("results", [])
if not isinstance(raw_results, list) or not raw_results:
    raise RuntimeError("step1 filtered results 为空，无法继续")

seen_urls = set()
seen_titles = set()
items = []
dropped_duplicate = 0

for raw in raw_results:
    title_en = clean_text(raw.get("title", ""))
    url = str(raw.get("url", "") or "").strip()
    source = infer_source(url, raw.get("host", ""))
    score_raw = float(raw.get("score", 0.0) or 0.0)
    compact = compress_content(raw.get("content", ""))

    if not title_en or not url or not compact:
        continue

    url_key = canonical_url(url)
    title_key = f"{source}|{normalize_title(title_en)}"
    if url_key in seen_urls or title_key in seen_titles:
        dropped_duplicate += 1
        continue

    seen_urls.add(url_key)
    seen_titles.add(title_key)

    keyword_bonus = 0
    lower_blob = f"{title_en} {compact}".lower()
    if any(k in lower_blob for k in ["openai", "nvidia", "google", "gemini", "anthropic", "chip", "gpu", "policy", "framework", "fund", "venture"]):
        keyword_bonus += 2
    if 90 <= len(compact) <= 320:
        keyword_bonus += 1

    rank_score = round(score_raw * 100 + SOURCE_BONUS.get(source, 0) + keyword_bonus, 2)
    items.append({
        "title_en": title_en,
        "source": source,
        "url": url,
        "score_raw": round(score_raw, 4),
        "rank_score": rank_score,
        "content_compact": compact,
    })

items.sort(key=lambda x: (x["rank_score"], x["score_raw"]), reverse=True)
items = items[:max_candidates]
for idx, item in enumerate(items, start=1):
    item["id"] = idx

with open(output_file, "w", encoding="utf-8") as f:
    json.dump({
        "stats": {
            "input_count": len(raw_results),
            "dropped_duplicate": dropped_duplicate,
            "kept_count": len(items),
        },
        "items": items,
    }, f, ensure_ascii=False, indent=2)

print(f"prepared_candidates={len(items)}")
PYEOF

log "CANDIDATES_FILE: $CANDIDATES_FILE"

if [ "$STOP_AFTER_STEP" = "1" ]; then
  log "STOP_AFTER_STEP=1，执行到 Step 1 结束。"
  exit 0
fi

if [ -z "$API_KEY" ]; then
  log "ERROR: 未找到 DASHSCOPE_API_KEY / BAILIAN_API_KEY / ALIYUN_BAILIAN_API_KEY。"
  exit 1
fi

build_request_json() {
  local prompt_file="$1"
  local request_file="$2"
  export PROMPT_FILE="$prompt_file" REQUEST_FILE="$request_file" MODEL_NAME
  python3 <<'PYEOF'
import json
import os

prompt = open(os.environ["PROMPT_FILE"], "r", encoding="utf-8").read()
body = {
    "model": os.environ["MODEL_NAME"],
    "messages": [
        {
            "role": "system",
            "content": "你是严谨的中文科技新闻编辑助手。所有输出必须是合法 JSON。"
        },
        {
            "role": "user",
            "content": prompt
        }
    ],
    "temperature": 0.2,
    "seed": 42,
    "stream": False,
    "response_format": {"type": "json_object"}
}
with open(os.environ["REQUEST_FILE"], "w", encoding="utf-8") as f:
    json.dump(body, f, ensure_ascii=False, indent=2)
PYEOF
}

call_bailian() {
  local request_file="$1"
  local response_file="$2"
  local http_code

  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' --max-time "$CURL_MAX_TIME" \
    -X POST "$API_URL" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    --data @"$request_file")"

  log "HTTP $http_code <= $(basename "$response_file")"

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    log "ERROR: 百炼接口返回非 2xx，响应如下："
    sed -n '1,80p' "$response_file"
    exit 1
  fi
}

parse_openai_json_content() {
  local response_file="$1"
  local parsed_file="$2"
  export RESPONSE_FILE="$response_file" PARSED_FILE="$parsed_file"
  python3 <<'PYEOF'
import json
import os
import re
import sys
from json import JSONDecoder, JSONDecodeError

response_file = os.environ["RESPONSE_FILE"]
parsed_file = os.environ["PARSED_FILE"]


def extract_first_json_block(text: str):
    cleaned = str(text or "").strip()
    cleaned = re.sub(r"^```json\\s*", "", cleaned, flags=re.I)
    cleaned = re.sub(r"^```\\s*", "", cleaned, flags=re.I)
    cleaned = re.sub(r"\\s*```$", "", cleaned, flags=re.I)
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

with open(response_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

content = (
    payload.get("choices", [{}])[0]
    .get("message", {})
    .get("content", "")
)

obj = extract_first_json_block(content)
if obj is None:
    print("ERROR: 模型返回内容中未提取到合法 JSON", file=sys.stderr)
    print(content[:1200], file=sys.stderr)
    sys.exit(1)

with open(parsed_file, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PYEOF
}

build_prompt_step2() {
  export CANDIDATES_FILE STEP2_PROMPT_FILE
  python3 <<'PYEOF'
import json
import os

candidates = json.load(open(os.environ["CANDIDATES_FILE"], "r", encoding="utf-8"))["items"]
view = [
    {
        "id": item["id"],
        "title_en": item["title_en"],
        "source": item["source"],
        "rank_score": item["rank_score"],
        "content_compact": item["content_compact"],
    }
    for item in candidates
]

prompt = f"""请从下面的英文 AI 新闻候选中选出 Top5，并以 JSON 输出。

要求：
1. 只做 Top5 选择，不翻译，不生成 title，不生成 summary。
2. 优先选择过去 24 小时内最重要、最具行业影响、信息最完整、且事件不重复的新闻。
3. 尽量覆盖模型/产品、公司战略、融资并购、芯片基础设施、政策监管、科研突破。
4. 输出必须是 JSON，不要 markdown，不要解释。
5. 输出格式必须为：
{{
  "items": [
    {{"id": 1}},
    {{"id": 2}},
    {{"id": 3}},
    {{"id": 4}},
    {{"id": 5}}
  ]
}}

候选新闻：
{json.dumps(view, ensure_ascii=False, indent=2)}
"""

with open(os.environ["STEP2_PROMPT_FILE"], "w", encoding="utf-8") as f:
    f.write(prompt)
PYEOF
}

materialize_top5_en() {
  export CANDIDATES_FILE STEP2_PARSED_FILE TOP5_EN_FILE
  python3 <<'PYEOF'
import json
import os

candidates = {int(item["id"]): item for item in json.load(open(os.environ["CANDIDATES_FILE"], "r", encoding="utf-8"))["items"]}
parsed = json.load(open(os.environ["STEP2_PARSED_FILE"], "r", encoding="utf-8"))
selected = []
seen = set()
for row in parsed.get("items", []):
    try:
        idx = int(row.get("id"))
    except Exception:
        continue
    if idx in candidates and idx not in seen:
        selected.append(candidates[idx])
        seen.add(idx)
    if len(selected) == 5:
        break

if len(selected) != 5:
    raise RuntimeError(f"LLM Top5 选择结果不足 5 条，当前数量={len(selected)}")

with open(os.environ["TOP5_EN_FILE"], "w", encoding="utf-8") as f:
    json.dump({"items": selected}, f, ensure_ascii=False, indent=2)
PYEOF
}

build_prompt_step3() {
  export TOP5_EN_FILE STEP3_PROMPT_FILE
  python3 <<'PYEOF'
import json
import os

top5 = json.load(open(os.environ["TOP5_EN_FILE"], "r", encoding="utf-8"))["items"]
view = [
    {
        "id": item["id"],
        "title_en": item["title_en"],
        "source": item["source"],
        "content_en": item["content_compact"],
    }
    for item in top5
]

prompt = f"""请将下面的 Top5 英文 AI 新闻翻译为中文标准事实稿，并以 JSON 输出。

要求：
1. 每条只生成一段中文标准事实稿，不生成 title，不生成 summary。
2. 中文表达自然、克制、资讯化。
3. 尽量保留关键事实：时间、公司、人物、金额、产品、动作、数字。
4. 不添加背景，不做评论，不延伸推断。
5. 输出必须是 JSON，不要 markdown，不要解释。
6. 输出格式必须为：
{{
  "items": [
    {{"id": 1, "fact_cn": "..."}}
  ]
}}

输入：
{json.dumps(view, ensure_ascii=False, indent=2)}
"""

with open(os.environ["STEP3_PROMPT_FILE"], "w", encoding="utf-8") as f:
    f.write(prompt)
PYEOF
}

build_prompt_step4() {
  export TOP5_EN_FILE STEP3_PARSED_FILE STEP4_PROMPT_FILE
  python3 <<'PYEOF'
import json
import os

top5 = {int(item["id"]): item for item in json.load(open(os.environ["TOP5_EN_FILE"], "r", encoding="utf-8"))["items"]}
translated = json.load(open(os.environ["STEP3_PARSED_FILE"], "r", encoding="utf-8")).get("items", [])
payload = []
for item in translated:
    idx = int(item["id"])
    if idx in top5:
        payload.append({
            "id": idx,
            "title_en": top5[idx]["title_en"],
            "content_en": top5[idx]["content_compact"],
            "fact_cn": item.get("fact_cn", ""),
        })

prompt = f"""请对下面的中文事实稿做事实校正，并以 JSON 输出。

要求：
1. 只校正事实完整性、措辞准确性、数字和主体是否遗漏。
2. 不扩写背景，不生成 title，不生成 summary。
3. 如原稿已经准确，可微调措辞，但不要明显改写主题。
4. 输出必须是 JSON，不要 markdown，不要解释。
5. 输出格式必须为：
{{
  "items": [
    {{"id": 1, "fact_cn_checked": "..."}}
  ]
}}

输入：
{json.dumps(payload, ensure_ascii=False, indent=2)}
"""

with open(os.environ["STEP4_PROMPT_FILE"], "w", encoding="utf-8") as f:
    f.write(prompt)
PYEOF
}

build_prompt_step5() {
  export CHECKED_FILE STEP5_PROMPT_FILE
  python3 <<'PYEOF'
import json
import os

checked = json.load(open(os.environ["CHECKED_FILE"], "r", encoding="utf-8")).get("items", [])

prompt = f"""请基于下面校正后的中文事实稿，为每条新闻生成最终 title 和 summary，并以 JSON 输出。

要求：
1. title 与 summary 必须低重复。
2. 中文表达自然、克制、资讯化。
3. title 必须点明主体，禁止使用“该公司”“某公司”“人工智能公司”等泛称。
4. title 尽量不超过 22 个中文字符；summary 尽量不超过 34 个中文字符。
5. 如果长度接近上限，请主动改写压缩，保证语义完整，不要靠截断完成长度要求。
6. title 和 summary 都必须是完整短句，不能出现残句，不能出现未完成的数字、单位、时间、金额、公司名、人名或动词短语。
7. 一条新闻只能表达一个主事件；如果事实稿中包含两个信息点，只保留最核心的那一个，不得并列混写。
8. title 负责概括“谁做了什么”，summary 负责补充关键结果、数字或背景，但不要与 title 只是换词重复。
9. 不要照搬事实稿整句，不要写成评论句，不要使用夸张、营销或判断性措辞。
10. 尽量避免使用分号、顿号串联两个独立新闻点。
11. 输出必须是 JSON，不要 markdown，不要解释。
12. 输出格式必须为：
{{
  "items": [
    {{"id": 1, "title": "...", "summary": "..."}}
  ]
}}

输入：
{json.dumps(checked, ensure_ascii=False, indent=2)}
"""

with open(os.environ["STEP5_PROMPT_FILE"], "w", encoding="utf-8") as f:
    f.write(prompt)
PYEOF
}

finalize_outputs() {
  export TOP5_EN_FILE CHECKED_FILE STEP5_PARSED_FILE TOP5_FILE BRIEF_FILE REPORT_FILE DATE_STR MODEL_NAME INPUT_FILE CANDIDATES_FILE STEP2_PARSED_FILE STEP3_PARSED_FILE STEP4_PARSED_FILE
  python3 <<'PYEOF'
import json
import os
import re
import string
import unicodedata

TITLE_MAX_CHARS = 22
SUMMARY_MAX_CHARS = 34


def clean_text(text: str) -> str:
    s = str(text or "")
    s = re.sub(r"https?://\S+", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s.strip(" .,:;|/-_")


def calc_visual_length(text: str) -> float:
    total = 0.0
    for ch in str(text or ""):
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


def smart_truncate_by_visual_length(text: str, max_visual_len: float) -> str:
    out = []
    acc = 0.0
    for ch in str(text or ""):
        w = calc_visual_length(ch)
        if acc + w > max_visual_len:
            break
        out.append(ch)
        acc += w
    return "".join(out).rstrip()


def enforce_visual_limits(title: str, summary: str):
    title = clean_text(title)
    summary = clean_text(summary)
    if summary.startswith(title):
        summary = clean_text(summary[len(title):])
    if len(title) > TITLE_MAX_CHARS:
        title = title[:TITLE_MAX_CHARS]
    if len(summary) > SUMMARY_MAX_CHARS:
        summary = summary[:SUMMARY_MAX_CHARS]

    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    if s_len > 34 or (t_len + s_len) > 52:
        summary = smart_truncate_by_visual_length(summary, min(34, 52 - t_len))
    t_len = calc_visual_length(title)
    s_len = calc_visual_length(summary)
    if t_len > 22 or (t_len + s_len) > 52:
        title = smart_truncate_by_visual_length(title, min(22, 52 - s_len))

    return clean_text(title), clean_text(summary)


top5_en = {int(item["id"]): item for item in json.load(open(os.environ["TOP5_EN_FILE"], "r", encoding="utf-8"))["items"]}
checked = {int(item["id"]): item.get("fact_cn_checked", "") for item in json.load(open(os.environ["CHECKED_FILE"], "r", encoding="utf-8")).get("items", [])}
final_items_raw = json.load(open(os.environ["STEP5_PARSED_FILE"], "r", encoding="utf-8")).get("items", [])

final_items = []
brief_items = []
for item in final_items_raw:
    idx = int(item["id"])
    if idx not in top5_en:
        continue
    title, summary = enforce_visual_limits(item.get("title", ""), item.get("summary", ""))
    final_items.append({
        "id": idx,
        "title": title,
        "summary": summary,
        "source": top5_en[idx]["source"],
        "url": top5_en[idx]["url"],
        "fact_cn_checked": checked.get(idx, ""),
    })
    brief_items.append({
        "title": title,
        "summary": summary,
    })

if len(final_items) != 5:
    raise RuntimeError(f"最终 title/summary 数量异常，当前={len(final_items)}")

with open(os.environ["TOP5_FILE"], "w", encoding="utf-8") as f:
    json.dump({"items": final_items}, f, ensure_ascii=False, indent=2)

with open(os.environ["BRIEF_FILE"], "w", encoding="utf-8") as f:
    json.dump({
        "date": os.environ["DATE_STR"],
        "template": "b",
        "items": brief_items,
    }, f, ensure_ascii=False, indent=2)

with open(os.environ["REPORT_FILE"], "w", encoding="utf-8") as f:
    f.write(f"input_file={os.environ['INPUT_FILE']}\n")
    f.write(f"model={os.environ['MODEL_NAME']}\n")
    f.write(f"step1_candidates_file={os.environ['CANDIDATES_FILE']}\n")
    f.write(f"step2_select_file={os.environ['STEP2_PARSED_FILE']}\n")
    f.write(f"step3_translate_file={os.environ['STEP3_PARSED_FILE']}\n")
    f.write(f"step4_check_file={os.environ['STEP4_PARSED_FILE']}\n")
    f.write(f"step5_title_summary_file={os.environ['STEP5_PARSED_FILE']}\n")
    f.write(f"final_items={len(final_items)}\n")
PYEOF
}

run_llm_step() {
  local step_label="$1"
  local builder_func="$2"
  local prompt_file="$3"
  local request_file="$4"
  local response_file="$5"
  local parsed_file="$6"

  log "$step_label building prompt"
  "$builder_func"
  log "$step_label prompt saved: $prompt_file"

  build_request_json "$prompt_file" "$request_file"
  log "$step_label request saved: $request_file"

  call_bailian "$request_file" "$response_file"
  log "$step_label response saved: $response_file"

  parse_openai_json_content "$response_file" "$parsed_file"
  log "$step_label parsed saved: $parsed_file"
}

# Step2：LLM 选择 Top5。
run_llm_step "[Step 2/5] LLM 选择 Top5" build_prompt_step2 "$STEP2_PROMPT_FILE" "$STEP2_REQUEST_FILE" "$STEP2_RESPONSE_FILE" "$STEP2_PARSED_FILE"
materialize_top5_en
log "TOP5_EN_FILE: $TOP5_EN_FILE"

if [ "$STOP_AFTER_STEP" = "2" ]; then
  log "STOP_AFTER_STEP=2，执行到 Step 2 结束。"
  exit 0
fi

# Step3：LLM 翻译。
run_llm_step "[Step 3/5] LLM 翻译" build_prompt_step3 "$STEP3_PROMPT_FILE" "$STEP3_REQUEST_FILE" "$STEP3_RESPONSE_FILE" "$STEP3_PARSED_FILE"
cp "$STEP3_PARSED_FILE" "$FACTS_FILE"
log "FACTS_FILE: $FACTS_FILE"

if [ "$STOP_AFTER_STEP" = "3" ]; then
  log "STOP_AFTER_STEP=3，执行到 Step 3 结束。"
  exit 0
fi

# Step4：LLM 校正。
run_llm_step "[Step 4/5] LLM 校正" build_prompt_step4 "$STEP4_PROMPT_FILE" "$STEP4_REQUEST_FILE" "$STEP4_RESPONSE_FILE" "$STEP4_PARSED_FILE"
cp "$STEP4_PARSED_FILE" "$CHECKED_FILE"
log "CHECKED_FILE: $CHECKED_FILE"

if [ "$STOP_AFTER_STEP" = "4" ]; then
  log "STOP_AFTER_STEP=4，执行到 Step 4 结束。"
  exit 0
fi

# Step5：LLM 生成 title 和 summary。
run_llm_step "[Step 5/5] LLM 生成 title 和 summary" build_prompt_step5 "$STEP5_PROMPT_FILE" "$STEP5_REQUEST_FILE" "$STEP5_RESPONSE_FILE" "$STEP5_PARSED_FILE"

# 最终拼装 top5 与 daily_brief。
finalize_outputs

log "TOP5_FILE: $TOP5_FILE"
log "BRIEF_FILE: $BRIEF_FILE"
log "REPORT_FILE: $REPORT_FILE"
log "========== Step2 Test (Bailian 5-Step): DONE =========="
