#!/usr/bin/env python3
"""Refine overflowing summaries in daily_brief.json to one-line rendering."""

from __future__ import annotations

import argparse
import json
import re
import string
import subprocess
import sys
import unicodedata
import uuid
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw

DEFAULT_POSTER_PROJECT_ROOT = Path(__file__).resolve().parents[2] / "daily-brief-to-poster"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Refine multi-line summaries before poster rendering.")
    parser.add_argument("--brief", required=True, help="Path to daily_brief.json")
    parser.add_argument(
        "--project-root",
        default=str(DEFAULT_POSTER_PROJECT_ROOT),
        help="Path to daily-brief-to-poster project root",
    )
    parser.add_argument("--template", choices=("a", "b", "c"), default=None, help="Optional template override")
    parser.add_argument("--max-retries-per-item", type=int, default=5, help="Max rewrite retries per item")
    parser.add_argument("--dry-run", action="store_true", help="Do not write files, only print stats")
    return parser.parse_args()


def extract_json_obj(raw: str) -> dict[str, Any] | None:
    decoder = json.JSONDecoder()
    for i, ch in enumerate(raw):
        if ch != "{":
            continue
        try:
            obj, _ = decoder.raw_decode(raw[i:])
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            return obj
    return None


def extract_summary_text(raw: str) -> str:
    cleaned = re.sub(r"\x1B\[[0-?]*[ -/]*[@-~]", "", raw or "")
    # Try direct JSON object first.
    obj = extract_json_obj(cleaned)
    if obj and "summary" in obj:
        return re.sub(r"\s+", " ", str(obj["summary"])).strip()

    # Try envelope payloads.
    if obj and "payloads" in obj and obj["payloads"]:
        text = str(obj["payloads"][0].get("text", "")).strip()
        payload_obj = extract_json_obj(text)
        if payload_obj and "summary" in payload_obj:
            return re.sub(r"\s+", " ", str(payload_obj["summary"])).strip()
        return re.sub(r"\s+", " ", text.replace("```json", "").replace("```", "")).strip().splitlines()[0].strip()

    # Fallback to first non-empty line.
    for line in cleaned.splitlines():
        line = line.strip()
        if (
            line
            and not line.startswith("[plugins]")
            and not line.startswith("[info]")
            and line not in {"{", "}", "[", "]", "```", "```json"}
        ):
            return re.sub(r"\s+", " ", line).strip()
    return ""


def is_valid_summary_text(text: str) -> bool:
    s = re.sub(r"\s+", " ", (text or "")).strip()
    if not s:
        return False
    if s in {"{", "}", "[", "]", "```", "```json"}:
        return False
    if s.startswith("{") or s.startswith("["):
        return False
    if len(s) < 6:
        return False
    return True


def calc_visual_length(text: str) -> float:
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


def smart_truncate_by_visual_length(text: str, max_visual_len: float) -> str:
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


def call_llm_rewrite(title: str, summary: str) -> str:
    prompt = f"""你是中文科技编辑。请仅重写下面这条新闻的 summary，并确保更短且信息不空。

要求：
1) 只输出 JSON：{{"summary":"..."}}
2) 不能改 title
3) summary 必须补充 title 未包含的新信息，不能复述
4) 中文输出（专有名词可英文）
5) 视觉加权长度目标：summary_visual_len<=34 且 title+summary<=52
6) 风格简洁，避免空话，尽量单行显示

title: {title}
summary: {summary}
"""
    sid = f"isolated-{uuid.uuid4().hex[:12]}"
    cmd = [
        "openclaw",
        "agent",
        "--session-id",
        sid,
        "--json",
        "--channel",
        "no",
        "--timeout",
        "120",
        "--thinking",
        "low",
        "--verbose",
        "off",
        "--message",
        prompt,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return extract_summary_text((result.stdout or "") + "\n" + (result.stderr or ""))


def main() -> int:
    args = parse_args()
    brief_path = Path(args.brief).resolve()
    project_root = Path(args.project_root).resolve()
    if not brief_path.exists():
        raise FileNotFoundError(f"brief not found: {brief_path}")

    sys.path.insert(0, str(project_root))
    from render_poster import FontManager, TEMPLATE_DEFAULT_KEY, TEMPLATE_REGISTRY, build_summary_variants, load_json

    brief = load_json(brief_path)
    items = brief.get("items", [])
    if not isinstance(items, list) or len(items) != 5:
        raise ValueError("daily_brief.json items must contain exactly 5 entries")

    template_key = args.template or str(brief.get("template", TEMPLATE_DEFAULT_KEY)).strip().lower() or TEMPLATE_DEFAULT_KEY
    if template_key not in TEMPLATE_REGISTRY:
        template_key = TEMPLATE_DEFAULT_KEY
    layout_path = project_root / TEMPLATE_REGISTRY[template_key].layout_path
    layout = load_json(layout_path)

    fonts = layout["fonts"]
    styles = layout["styles"]
    padding = layout["card_padding"]
    cards = layout["news_cards"]

    img = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    fm = FontManager(project_root)
    summary_font = fm.get(fonts["card_summary"], int(styles["card_summary"]["font_size"]))

    def summary_lines(text: str, card: dict[str, Any]) -> int:
        content_w = int(card["w"]) - 2 * int(padding["left_right"])
        variants = build_summary_variants(draw, text, summary_font, content_w)
        if not variants:
            return 99
        return len(variants[0])

    checked = 0
    rewritten = 0
    one_line = 0
    fallback_kept = 0

    for i, item in enumerate(items):
        checked += 1
        card = cards[i]
        title = re.sub(r"\s+", " ", str(item.get("title", ""))).strip()
        current = re.sub(r"\s+", " ", str(item.get("summary", ""))).strip()
        if summary_lines(current, card) <= 1:
            one_line += 1
            continue

        success = False
        for _ in range(max(1, args.max_retries_per_item)):
            candidate = call_llm_rewrite(title, current)
            if not is_valid_summary_text(candidate):
                continue
            candidate = re.sub(r"\s+", " ", candidate).strip()[:34]
            title_len = calc_visual_length(title)
            summary_len = calc_visual_length(candidate)
            combined_len = round(title_len + summary_len, 2)
            if summary_len > 34 or combined_len > 52:
                allowed = min(34, 52 - title_len)
                candidate = smart_truncate_by_visual_length(candidate, allowed)
            if candidate == current:
                continue
            item["summary"] = candidate
            current = candidate
            rewritten += 1
            if summary_lines(current, card) <= 1:
                one_line += 1
                success = True
                break
        if not success and summary_lines(current, card) > 1:
            fallback_kept += 1

    if not args.dry_run:
        brief_path.write_text(json.dumps(brief, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    result = {
        "status": "ok",
        "checked_count": checked,
        "rewritten_count": rewritten,
        "one_line_count": one_line,
        "fallback_kept_count": fallback_kept,
        "template": template_key,
    }
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
