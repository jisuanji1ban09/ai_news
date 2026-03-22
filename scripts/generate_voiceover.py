#!/usr/bin/env python3
"""Generate a short-video voiceover script from top5.json."""

from __future__ import annotations

import json
import logging
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Mapping, Sequence

logger = logging.getLogger(__name__)
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RUNTIME_DIR = PROJECT_ROOT / "tmp"

TOP5_FILE = Path(
    os.environ.get(
        "TOP5_JSON_FILE",
        str(DEFAULT_RUNTIME_DIR / "top5.json"),
    )
)
OUTPUT_FILE = Path(
    os.environ.get(
        "VOICEOVER_SCRIPT_FILE",
        str(DEFAULT_RUNTIME_DIR / "voiceover_script.txt"),
    )
)
DATE_STR = os.environ.get("DATE_STR")

TITLE_KEYS = ("short_title", "title")
SUMMARY_KEYS = ("short_summary", "summary", "summary_cn")
UNCERTAIN_KEYWORDS = (
    "计划",
    "拟",
    "预计",
    "将",
    "或将",
    "考虑",
    "下周公布",
    "传闻",
)
CATEGORY_MAP = {
    "china_ai": "policy",
    "funding_mna": "investment",
    "bigtech": "bigtech",
    "regulation_policy": "policy",
    "research_breakthrough": "research",
}
KEYWORD_GROUPS = (
    ("government", ("军工", "政府订单", "政府采购", "国防", "五角大楼")),
    ("policy", ("政策", "法规", "监管", "立法", "法案", "合规", "条例")),
    ("chip", ("芯片", "gpu", "算力", "数据中心", "服务器", "云基础设施")),
    ("investment", ("融资", "投资", "收购", "并购", "募资", "入股")),
    ("product", ("模型", "agent", "智能体", "开源", "产品", "发布", "推出", "升级")),
    ("bigtech", ("裁员", "重组", "战略", "组织", "资源", "大厂")),
    ("research", ("材料", "科研", "研究", "科学", "实验", "发现")),
)
ACTION_HINTS = (
    "被",
    "将",
    "拟",
    "计划",
    "考虑",
    "推进",
    "限制",
    "聚焦",
    "围绕",
    "推出",
    "发布",
    "升级",
    "道歉",
    "列入",
    "禁止",
    "压缩",
)
STANDARD_INSIGHTS = {
    "chip": (
        "算力竞争还在继续升级",
        "基础设施投入还在加速",
        "供应链能力越来越关键",
    ),
    "investment": (
        "资本继续押注关键技术",
        "行业整合速度正在加快",
        "商业化价值被重新定价",
    ),
    "product": (
        "产品竞争进入了新阶段",
        "AI应用生态正在扩大",
        "技术热度还在持续上升",
    ),
    "bigtech": (
        "大厂正在调整资源结构",
        "AI已进入核心投入阶段",
        "组织效率开始服务AI战略",
    ),
    "policy": (
        "监管开始跟上技术发展",
        "政策会直接影响行业节奏",
        "合规正在变成新门槛",
    ),
    "government": (
        "AI开始进入真实需求场景",
        "政府采购正在释放产业信号",
        "真实订单开始带动落地节奏",
    ),
    "research": (
        "AI正在改写科研推进速度",
        "科研场景开始看到实际增益",
        "技术落地正从工具走向方法",
    ),
    "general": (
        "行业动作还在持续加快",
        "市场关注点正在继续上移",
        "落地节奏还在不断往前推",
    ),
}
SOFT_INSIGHTS = {
    "chip": (
        "算力投入可能还会继续升温",
        "基础设施布局还会继续提速",
        "供应链能力会更受关注",
    ),
    "investment": (
        "资本还在继续观察关键技术",
        "行业整合节奏可能继续加快",
        "商业化价值还会反复验证",
    ),
    "product": (
        "产品竞争还会继续往前推",
        "AI应用生态还在继续扩张",
        "技术热度短期内还会维持",
    ),
    "bigtech": (
        "大厂资源还会继续向AI倾斜",
        "核心投入方向可能继续调整",
        "组织变化还会围着AI展开",
    ),
    "policy": (
        "监管讨论正在逐步跟上",
        "政策方向会影响后续节奏",
        "行业还要继续适应合规要求",
    ),
    "government": (
        "真实需求场景还在持续打开",
        "政府信号会继续影响产业判断",
        "相关采购动向值得继续观察",
    ),
    "research": (
        "科研场景还会继续验证AI价值",
        "研究效率提升还要看持续落地",
        "技术突破还需要更多真实验证",
    ),
    "general": (
        "行业节奏可能还会继续加快",
        "市场还在观察后续落地情况",
        "这类动作值得继续跟进",
    ),
}


def format_date(date_str: str | None = None) -> str:
    """Format the date as YYYY年M月D日."""
    if not date_str:
        current = datetime.now()
        return f"{current.year}年{current.month}月{current.day}日"

    cleaned = clean_text(date_str)
    match = re.search(r"(\d{4})[.\-/年](\d{1,2})[.\-/月](\d{1,2})", cleaned)
    if match:
        year, month, day = (int(value) for value in match.groups())
        return f"{year}年{month}月{day}日"

    return cleaned


def clean_text(text: Any) -> str:
    """Clean text for voiceover generation."""
    if text is None:
        return ""

    cleaned = str(text)
    cleaned = re.sub(r"(https?://|www\.)\S+", "", cleaned)
    cleaned = cleaned.replace("\u3000", " ")
    cleaned = cleaned.translate(
        str.maketrans(
            {
                ",": "，",
                ".": "。",
                "!": "！",
                "?": "？",
                ":": "：",
                ";": "；",
                "(": "（",
                ")": "）",
            }
        )
    )
    cleaned = re.sub(r"\s+", " ", cleaned)
    cleaned = re.sub(r"\s*([，。！？；：])\s*", r"\1", cleaned)
    cleaned = re.sub(r"([，。！？；：])\1+", r"\1", cleaned)
    return cleaned.strip(" ，。！？；：\n\t")


def load_top5(file_path: Path) -> list[dict[str, Any]]:
    """Load and validate top5 news data from JSON."""
    logger.info("Loading top5 data from %s", file_path)

    if not file_path.exists():
        raise FileNotFoundError(f"top5.json 不存在：{file_path}")

    try:
        raw_data = json.loads(file_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"top5.json 不是合法 JSON：{exc}") from exc

    if not isinstance(raw_data, list):
        raise ValueError("top5.json 顶层必须是 list")
    if len(raw_data) != 5:
        raise ValueError(f"top5.json 长度必须为 5，当前为 {len(raw_data)}")

    validated: list[dict[str, Any]] = []
    for index, item in enumerate(raw_data, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"第 {index} 条新闻必须是 dict")
        validated.append(dict(item))

    logger.info("Validated %s news items", len(validated))
    return validated


def get_preferred_value(item: Mapping[str, Any], keys: Sequence[str]) -> str:
    """Return the first non-empty field from the given keys."""
    for key in keys:
        value = clean_text(item.get(key, ""))
        if value:
            return value
    return ""


def has_uncertainty(text: str) -> bool:
    """Return True when the news contains tentative wording."""
    return any(keyword in text for keyword in UNCERTAIN_KEYWORDS)


def classify_news(item: Mapping[str, Any]) -> str:
    """Classify a news item for insight generation."""
    category = str(item.get("category", "")).strip()
    base_group = CATEGORY_MAP.get(category, "")
    searchable = " ".join(
        (
            get_preferred_value(item, TITLE_KEYS),
            get_preferred_value(item, SUMMARY_KEYS),
            category,
        )
    ).lower()

    government_keywords = dict(KEYWORD_GROUPS).get("government", ())
    if any(keyword in searchable for keyword in government_keywords):
        return "government"
    if base_group:
        return base_group

    for group, keywords in KEYWORD_GROUPS:
        if any(keyword in searchable for keyword in keywords):
            return group

    return "general"


def extract_subject(title: str) -> str:
    """Extract a rough subject from the title for light rewriting."""
    verbs = (
        "获",
        "获得",
        "拿到",
        "推出",
        "发布",
        "加码",
        "计划",
        "拟",
        "考虑",
        "提出",
        "通过",
        "卷入",
        "陷",
        "推进",
        "提速",
    )
    for verb in verbs:
        if verb in title:
            subject = clean_text(title.split(verb, maxsplit=1)[0])
            if 1 <= len(subject) <= 18:
                return subject
    return clean_text(title[:14])


def trim_clause(text: str, limit: int) -> str:
    """Trim text to a soft length limit without trailing connectors."""
    trimmed = clean_text(text)
    if len(trimmed) <= limit:
        return trimmed
    shortened = trimmed[:limit].rstrip("，、和及与在把对的")
    return clean_text(shortened)


def rewrite_title(title: str, summary: str, group: str) -> str:
    """Rewrite the preferred title into a more spoken clause."""
    spoken = clean_text(title)
    if not spoken:
        return ""

    if group == "investment":
        spoken = spoken.replace("获得", "拿到").replace("获", "拿到", 1)
    if "拟推" in spoken:
        spoken = spoken.replace("拟推", "提出")
    if "再提速" in spoken:
        spoken = spoken.replace("再提速", "继续提速")
    if "风波" in spoken and "陷" in spoken:
        spoken = spoken.replace("陷", "卷入", 1)
    if spoken.endswith("法") and "法案" not in spoken and group == "policy":
        spoken = f"{spoken}案"

    if group == "investment":
        subject = extract_subject(title)
        amount_match = re.search(r"([0-9]+(?:\.[0-9]+)?[亿美元万亿万元元]+)", title + summary)
        if subject and amount_match:
            return trim_clause(f"{subject}拿到{amount_match.group(1)}融资", 24)

    return trim_clause(spoken, 24)


def rewrite_detail(summary: str, title: str, group: str, uncertain: bool) -> str:
    """Rewrite the supporting detail into a spoken supplement."""
    detail = clean_text(summary)
    if not detail:
        return ""

    if title and detail in title:
        return ""
    if title and title in detail:
        detail = clean_text(detail.replace(title, "", 1))

    if not detail:
        return ""

    detail = re.split(r"[。；]", detail, maxsplit=1)[0]
    detail = clean_text(detail)
    detail = detail.replace("被列", "被列入")
    detail = detail.replace("压缩至", "压缩到")
    detail = detail.replace("推进3D", "在推进3D")
    detail = re.sub(
        r"^AI将(.+?)压缩到(.+)$",
        r"有团队想把\1压缩到\2",
        detail,
    )
    detail = re.sub(
        r"^限制(.+?)情感宣传$",
        r"限制\1做情感宣传",
        detail,
    )

    if not detail:
        return ""

    if any(hint in detail for hint in ACTION_HINTS):
        if "研发" in detail and not uncertain and "继续" not in detail:
            detail = detail.replace("研发", "研发", 1)
        return trim_clause(detail, 20)

    if group == "investment":
        detail = f"主要投向{detail}"
    elif group in {"chip", "product", "research", "government"}:
        detail = f"重点放在{detail}"
    elif group == "policy":
        detail = f"重点是{detail}"
    elif group == "bigtech":
        detail = f"背后是{detail}"
    else:
        detail = f"重点是{detail}"

    return trim_clause(detail, 20)


def generate_news_sentence(item: Mapping[str, Any]) -> str:
    """Generate the first sentence: what happened."""
    title = get_preferred_value(item, TITLE_KEYS)
    summary = get_preferred_value(item, SUMMARY_KEYS)
    group = classify_news(item)
    uncertain = has_uncertainty(f"{title} {summary}")

    headline = rewrite_title(title, summary, group)
    detail = rewrite_detail(summary, title, group, uncertain)

    if headline and detail:
        return trim_clause(f"{headline}，{detail}", 38)
    if headline:
        return headline
    if detail:
        return detail
    return "这条新闻的关键信息暂时不够完整"


def generate_insight_sentence(item: Mapping[str, Any], index: int) -> str:
    """Generate the second sentence: what it means."""
    title = get_preferred_value(item, TITLE_KEYS)
    summary = get_preferred_value(item, SUMMARY_KEYS)
    uncertain = has_uncertainty(f"{title} {summary}")
    group = classify_news(item)

    pool_map = SOFT_INSIGHTS if uncertain else STANDARD_INSIGHTS
    candidates = pool_map.get(group, pool_map["general"])
    return candidates[(index - 1) % len(candidates)]


def generate_script(items: Sequence[Mapping[str, Any]], date_str: str | None = None) -> str:
    """Generate the full voiceover script."""
    if len(items) != 5:
        raise ValueError(f"生成口播前需要 5 条新闻，当前为 {len(items)}")

    script_date = format_date(date_str)
    ordinals = ("第一条", "第二条", "第三条", "第四条", "第五条")

    lines = [
        "AI 每日资讯来了！",
        f"{script_date}，AI 圈 5 条重点消息，带你快速看懂行业最新动态。",
        "",
    ]
    group_counts: dict[str, int] = {}

    for index, item in enumerate(items, start=1):
        group = classify_news(item)
        group_counts[group] = group_counts.get(group, 0) + 1
        news_sentence = generate_news_sentence(item)
        insight_sentence = generate_insight_sentence(item, group_counts[group])
        lines.append(f"{ordinals[index - 1]}，{news_sentence}。{insight_sentence}。")

    lines.extend(
        [
            "",
            "以上就是今天的 5 条重点消息。",
            "关注我，每天带你快速看懂 AI 行业最新动态。",
        ]
    )
    return "\n".join(lines)


def save_script(output_path: Path, script: str) -> None:
    """Save the generated script to disk."""
    logger.info("Saving voiceover script to %s", output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(script, encoding="utf-8")


def main() -> None:
    """Main entry point."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    try:
        items = load_top5(TOP5_FILE)
        script = generate_script(items, DATE_STR)
        save_script(OUTPUT_FILE, script)
        logger.info("Voiceover script generated successfully")
    except (FileNotFoundError, ValueError) as exc:
        logger.error("%s", exc)
        sys.exit(1)
    except OSError as exc:
        logger.error("写入文件失败：%s", exc)
        sys.exit(1)
    except Exception as exc:  # pragma: no cover
        logger.exception("生成口播稿时发生未预期错误：%s", exc)
        sys.exit(1)


if __name__ == "__main__":
    main()
