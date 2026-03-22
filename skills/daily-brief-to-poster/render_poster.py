#!/usr/bin/env python3
"""AI Daily Poster renderer with multi-template support."""

import argparse
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Hard-coded invariants requested by product constraints.
REQUIRED_CANVAS_WIDTH = 1365
REQUIRED_CANVAS_HEIGHT = 2048
REQUIRED_NEWS_COUNT = 5
FIXED_MAIN_TITLE = "AI每日资讯"
SUPPORTED_DATE_FORMATS = ("%Y.%m.%d", "%Y-%m-%d")
TEMPLATE_DEFAULT_KEY = "b"
ALLOWED_TEMPLATE_KEYS = ("a", "b", "c")


@dataclass
class TextLayout:
    """Container for measured multiline text layout."""

    lines: List[str]
    font: ImageFont.FreeTypeFont
    spacing: int
    width: int
    height: int


@dataclass(frozen=True)
class TemplateSpec:
    """Static configuration for one template key."""

    key: str
    display_name: str
    layout_path: str
    template_path: str
    output_suffix: str


@dataclass(frozen=True)
class TemplateSelection:
    """Resolved template information after priority parsing."""

    key: str
    display_name: str
    output_suffix: str
    layout_path: Path
    template_path: Path
    source: str


# Central template registry keeps template-specific paths out of drawing logic.
TEMPLATE_REGISTRY: Dict[str, TemplateSpec] = {
    "a": TemplateSpec(
        key="a",
        display_name="Template A v1",
        layout_path="config/template_a_layout.json",
        template_path="assets/template_a_v1.png",
        output_suffix="a",
    ),
    "b": TemplateSpec(
        key="b",
        display_name="Template B v1",
        layout_path="config/template_b_layout.json",
        template_path="assets/template_b_v1.png",
        output_suffix="b",
    ),
    "c": TemplateSpec(
        key="c",
        display_name="Template C v1",
        layout_path="config/template_c_layout.json",
        template_path="assets/template_c_v1.png",
        output_suffix="c",
    ),
}


class FontManager:
    """Cache TrueType fonts so repeated size probes stay fast and deterministic."""

    def __init__(self, project_root: Path) -> None:
        # Use a dict cache keyed by absolute path and size.
        self._cache: Dict[Tuple[str, int], ImageFont.FreeTypeFont] = {}
        self._project_root = project_root

    def get(self, font_path: str, size: int) -> ImageFont.FreeTypeFont:
        """Return a loaded font from cache or disk."""
        abs_path = (self._project_root / font_path).resolve()
        key = (str(abs_path), size)
        if key in self._cache:
            return self._cache[key]

        if not abs_path.exists():
            raise FileNotFoundError(f"Font file not found: {abs_path}")

        # Pillow handles OTF/TTF loading via FreeType.
        self._cache[key] = ImageFont.truetype(str(abs_path), size=size)
        return self._cache[key]


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments for the renderer."""
    parser = argparse.ArgumentParser(description="Render AI Daily Poster PNG.")
    parser.add_argument(
        "--input",
        default="data/daily_brief.json",
        help="Path to daily_brief.json",
    )
    parser.add_argument(
        "--layout",
        default=None,
        help="Optional layout JSON override path (debug only)",
    )
    parser.add_argument(
        "--template",
        default=None,
        choices=ALLOWED_TEMPLATE_KEYS,
        help="Template key override (a|b|c), higher priority than JSON template",
    )
    parser.add_argument(
        "--template-path",
        default=None,
        help="Optional template background PNG override path (debug only)",
    )
    parser.add_argument(
        "--output-dir",
        default="output",
        help="Directory to save rendered poster",
    )
    parser.add_argument(
        "--debug-boxes",
        action="store_true",
        help="Export an extra debug image with layout/text boxes",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    """Load a JSON file and return parsed dict."""
    if not path.exists():
        raise FileNotFoundError(f"JSON file not found: {path}")
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def parse_color(color_value: str) -> Tuple[int, int, int, int]:
    """Parse #RRGGBB / #RRGGBBAA / rgba(r,g,b,a) into RGBA tuple."""
    color = color_value.strip()

    # Parse hex colors first because they are the most common in this project.
    if color.startswith("#"):
        hex_body = color[1:]
        if len(hex_body) == 6:
            r = int(hex_body[0:2], 16)
            g = int(hex_body[2:4], 16)
            b = int(hex_body[4:6], 16)
            return (r, g, b, 255)
        if len(hex_body) == 8:
            r = int(hex_body[0:2], 16)
            g = int(hex_body[2:4], 16)
            b = int(hex_body[4:6], 16)
            a = int(hex_body[6:8], 16)
            return (r, g, b, a)
        raise ValueError(f"Unsupported hex color format: {color_value}")

    # Parse rgba(...) with alpha in 0..1 or 0..255.
    rgba_match = re.fullmatch(
        r"rgba\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*([\d.]+)\s*\)",
        color,
    )
    if rgba_match:
        r = int(rgba_match.group(1))
        g = int(rgba_match.group(2))
        b = int(rgba_match.group(3))
        alpha_raw = float(rgba_match.group(4))

        for channel_name, channel_value in (("r", r), ("g", g), ("b", b)):
            if not 0 <= channel_value <= 255:
                raise ValueError(f"RGBA {channel_name} out of range in: {color_value}")

        if alpha_raw <= 1:
            a = int(round(alpha_raw * 255))
        else:
            a = int(round(alpha_raw))

        if not 0 <= a <= 255:
            raise ValueError(f"RGBA alpha out of range in: {color_value}")

        return (r, g, b, a)

    raise ValueError(f"Unsupported color format: {color_value}")


def normalize_text(raw_text: str) -> str:
    """Trim text and collapse accidental whitespace to keep line breaks stable."""
    return re.sub(r"\s+", " ", raw_text.strip())


def measure_text(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont) -> Tuple[int, int]:
    """Measure single-line text size via Pillow textbbox API."""
    if text == "":
        return (0, 0)
    bbox = draw.textbbox((0, 0), text, font=font)
    return (bbox[2] - bbox[0], bbox[3] - bbox[1])


def measure_multiline_text(
    draw: ImageDraw.ImageDraw,
    lines: Sequence[str],
    font: ImageFont.FreeTypeFont,
    spacing: int,
) -> Tuple[int, int]:
    """Measure multi-line text size via Pillow multiline_textbbox API."""
    if not lines:
        return (0, 0)
    text = "\n".join(lines)
    bbox = draw.multiline_textbbox((0, 0), text, font=font, spacing=spacing, align="center")
    return (bbox[2] - bbox[0], bbox[3] - bbox[1])


def wrap_text_by_width(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: int,
) -> List[str]:
    """Wrap text by character width, robust for both Chinese and mixed-language strings."""
    clean_text = normalize_text(text)
    if not clean_text:
        return [""]

    lines: List[str] = []
    current = ""

    # Character-level wrapping guarantees CJK and mixed punctuation safety.
    for char in clean_text:
        candidate = current + char
        candidate_width, _ = measure_text(draw, candidate, font)

        if current and candidate_width > max_width:
            lines.append(current.rstrip())
            current = char.lstrip()
        else:
            current = candidate

    if current:
        lines.append(current.rstrip())

    return [line for line in lines if line] or [""]


def truncate_single_line_with_ellipsis(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: int,
) -> str:
    """Truncate a line and append ellipsis if width exceeds max_width."""
    clean_text = normalize_text(text)
    ellipsis = "..."

    text_width, _ = measure_text(draw, clean_text, font)
    if text_width <= max_width:
        return clean_text

    ellipsis_width, _ = measure_text(draw, ellipsis, font)
    if ellipsis_width > max_width:
        return ""

    output = ""
    for char in clean_text:
        candidate = output + char
        candidate_width, _ = measure_text(draw, candidate + ellipsis, font)
        if candidate_width <= max_width:
            output = candidate
        else:
            break

    return output.rstrip() + ellipsis


def force_two_lines_with_ellipsis(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: int,
) -> List[str]:
    """Force text into at most two lines by truncating the second line with ellipsis."""
    wrapped = wrap_text_by_width(draw, text, font, max_width)

    if len(wrapped) <= 1:
        return [truncate_single_line_with_ellipsis(draw, wrapped[0], font, max_width)]

    first_line = wrapped[0]
    remainder = "".join(wrapped[1:])
    second_line = truncate_single_line_with_ellipsis(draw, remainder, font, max_width)

    if not second_line:
        # Keep graceful output even in narrow areas where only one line can survive.
        return [truncate_single_line_with_ellipsis(draw, first_line, font, max_width)]

    return [first_line, second_line]


def build_summary_variants(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: int,
) -> List[List[str]]:
    """Build summary candidates in strict order: single line -> two lines -> ellipsis."""
    variants: List[List[str]] = []

    clean_text = normalize_text(text)

    # 1) Single-line candidate.
    single_width, _ = measure_text(draw, clean_text, font)
    if single_width <= max_width:
        variants.append([clean_text])

    # 2) Natural two-line candidate.
    wrapped = wrap_text_by_width(draw, clean_text, font, max_width)
    if len(wrapped) <= 2:
        variants.append(wrapped)

    # 3) Two-line ellipsis fallback candidate.
    ellipsis_variant = force_two_lines_with_ellipsis(draw, clean_text, font, max_width)
    variants.append(ellipsis_variant)

    # Deduplicate variants while preserving the strict evaluation order.
    deduped: List[List[str]] = []
    seen: Set[Tuple[str, ...]] = set()
    for item in variants:
        key = tuple(item)
        if key not in seen:
            deduped.append(item)
            seen.add(key)

    return deduped


def build_title_line_options(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: int,
) -> Dict[str, List[str]]:
    """Build title line options for one-line and two-line rendering."""
    clean_text = normalize_text(text)

    options: Dict[str, List[str]] = {}

    # One-line option is only valid if width fits exactly.
    single_width, _ = measure_text(draw, clean_text, font)
    if single_width <= max_width:
        options["single"] = [clean_text]

    # Two-line natural wrap option.
    wrapped = wrap_text_by_width(draw, clean_text, font, max_width)
    if len(wrapped) <= 2:
        options["two"] = wrapped

    # Two-line ellipsis fallback option.
    options["two_ellipsis"] = force_two_lines_with_ellipsis(draw, clean_text, font, max_width)

    return options


def choose_card_text_layout(
    draw: ImageDraw.ImageDraw,
    title_text: str,
    summary_text: str,
    card_content_width: int,
    card_content_height: int,
    title_style: Dict[str, Any],
    summary_style: Dict[str, Any],
    gap: int,
    font_manager: FontManager,
    title_font_path: str,
    summary_font_path: str,
) -> Tuple[TextLayout, TextLayout]:
    """Select card title/summary layouts while honoring line rules and height limits."""
    summary_font_size = int(summary_style["font_size"])
    summary_min_font_size = int(summary_style.get("min_font_size", summary_font_size))
    summary_spacing = int(summary_style.get("line_spacing", 0))

    title_font_size = int(title_style["font_size"])
    title_min_font_size = int(title_style["min_font_size"])
    title_spacing = int(title_style.get("line_spacing", 0))

    # Pass 1: prefer single-line title and shrink font only if needed.
    for size in range(title_font_size, title_min_font_size - 1, -1):
        title_font = font_manager.get(title_font_path, size)
        options = build_title_line_options(draw, title_text, title_font, card_content_width)
        if "single" not in options:
            continue

        title_lines = options["single"]
        title_width, title_height = measure_multiline_text(draw, title_lines, title_font, title_spacing)

        for summary_size in range(summary_font_size, summary_min_font_size - 1, -1):
            summary_font = font_manager.get(summary_font_path, summary_size)
            summary_variants = build_summary_variants(
                draw,
                summary_text,
                summary_font,
                card_content_width,
            )
            for summary_lines in summary_variants:
                summary_width, summary_height = measure_multiline_text(
                    draw,
                    summary_lines,
                    summary_font,
                    summary_spacing,
                )
                combined_height = title_height + gap + summary_height
                if combined_height <= card_content_height:
                    return (
                        TextLayout(
                            lines=title_lines,
                            font=title_font,
                            spacing=title_spacing,
                            width=title_width,
                            height=title_height,
                        ),
                        TextLayout(
                            lines=summary_lines,
                            font=summary_font,
                            spacing=summary_spacing,
                            width=summary_width,
                            height=summary_height,
                        ),
                    )

    # Pass 2: fallback to two-line title (natural wrap first, then ellipsis) with auto font shrinking.
    for size in range(title_font_size, title_min_font_size - 1, -1):
        title_font = font_manager.get(title_font_path, size)
        options = build_title_line_options(draw, title_text, title_font, card_content_width)

        for key in ("two", "two_ellipsis"):
            if key not in options:
                continue

            title_lines = options[key]
            if len(title_lines) > 2:
                continue

            title_width, title_height = measure_multiline_text(draw, title_lines, title_font, title_spacing)

            for summary_size in range(summary_font_size, summary_min_font_size - 1, -1):
                summary_font = font_manager.get(summary_font_path, summary_size)
                summary_variants = build_summary_variants(
                    draw,
                    summary_text,
                    summary_font,
                    card_content_width,
                )
                for summary_lines in summary_variants:
                    summary_width, summary_height = measure_multiline_text(
                        draw,
                        summary_lines,
                        summary_font,
                        summary_spacing,
                    )
                    combined_height = title_height + gap + summary_height
                    if combined_height <= card_content_height:
                        return (
                            TextLayout(
                                lines=title_lines,
                                font=title_font,
                                spacing=title_spacing,
                                width=title_width,
                                height=title_height,
                            ),
                            TextLayout(
                                lines=summary_lines,
                                font=summary_font,
                                spacing=summary_spacing,
                                width=summary_width,
                                height=summary_height,
                            ),
                        )

    raise ValueError(
        "Card text cannot fit fixed card height under current constraints. "
        "Please shorten title/summary text in JSON."
    )


def parse_date(value: str) -> datetime:
    """Parse date string from JSON using allowed formats only."""
    for fmt in SUPPORTED_DATE_FORMATS:
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    raise ValueError("date must match YYYY.MM.DD or YYYY-MM-DD")


def validate_layout(layout: Dict[str, Any]) -> None:
    """Validate layout invariants before rendering."""
    canvas = layout.get("canvas", {})
    width = int(canvas.get("width", 0))
    height = int(canvas.get("height", 0))

    if width != REQUIRED_CANVAS_WIDTH or height != REQUIRED_CANVAS_HEIGHT:
        raise ValueError(
            f"Layout canvas must be {REQUIRED_CANVAS_WIDTH}x{REQUIRED_CANVAS_HEIGHT}, "
            f"got {width}x{height}."
        )

    cards = layout.get("news_cards", [])
    if len(cards) != REQUIRED_NEWS_COUNT:
        raise ValueError(f"layout.news_cards must contain exactly {REQUIRED_NEWS_COUNT} cards")

    heights = {int(card.get("h", 0)) for card in cards}
    if len(heights) != 1:
        raise ValueError("All news cards must keep fixed height")

    required_sections = [
        "safe_margin",
        "title_area",
        "date_area",
        "news_group_area",
        "card_padding",
        "forbidden_zone",
        "styles",
        "fonts",
    ]
    for section in required_sections:
        if section not in layout:
            raise ValueError(f"Missing layout section: {section}")


def validate_layout_template_metadata(layout: Dict[str, Any], selected_template: TemplateSelection) -> None:
    """Validate optional template metadata in layout for safer multi-template wiring."""
    layout_template_id = str(layout.get("template_id", "")).strip().lower()
    if layout_template_id and layout_template_id != selected_template.key:
        raise ValueError(
            f"Layout template_id '{layout_template_id}' does not match selected template '{selected_template.key}'"
        )

    layout_output_suffix = str(layout.get("output_suffix", "")).strip().lower()
    if layout_output_suffix and layout_output_suffix != selected_template.output_suffix:
        raise ValueError(
            f"Layout output_suffix '{layout_output_suffix}' does not match selected suffix '{selected_template.output_suffix}'"
        )


def validate_daily_brief(data: Dict[str, Any]) -> None:
    """Validate daily brief schema and hard constraints."""
    if "date" not in data:
        raise ValueError("daily_brief.json missing required field: date")

    items = data.get("items")
    if not isinstance(items, list):
        raise ValueError("daily_brief.json field items must be a list")
    if len(items) != REQUIRED_NEWS_COUNT:
        raise ValueError(f"daily_brief.json items must contain exactly {REQUIRED_NEWS_COUNT} news cards")

    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"items[{index}] must be an object")
        if not normalize_text(str(item.get("title", ""))):
            raise ValueError(f"items[{index}].title must not be empty")
        if not normalize_text(str(item.get("summary", ""))):
            raise ValueError(f"items[{index}].summary must not be empty")


def resolve_template_selection(
    project_root: Path,
    daily_brief: Dict[str, Any],
    cli_template_key: Optional[str],
    layout_override_path: Optional[Path],
    template_override_path: Optional[Path],
) -> TemplateSelection:
    """Resolve template key and resource paths using priority: CLI > JSON > default."""
    if cli_template_key is not None:
        # CLI key has the highest priority and is intended for debugging overrides.
        selected_key = str(cli_template_key).strip().lower()
        source = "cli"
    else:
        json_template = daily_brief.get("template")
        if json_template is None:
            selected_key = TEMPLATE_DEFAULT_KEY
            source = "default"
        else:
            # JSON is the standard production driver when CLI override is absent.
            selected_key = str(json_template).strip().lower()
            source = "json"

    if selected_key == "":
        raise ValueError("template cannot be empty; allowed values are a|b|c")

    if selected_key not in TEMPLATE_REGISTRY:
        raise ValueError(
            f"template must be one of {'|'.join(ALLOWED_TEMPLATE_KEYS)}; got '{selected_key}'"
        )

    spec = TEMPLATE_REGISTRY[selected_key]

    # CLI path overrides are optional and mainly for local troubleshooting.
    layout_path = layout_override_path or (project_root / spec.layout_path).resolve()
    template_path = template_override_path or (project_root / spec.template_path).resolve()

    return TemplateSelection(
        key=spec.key,
        display_name=spec.display_name,
        output_suffix=spec.output_suffix,
        layout_path=layout_path,
        template_path=template_path,
        source=source,
    )


def centered_text_xy(area: Dict[str, int], width: int, height: int) -> Tuple[float, float]:
    """Calculate top-left point to center a text box inside an area box."""
    x = area["x"] + (area["w"] - width) / 2
    y = area["y"] + (area["h"] - height) / 2
    return (x, y)


def draw_text_with_glow(
    image: Image.Image,
    position: Tuple[float, float],
    text: str,
    font: ImageFont.FreeTypeFont,
    text_color: Tuple[int, int, int, int],
    glow_color: Tuple[int, int, int, int],
    glow_blur: int,
    multiline_spacing: int = 0,
) -> None:
    """Draw text with optional glow using a temporary blurred layer."""
    x, y = position

    if glow_blur > 0:
        glow_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        glow_draw = ImageDraw.Draw(glow_layer)
        if "\n" in text:
            glow_draw.multiline_text((x, y), text, font=font, fill=glow_color, spacing=multiline_spacing, align="center")
        else:
            glow_draw.text((x, y), text, font=font, fill=glow_color)
        blurred = glow_layer.filter(ImageFilter.GaussianBlur(glow_blur))
        image.alpha_composite(blurred)

    final_draw = ImageDraw.Draw(image)
    if "\n" in text:
        final_draw.multiline_text((x, y), text, font=font, fill=text_color, spacing=multiline_spacing, align="center")
    else:
        final_draw.text((x, y), text, font=font, fill=text_color)


def draw_card_container(
    image: Image.Image,
    card: Dict[str, int],
    style: Dict[str, Any],
) -> None:
    """Draw rounded card background, border, and subtle glow."""
    x = int(card["x"])
    y = int(card["y"])
    w = int(card["w"])
    h = int(card["h"])

    rect = (x, y, x + w, y + h)
    radius = int(style["radius"])
    border_width = int(style["border_width"])

    fill_color = parse_color(style["fill"])
    border_color = parse_color(style["border_color"])
    glow_color = parse_color(style.get("glow_color", style["border_color"]))
    glow_blur = int(style.get("glow_blur", 0))

    if glow_blur > 0:
        glow_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        glow_draw = ImageDraw.Draw(glow_layer)
        glow_draw.rounded_rectangle(
            rect,
            radius=radius,
            outline=glow_color,
            width=max(1, border_width + 1),
        )
        blurred = glow_layer.filter(ImageFilter.GaussianBlur(glow_blur))
        image.alpha_composite(blurred)

    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        rect,
        radius=radius,
        fill=fill_color,
        outline=border_color,
        width=border_width,
    )


def ensure_template_size(image: Image.Image, canvas: Dict[str, Any]) -> None:
    """Enforce strict template size, no auto scaling allowed."""
    expected_w = int(canvas["width"])
    expected_h = int(canvas["height"])
    actual_w, actual_h = image.size

    if actual_w != expected_w or actual_h != expected_h:
        raise ValueError(
            f"Template size must be {expected_w}x{expected_h}, got {actual_w}x{actual_h}. "
            "Auto-resize is disabled by hard rule."
        )


def validate_area_fits_single_line(
    draw: ImageDraw.ImageDraw,
    area: Dict[str, int],
    text: str,
    font: ImageFont.FreeTypeFont,
    label: str,
) -> Tuple[int, int]:
    """Validate fixed single-line text can fit its assigned area."""
    text_width, text_height = measure_text(draw, text, font)
    if text_width > area["w"] or text_height > area["h"]:
        raise ValueError(
            f"{label} does not fit area {area['w']}x{area['h']} with measured size "
            f"{text_width}x{text_height}."
        )
    return (text_width, text_height)


def enforce_forbidden_zone(text_bbox: Tuple[float, float, float, float], limit_y: int, label: str) -> None:
    """Reject layouts where important text enters forbidden bottom highlight zone."""
    if text_bbox[3] > limit_y:
        raise ValueError(
            f"{label} exceeds forbidden zone bottom_text_limit_y={limit_y} (actual bottom={text_bbox[3]:.1f})."
        )


def draw_debug_boxes(
    image: Image.Image,
    layout: Dict[str, Any],
    text_boxes: List[Tuple[str, Tuple[float, float, float, float]]],
) -> None:
    """Overlay safe area, major regions, card boxes, forbidden line, and text bounds."""
    debug_style = layout["styles"].get("debug", {})

    safe_margin_color = parse_color(debug_style.get("safe_margin_color", "rgba(255,255,0,0.9)"))
    area_color = parse_color(debug_style.get("area_color", "rgba(88,235,255,0.9)"))
    card_color = parse_color(debug_style.get("card_color", "rgba(255,154,54,0.95)"))
    forbidden_color = parse_color(debug_style.get("forbidden_color", "rgba(255,45,45,0.95)"))
    text_bbox_color = parse_color(debug_style.get("text_bbox_color", "rgba(255,255,255,0.9)"))
    line_width = int(debug_style.get("line_width", 2))

    draw = ImageDraw.Draw(image)
    canvas_w = int(layout["canvas"]["width"])
    canvas_h = int(layout["canvas"]["height"])

    safe = layout["safe_margin"]
    safe_rect = (
        int(safe["left"]),
        int(safe["top"]),
        canvas_w - int(safe["right"]),
        canvas_h - int(safe["bottom"]),
    )
    draw.rectangle(safe_rect, outline=safe_margin_color, width=line_width)

    for area_key in ("title_area", "date_area", "news_group_area"):
        area = layout[area_key]
        draw.rectangle(
            (
                int(area["x"]),
                int(area["y"]),
                int(area["x"] + area["w"]),
                int(area["y"] + area["h"]),
            ),
            outline=area_color,
            width=line_width,
        )

    for card in layout["news_cards"]:
        draw.rectangle(
            (
                int(card["x"]),
                int(card["y"]),
                int(card["x"] + card["w"]),
                int(card["y"] + card["h"]),
            ),
            outline=card_color,
            width=line_width,
        )

    forbidden_y = int(layout["forbidden_zone"]["bottom_text_limit_y"])
    draw.line((0, forbidden_y, canvas_w, forbidden_y), fill=forbidden_color, width=line_width)

    for _, bbox in text_boxes:
        draw.rectangle(bbox, outline=text_bbox_color, width=max(1, line_width - 1))


def render_poster(
    project_root: Path,
    input_path: Path,
    output_dir: Path,
    debug_boxes: bool,
    cli_template_key: Optional[str] = None,
    layout_override_path: Optional[Path] = None,
    template_override_path: Optional[Path] = None,
) -> Tuple[Path, Optional[Path], TemplateSelection]:
    """Render poster image according to strict project constraints."""
    daily_brief = load_json(input_path)
    validate_daily_brief(daily_brief)

    # Resolve template resources from a single priority function.
    selected_template = resolve_template_selection(
        project_root=project_root,
        daily_brief=daily_brief,
        cli_template_key=cli_template_key,
        layout_override_path=layout_override_path,
        template_override_path=template_override_path,
    )

    layout = load_json(selected_template.layout_path)
    validate_layout(layout)
    validate_layout_template_metadata(layout, selected_template)

    date_obj = parse_date(str(daily_brief["date"]))
    date_text = date_obj.strftime("%Y.%m.%d")
    output_name = f"poster_{date_obj.strftime('%Y_%m_%d')}_{selected_template.output_suffix}.png"

    # Open template in RGBA mode because cards and glow use alpha composition.
    template_image = Image.open(selected_template.template_path).convert("RGBA")
    ensure_template_size(template_image, layout["canvas"])

    draw = ImageDraw.Draw(template_image)
    font_manager = FontManager(project_root)

    styles = layout["styles"]
    fonts = layout["fonts"]

    # Load fonts used in fixed sections first so fit checks are explicit and early.
    title_font = font_manager.get(fonts["title"], int(styles["title"]["font_size"]))
    date_font = font_manager.get(fonts["date"], int(styles["date"]["font_size"]))

    # Validate title/date with fixed single-line constraints.
    title_area = layout["title_area"]
    date_area = layout["date_area"]

    title_text = styles["title"].get("text", FIXED_MAIN_TITLE)
    if title_text != FIXED_MAIN_TITLE:
        raise ValueError(f"Main title must stay fixed as '{FIXED_MAIN_TITLE}'")

    title_w, title_h = validate_area_fits_single_line(draw, title_area, title_text, title_font, "Main title")
    date_w, date_h = validate_area_fits_single_line(draw, date_area, date_text, date_font, "Date")

    # Draw five card containers before text so typography stays crisp on top.
    for card in layout["news_cards"]:
        draw_card_container(template_image, card, styles["card_container"])

    text_boxes: List[Tuple[str, Tuple[float, float, float, float]]] = []
    bottom_limit_y = int(layout["forbidden_zone"]["bottom_text_limit_y"])

    # Draw title with optional glow.
    title_x, title_y = centered_text_xy(title_area, title_w, title_h)
    draw_text_with_glow(
        image=template_image,
        position=(title_x, title_y),
        text=title_text,
        font=title_font,
        text_color=parse_color(styles["title"]["color"]),
        glow_color=parse_color(styles["title"]["glow_color"]),
        glow_blur=int(styles["title"].get("glow_blur", 0)),
    )
    title_bbox = (title_x, title_y, title_x + title_w, title_y + title_h)
    text_boxes.append(("main_title", title_bbox))
    enforce_forbidden_zone(title_bbox, bottom_limit_y, "Main title")

    # Draw date text.
    date_x, date_y = centered_text_xy(date_area, date_w, date_h)
    draw_text_with_glow(
        image=template_image,
        position=(date_x, date_y),
        text=date_text,
        font=date_font,
        text_color=parse_color(styles["date"]["color"]),
        glow_color=parse_color(styles["date"]["color"]),
        glow_blur=0,
    )
    date_bbox = (date_x, date_y, date_x + date_w, date_y + date_h)
    text_boxes.append(("date", date_bbox))
    enforce_forbidden_zone(date_bbox, bottom_limit_y, "Date")

    # Render news cards text content with fixed count and fixed card heights.
    padding = layout["card_padding"]
    title_style = styles["card_title"]
    summary_style = styles["card_summary"]
    title_summary_gap = int(styles["card_content"].get("title_summary_gap", 0))

    items = daily_brief["items"]
    if len(items) != REQUIRED_NEWS_COUNT:
        raise ValueError(f"Exactly {REQUIRED_NEWS_COUNT} items are required")

    for index, card in enumerate(layout["news_cards"]):
        item = items[index]

        content_x = int(card["x"]) + int(padding["left_right"])
        content_y = int(card["y"]) + int(padding["top"])
        content_w = int(card["w"]) - 2 * int(padding["left_right"])
        content_h = int(card["h"]) - int(padding["top"]) - int(padding["bottom"])

        if content_w <= 0 or content_h <= 0:
            raise ValueError(f"Card {index + 1} content area is invalid: {content_w}x{content_h}")

        title_layout, summary_layout = choose_card_text_layout(
            draw=draw,
            title_text=str(item["title"]),
            summary_text=str(item["summary"]),
            card_content_width=content_w,
            card_content_height=content_h,
            title_style=title_style,
            summary_style=summary_style,
            gap=title_summary_gap,
            font_manager=font_manager,
            title_font_path=fonts["card_title"],
            summary_font_path=fonts["card_summary"],
        )

        total_text_height = title_layout.height + title_summary_gap + summary_layout.height
        title_y = content_y + (content_h - total_text_height) / 2
        summary_y = title_y + title_layout.height + title_summary_gap

        title_text_block = "\n".join(title_layout.lines)
        title_x = content_x + (content_w - title_layout.width) / 2
        draw_text_with_glow(
            image=template_image,
            position=(title_x, title_y),
            text=title_text_block,
            font=title_layout.font,
            text_color=parse_color(title_style["color"]),
            glow_color=parse_color(title_style["color"]),
            glow_blur=0,
            multiline_spacing=title_layout.spacing,
        )
        title_bbox = (
            title_x,
            title_y,
            title_x + title_layout.width,
            title_y + title_layout.height,
        )
        text_boxes.append((f"card_{index + 1}_title", title_bbox))
        enforce_forbidden_zone(title_bbox, bottom_limit_y, f"Card {index + 1} title")

        summary_text_block = "\n".join(summary_layout.lines)
        summary_x = content_x + (content_w - summary_layout.width) / 2
        draw_text_with_glow(
            image=template_image,
            position=(summary_x, summary_y),
            text=summary_text_block,
            font=summary_layout.font,
            text_color=parse_color(summary_style["color"]),
            glow_color=parse_color(summary_style["color"]),
            glow_blur=0,
            multiline_spacing=summary_layout.spacing,
        )
        summary_bbox = (
            summary_x,
            summary_y,
            summary_x + summary_layout.width,
            summary_y + summary_layout.height,
        )
        text_boxes.append((f"card_{index + 1}_summary", summary_bbox))
        enforce_forbidden_zone(summary_bbox, bottom_limit_y, f"Card {index + 1} summary")

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / output_name
    template_image.save(output_path)

    debug_path: Optional[Path] = None
    if debug_boxes:
        debug_image = template_image.copy()
        draw_debug_boxes(debug_image, layout, text_boxes)
        debug_path = output_dir / output_name.replace(".png", "_debug.png")
        debug_image.save(debug_path)

    return output_path, debug_path, selected_template


def main() -> None:
    """Entry point with controlled error output for local scripting workflows."""
    args = parse_args()
    project_root = Path(__file__).resolve().parent

    input_path = (project_root / args.input).resolve()
    output_dir = (project_root / args.output_dir).resolve()
    layout_override_path = (project_root / args.layout).resolve() if args.layout else None
    template_override_path = (project_root / args.template_path).resolve() if args.template_path else None

    try:
        output_path, debug_path, selected_template = render_poster(
            project_root=project_root,
            input_path=input_path,
            output_dir=output_dir,
            debug_boxes=args.debug_boxes,
            cli_template_key=args.template,
            layout_override_path=layout_override_path,
            template_override_path=template_override_path,
        )
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)

    print(
        "[INFO] Template selected: "
        f"{selected_template.key} ({selected_template.display_name}), source={selected_template.source}"
    )
    print(f"[OK] Poster generated: {output_path}")
    if debug_path:
        print(f"[OK] Debug image generated: {debug_path}")


if __name__ == "__main__":
    main()
