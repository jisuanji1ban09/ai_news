#!/usr/bin/env python3
"""Generate a short-video voiceover script using Bailian LLM."""

from __future__ import annotations

import json
import logging
import os
import re
import sys
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RUNTIME_DIR = PROJECT_ROOT / "tmp"

TOP5_FILE = Path(
    os.environ.get("TOP5_JSON_FILE", str(DEFAULT_RUNTIME_DIR / "top5.json"))
)
OUTPUT_FILE = Path(
    os.environ.get("VOICEOVER_SCRIPT_FILE", str(DEFAULT_RUNTIME_DIR / "voice_script.txt"))
)
DATE_STR = os.environ.get("DATE_STR", "")

# 百炼 API 配置，复用 Step3 的环境变量
API_KEY = (
    os.environ.get("BAILIAN_API_KEY") or
    os.environ.get("DASHSCOPE_API_KEY") or
    os.environ.get("ALIYUN_BAILIAN_API_KEY", "")
)
MODEL = os.environ.get("BAILIAN_MODEL", "qwen-plus")
API_URL = os.environ.get(
    "BAILIAN_BASE_URL",
    "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
)
TIMEOUT = int(os.environ.get("CURL_MAX_TIME", "180"))


def format_date(date_str: str) -> str:
    """Format date string to Chinese format."""
    if not date_str:
        dt = datetime.now()
        return f"{dt.year}年{dt.month}月{dt.day}日"
    m = re.search(r"(\d{4})[.\-/年](\d{1,2})[.\-/月](\d{1,2})", date_str)
    if m:
        y, mo, d = (int(v) for v in m.groups())
        return f"{y}年{mo}月{d}日"
    return date_str


def load_top5(file_path: Path) -> list[dict[str, Any]]:
    """Load and validate top5.json."""
    if not file_path.exists():
        raise FileNotFoundError(f"top5.json 不存在：{file_path}")
    try:
        data = json.loads(file_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise ValueError(f"top5.json 不是合法 JSON：{e}") from e
    if not isinstance(data, list) or len(data) != 5:
        raise ValueError(f"top5.json 必须是长度为 5 的数组，当前：{len(data) if isinstance(data, list) else type(data)}")
    return data


def call_llm(prompt: str) -> str:
    """Call Bailian API and return plain text response."""
    if not API_KEY:
        raise RuntimeError("未找到百炼 API Key（BAILIAN_API_KEY / DASHSCOPE_API_KEY）")

    body = {
        "model": MODEL,
        "messages": [
            {
                "role": "system",
                "content": "你是专业的抖音 AI 资讯短视频口播文案撰稿人。"
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        "temperature": 0.7,
        "enable_thinking": False,
        "stream": False,
    }
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=body_bytes,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", "replace")[:400]
        raise RuntimeError(f"百炼 API HTTP {e.code}：{err}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"百炼 API 连接失败：{e.reason}")

    payload = json.loads(raw)
    content = (
        payload.get("choices", [{}])[0]
               .get("message", {})
               .get("content", "")
    )
    if not content:
        raise RuntimeError(f"百炼 API 返回空内容，完整响应：{raw[:300]}")
    return content.strip()


def build_prompt(items: list[dict[str, Any]], script_date: str) -> str:
    """Build the voiceover prompt from top5 items."""
    news_lines = []
    for i, item in enumerate(items, 1):
        title = str(item.get("title", "")).strip()
        summary = str(item.get("summary", "")).strip()
        news_lines.append(f"{i}. 标题：{title}\n   摘要：{summary}")

    news_block = "\n".join(news_lines)

    return f"""请根据下面 5 条 AI 新闻，生成一段抖音短视频口播文案。

【今日日期】{script_date}

【新闻内容】
{news_block}

【口播要求】
1. 开场要有钩子，吸引观众继续看，不超过 20 字
2. 用"第一条""第二条"..."第五条"逐条播报
3. 每条新闻播报要求：
   - 融合 title 和 summary 的信息，不要只念 title
   - 口语化表达，像在和朋友聊天
   - 数字要口语化：50% → 百分之五十，$140B → 一百四十亿美元
   - 每条控制在 40~60 字，完整表达，不能截断
   - 结尾加一句点评或洞察（10字以内）
4. 结尾加互动引导，鼓励评论和关注
5. 全文总字数控制在 300~450 字，适合 60~90 秒播报
6. 全程使用简体中文，专有名词（OpenAI、GPU 等）可保留英文
7. 不要用夸张或过度营销的措辞，保持资讯感

【格式要求】
直接输出口播文案正文，不要加任何说明、标题或 markdown 格式。
"""


def generate_script(items: list[dict[str, Any]], date_str: str) -> str:
    """Generate voiceover script via LLM."""
    script_date = format_date(date_str)
    prompt = build_prompt(items, script_date)
    logger.info("Calling Bailian LLM for voiceover generation...")
    script = call_llm(prompt)
    logger.info("Voiceover script generated, length=%d chars", len(script))
    return script


def save_script(output_path: Path, script: str) -> None:
    """Save script to disk."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(script, encoding="utf-8")
    logger.info("Saved voiceover script to %s", output_path)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    try:
        items = load_top5(TOP5_FILE)
        script = generate_script(items, DATE_STR)
        save_script(OUTPUT_FILE, script)
        logger.info("Voiceover script generated successfully")
    except (FileNotFoundError, ValueError) as e:
        logger.error("%s", e)
        sys.exit(1)
    except RuntimeError as e:
        logger.error("LLM 调用失败：%s", e)
        sys.exit(1)
    except OSError as e:
        logger.error("写入文件失败：%s", e)
        sys.exit(1)
    except Exception as e:
        logger.exception("生成口播稿时发生未预期错误：%s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
