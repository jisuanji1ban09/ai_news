#!/usr/bin/env python3
"""Render short MP4 video from poster PNG + daily_brief JSON + template regions config."""

import argparse
import json
import logging
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from PIL import Image

# 将项目根目录加入导入路径，复用现有海报链路的校验逻辑。
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from render_poster import (  # noqa: E402
    ALLOWED_TEMPLATE_KEYS,
    REQUIRED_CANVAS_HEIGHT,
    REQUIRED_CANVAS_WIDTH,
    REQUIRED_NEWS_COUNT,
    TEMPLATE_REGISTRY,
    TEMPLATE_DEFAULT_KEY,
    validate_daily_brief,
)

# MVP 固定视频参数。
OUTPUT_WIDTH = 1080
OUTPUT_HEIGHT = 1920
OUTPUT_FPS = 30
OUTPUT_DURATION_SECONDS = 15

# 按产品约束固定分镜时长。
INTRO_DURATION_SECONDS = 2
FOCUS_DURATION_SECONDS = 2
OUTRO_DURATION_SECONDS = 3

# 增强后的镜头参数（可继续按视觉反馈微调）。
INTRO_ZOOM_START = 1.00
INTRO_ZOOM_END = 1.14
FOCUS_ZOOM_START = 1.20
FOCUS_ZOOM_END = 1.48
OUTRO_ZOOM_START = 1.22
OUTRO_ZOOM_END = 1.00

# 聚焦遮罩与亮框样式。
FOCUS_DIM_ALPHA = 0.38
FOCUS_BORDER_COLOR = "0x7CE5FF"


@dataclass(frozen=True)
class Region:
    """One focus region for one news card."""

    index: int
    x: int
    y: int
    w: int
    h: int


@dataclass(frozen=True)
class RegionsConfig:
    """Parsed and validated regions configuration."""

    template: str
    canvas_width: int
    canvas_height: int
    regions: Sequence[Region]


@dataclass(frozen=True)
class ScenePlan:
    """One scene segment in the final 15-second timeline."""

    name: str
    start_sec: float
    end_sec: float
    frames: int
    zoom_start: float
    zoom_end: float
    focus_start_center: Tuple[float, float]
    focus_end_center: Tuple[float, float]
    highlight: bool
    fade_in: bool
    region_index: Optional[int]
    region_x: int
    region_y: int
    region_w: int
    region_h: int


class RenderVideoError(RuntimeError):
    """Typed runtime error with clear, retry-friendly message."""


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments for local MP4 rendering."""
    parser = argparse.ArgumentParser(description="Render 15s 1080x1920 MP4 from generated poster")
    parser.add_argument("--poster", required=True, help="Poster PNG path (expected 1365x2048)")
    parser.add_argument("--brief", required=True, help="daily_brief.json path")
    parser.add_argument(
        "--regions",
        default=None,
        help="Optional regions config JSON path. If omitted, auto use config/video_regions_{template}.json",
    )
    parser.add_argument("--output", required=True, help="Output mp4 path")
    parser.add_argument(
        "--log",
        default=None,
        help="Optional log path. Default: <output_dir>/render_video.log",
    )
    parser.add_argument(
        "--ffmpeg-bin",
        default="ffmpeg",
        help="ffmpeg executable name or absolute path",
    )
    parser.add_argument(
        "--debug-frames-dir",
        default=None,
        help="Optional directory to export key debug frames from final MP4",
    )
    return parser.parse_args()


def setup_logger(log_path: Path) -> logging.Logger:
    """Build dual logger (stdout + local file) for auditability."""
    log_path.parent.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("render_video")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    return logger


def ensure_file_exists(path: Path, label: str) -> None:
    """Fail early when required input file is missing."""
    if not path.exists() or not path.is_file():
        raise RenderVideoError(f"{label} file not found: {path}")


def load_json_dict(path: Path, label: str) -> Dict[str, Any]:
    """Read JSON object file with explicit parse errors."""
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except json.JSONDecodeError as exc:
        raise RenderVideoError(f"{label} JSON is invalid: {exc}") from exc

    if not isinstance(payload, dict):
        raise RenderVideoError(f"{label} JSON must be an object")

    return payload


def resolve_template_from_brief(brief: Dict[str, Any]) -> str:
    """Resolve template using same fallback policy as poster renderer."""
    raw_template = brief.get("template", TEMPLATE_DEFAULT_KEY)
    template = str(raw_template).strip().lower()

    if not template:
        raise RenderVideoError("brief template cannot be empty; allowed values are a|b|c")

    if template not in ALLOWED_TEMPLATE_KEYS:
        raise RenderVideoError(f"brief template must be one of a|b|c, got '{template}'")

    return template


def parse_regions_config(payload: Dict[str, Any]) -> RegionsConfig:
    """Parse regions config structure and enforce strict schema."""
    template = str(payload.get("template", "")).strip().lower()
    if template not in ALLOWED_TEMPLATE_KEYS:
        raise RenderVideoError(f"regions template must be one of a|b|c, got '{template}'")

    canvas = payload.get("canvas")
    if not isinstance(canvas, dict):
        raise RenderVideoError("regions canvas must be an object")

    try:
        canvas_width = int(canvas.get("width"))
        canvas_height = int(canvas.get("height"))
    except (TypeError, ValueError) as exc:
        raise RenderVideoError("regions canvas.width/canvas.height must be integers") from exc

    if canvas_width != REQUIRED_CANVAS_WIDTH or canvas_height != REQUIRED_CANVAS_HEIGHT:
        raise RenderVideoError(
            "regions canvas must be 1365x2048 to match poster template constraints, "
            f"got {canvas_width}x{canvas_height}"
        )

    raw_regions = payload.get("regions")
    if not isinstance(raw_regions, list):
        raise RenderVideoError("regions.regions must be a list")
    if len(raw_regions) != REQUIRED_NEWS_COUNT:
        raise RenderVideoError(f"regions.regions must contain exactly {REQUIRED_NEWS_COUNT} entries")

    parsed_regions: List[Region] = []
    seen_indices = set()
    for item in raw_regions:
        if not isinstance(item, dict):
            raise RenderVideoError("every regions entry must be an object")

        try:
            index = int(item.get("index"))
            x = int(item.get("x"))
            y = int(item.get("y"))
            w = int(item.get("w"))
            h = int(item.get("h"))
        except (TypeError, ValueError) as exc:
            raise RenderVideoError("region fields index/x/y/w/h must be integers") from exc

        if index < 1 or index > REQUIRED_NEWS_COUNT:
            raise RenderVideoError(f"region index out of range [1,5]: {index}")
        if index in seen_indices:
            raise RenderVideoError(f"duplicated region index found: {index}")
        seen_indices.add(index)

        if w <= 0 or h <= 0:
            raise RenderVideoError(f"region {index} size must be positive, got {w}x{h}")
        if x < 0 or y < 0:
            raise RenderVideoError(f"region {index} x/y must be >= 0, got x={x}, y={y}")

        if x + w > canvas_width or y + h > canvas_height:
            raise RenderVideoError(
                f"region {index} out of canvas bounds: x={x}, y={y}, w={w}, h={h}, "
                f"canvas={canvas_width}x{canvas_height}"
            )

        parsed_regions.append(Region(index=index, x=x, y=y, w=w, h=h))

    # 对区域按 index 排序，确保分镜顺序稳定可复现。
    parsed_regions.sort(key=lambda region: region.index)

    return RegionsConfig(
        template=template,
        canvas_width=canvas_width,
        canvas_height=canvas_height,
        regions=parsed_regions,
    )


def validate_poster_size(poster_path: Path, expected_width: int, expected_height: int) -> None:
    """Verify poster dimensions before building any ffmpeg command."""
    with Image.open(poster_path) as image:
        width, height = image.size

    if width != expected_width or height != expected_height:
        raise RenderVideoError(
            f"poster size must be {expected_width}x{expected_height}, got {width}x{height}"
        )


def compute_center_crop(canvas_width: int, canvas_height: int) -> Tuple[int, int, int, int]:
    """Compute center crop window to convert poster ratio to 9:16 output ratio."""
    target_ratio = OUTPUT_WIDTH / OUTPUT_HEIGHT
    current_ratio = canvas_width / canvas_height

    if current_ratio > target_ratio:
        # 海报更宽：优先左右裁切，保证上下信息完整。
        crop_h = canvas_height
        crop_w = int(round(crop_h * target_ratio))
        crop_x = (canvas_width - crop_w) // 2
        crop_y = 0
    else:
        # 海报更窄：优先上下裁切，保证左右信息完整。
        crop_w = canvas_width
        crop_h = int(round(crop_w / target_ratio))
        crop_x = 0
        crop_y = (canvas_height - crop_h) // 2

    return (crop_x, crop_y, crop_w, crop_h)


def clamp(value: float, lower: float, upper: float) -> float:
    """Clamp helper for focus center safety."""
    return max(lower, min(upper, value))


def to_crop_space_center(region: Region, crop_box: Tuple[int, int, int, int]) -> Tuple[float, float]:
    """Convert region center from poster canvas to cropped 9:16 coordinate space."""
    crop_x, crop_y, crop_w, crop_h = crop_box

    center_x = region.x + (region.w / 2.0) - crop_x
    center_y = region.y + (region.h / 2.0) - crop_y

    safe_x = clamp(center_x, 0.0, float(crop_w))
    safe_y = clamp(center_y, 0.0, float(crop_h))
    return (safe_x, safe_y)


def build_scene_plan(regions: Sequence[Region], crop_box: Tuple[int, int, int, int]) -> List[ScenePlan]:
    """Build fixed 15s sequence: intro -> 5 focus scenes -> outro."""
    _, _, crop_w, crop_h = crop_box
    center_full = (crop_w / 2.0, crop_h / 2.0)

    timeline: List[ScenePlan] = []
    cursor = 0.0

    intro_end = cursor + INTRO_DURATION_SECONDS
    intro_start_center = (center_full[0], clamp(center_full[1] + 120.0, 0.0, float(crop_h)))
    timeline.append(
        ScenePlan(
            name="intro_full",
            start_sec=cursor,
            end_sec=intro_end,
            frames=INTRO_DURATION_SECONDS * OUTPUT_FPS,
            zoom_start=INTRO_ZOOM_START,
            zoom_end=INTRO_ZOOM_END,
            focus_start_center=intro_start_center,
            focus_end_center=center_full,
            highlight=False,
            fade_in=True,
            region_index=None,
            region_x=0,
            region_y=0,
            region_w=0,
            region_h=0,
        )
    )
    cursor = intro_end

    last_focus_center = center_full
    for region in regions:
        end_sec = cursor + FOCUS_DURATION_SECONDS
        target_center = to_crop_space_center(region, crop_box)

        # 每段给一个可见的起始偏移，确保镜头移动在肉眼上明显可见。
        x_offset = -130.0 if region.index % 2 == 1 else 130.0
        y_offset = 180.0 if region.index in (1, 3, 5) else -180.0
        start_center = (
            clamp(target_center[0] + x_offset, 0.0, float(crop_w)),
            clamp(target_center[1] + y_offset, 0.0, float(crop_h)),
        )

        timeline.append(
            ScenePlan(
                name=f"focus_card_{region.index}",
                start_sec=cursor,
                end_sec=end_sec,
                frames=FOCUS_DURATION_SECONDS * OUTPUT_FPS,
                zoom_start=FOCUS_ZOOM_START,
                zoom_end=FOCUS_ZOOM_END,
                focus_start_center=start_center,
                focus_end_center=target_center,
                highlight=True,
                fade_in=False,
                region_index=region.index,
                region_x=region.x,
                region_y=region.y,
                region_w=region.w,
                region_h=region.h,
            )
        )
        last_focus_center = target_center
        cursor = end_sec

    outro_end = cursor + OUTRO_DURATION_SECONDS
    timeline.append(
        ScenePlan(
            name="outro_full",
            start_sec=cursor,
            end_sec=outro_end,
            frames=OUTRO_DURATION_SECONDS * OUTPUT_FPS,
            zoom_start=OUTRO_ZOOM_START,
            zoom_end=OUTRO_ZOOM_END,
            focus_start_center=last_focus_center,
            focus_end_center=center_full,
            highlight=False,
            fade_in=False,
            region_index=None,
            region_x=0,
            region_y=0,
            region_w=0,
            region_h=0,
        )
    )

    if round(outro_end, 2) != float(OUTPUT_DURATION_SECONDS):
        raise RenderVideoError(
            f"scene timeline must total {OUTPUT_DURATION_SECONDS}s, got {outro_end}s"
        )

    return timeline


def apply_layout_card_geometry_to_scenes(
    scenes: Sequence[ScenePlan],
    layout_card_regions: Dict[int, Region],
) -> List[ScenePlan]:
    """Replace scene highlight geometry with exact card boxes used by render_poster layout."""
    patched: List[ScenePlan] = []
    for scene in scenes:
        if scene.region_index is None:
            patched.append(scene)
            continue

        layout_region = layout_card_regions.get(scene.region_index)
        if layout_region is None:
            raise RenderVideoError(
                f"layout card region missing for index {scene.region_index}"
            )

        patched.append(
            ScenePlan(
                name=scene.name,
                start_sec=scene.start_sec,
                end_sec=scene.end_sec,
                frames=scene.frames,
                zoom_start=scene.zoom_start,
                zoom_end=scene.zoom_end,
                focus_start_center=scene.focus_start_center,
                focus_end_center=scene.focus_end_center,
                highlight=scene.highlight,
                fade_in=scene.fade_in,
                region_index=scene.region_index,
                region_x=layout_region.x,
                region_y=layout_region.y,
                region_w=layout_region.w,
                region_h=layout_region.h,
            )
        )
    return patched


def build_zoom_expr(zoom_start: float, zoom_end: float, frames: int) -> str:
    """Generate stable ffmpeg zoom expression for linear per-frame movement."""
    if frames < 2:
        return f"{zoom_start:.6f}"

    step = (zoom_end - zoom_start) / float(frames - 1)
    if step >= 0:
        return (
            f"if(eq(on,0),{zoom_start:.6f},min({zoom_end:.6f},zoom+{step:.8f}))"
        )

    # 负步长用于结尾回拉镜头（缩小）。
    return (
        f"if(eq(on,0),{zoom_start:.6f},max({zoom_end:.6f},zoom{step:.8f}))"
    )


def estimate_mapped_highlight_box(
    scene: ScenePlan,
    crop_box: Tuple[int, int, int, int],
    progress: float,
) -> Tuple[int, int, int, int]:
    """Estimate mapped highlight box in output space for logging/debug checks."""
    if scene.region_index is None:
        return (0, 0, 0, 0)

    crop_x, crop_y, crop_w, crop_h = crop_box
    p = clamp(progress, 0.0, 1.0)
    zoom = scene.zoom_start + (scene.zoom_end - scene.zoom_start) * p
    focus_x = scene.focus_start_center[0] + (scene.focus_end_center[0] - scene.focus_start_center[0]) * p
    focus_y = scene.focus_start_center[1] + (scene.focus_end_center[1] - scene.focus_start_center[1]) * p

    pan_x = clamp(focus_x - (crop_w / (2.0 * zoom)), 0.0, crop_w - (crop_w / zoom))
    pan_y = clamp(focus_y - (crop_h / (2.0 * zoom)), 0.0, crop_h - (crop_h / zoom))

    scale_x = (OUTPUT_WIDTH / crop_w) * zoom
    scale_y = (OUTPUT_HEIGHT / crop_h) * zoom

    region_crop_x = scene.region_x - crop_x
    region_crop_y = scene.region_y - crop_y

    raw_x = (region_crop_x - pan_x) * scale_x
    raw_y = (region_crop_y - pan_y) * scale_y
    raw_w = scene.region_w * scale_x
    raw_h = scene.region_h * scale_y

    mapped_x = clamp(raw_x, 0.0, OUTPUT_WIDTH - 2.0)
    mapped_y = clamp(raw_y, 0.0, OUTPUT_HEIGHT - 2.0)
    mapped_right = clamp(raw_x + raw_w, 2.0, float(OUTPUT_WIDTH))
    mapped_bottom = clamp(raw_y + raw_h, 2.0, float(OUTPUT_HEIGHT))
    mapped_w = max(2.0, mapped_right - mapped_x)
    mapped_h = max(2.0, mapped_bottom - mapped_y)

    return (
        int(round(mapped_x)),
        int(round(mapped_y)),
        int(round(mapped_w)),
        int(round(mapped_h)),
    )


def build_focus_overlay_filters_in_crop(
    scene: ScenePlan,
    crop_box: Tuple[int, int, int, int],
) -> List[str]:
    """Build dim mask + bright focus box in crop space so it follows zoom/pan exactly."""
    if scene.region_index is None:
        return []

    crop_x, crop_y, crop_w, crop_h = crop_box

    region_crop_x = int(round(clamp(scene.region_x - crop_x, 0.0, crop_w - 2.0)))
    region_crop_y = int(round(clamp(scene.region_y - crop_y, 0.0, crop_h - 2.0)))
    region_crop_w = int(round(clamp(scene.region_w, 2.0, crop_w - region_crop_x)))
    region_crop_h = int(round(clamp(scene.region_h, 2.0, crop_h - region_crop_y)))

    region_right = region_crop_x + region_crop_w
    region_bottom = region_crop_y + region_crop_h

    return [
        # 上下左右四块遮罩：压暗非焦点区域。
        f"drawbox=x=0:y=0:w={crop_w}:h={region_crop_y}:color=black@{FOCUS_DIM_ALPHA:.2f}:t=fill",
        (
            "drawbox="
            f"x=0:y={region_bottom}:w={crop_w}:h={max(0, crop_h - region_bottom)}:"
            f"color=black@{FOCUS_DIM_ALPHA:.2f}:t=fill"
        ),
        (
            "drawbox="
            f"x=0:y={region_crop_y}:w={region_crop_x}:h={region_crop_h}:"
            f"color=black@{FOCUS_DIM_ALPHA:.2f}:t=fill"
        ),
        (
            "drawbox="
            f"x={region_right}:y={region_crop_y}:w={max(0, crop_w - region_right)}:h={region_crop_h}:"
            f"color=black@{FOCUS_DIM_ALPHA:.2f}:t=fill"
        ),
        # 焦点区提亮 + 双层亮框。
        (
            "drawbox="
            f"x={region_crop_x}:y={region_crop_y}:w={region_crop_w}:h={region_crop_h}:"
            f"color={FOCUS_BORDER_COLOR}@0.16:t=fill"
        ),
        (
            "drawbox="
            f"x={region_crop_x}:y={region_crop_y}:w={region_crop_w}:h={region_crop_h}:"
            f"color={FOCUS_BORDER_COLOR}@1.00:t=4"
        ),
        (
            "drawbox="
            f"x={max(0, region_crop_x - 10)}:y={max(0, region_crop_y - 10)}:"
            f"w={min(crop_w - max(0, region_crop_x - 10), region_crop_w + 20)}:"
            f"h={min(crop_h - max(0, region_crop_y - 10), region_crop_h + 20)}:"
            f"color={FOCUS_BORDER_COLOR}@0.45:t=3"
        ),
    ]


def build_scene_filter(scene: ScenePlan, crop_box: Tuple[int, int, int, int]) -> str:
    """Build ffmpeg filter graph for one scene segment."""
    crop_x, crop_y, crop_w, crop_h = crop_box
    focus_start_x, focus_start_y = scene.focus_start_center
    focus_end_x, focus_end_y = scene.focus_end_center

    zoom_expr = build_zoom_expr(scene.zoom_start, scene.zoom_end, scene.frames)
    pan_denom = max(1, scene.frames - 1)
    focus_x_expr = (
        f"({focus_start_x:.3f}+(({focus_end_x:.3f})-({focus_start_x:.3f}))*on/{pan_denom})"
    )
    focus_y_expr = (
        f"({focus_start_y:.3f}+(({focus_end_y:.3f})-({focus_start_y:.3f}))*on/{pan_denom})"
    )
    x_expr = f"max(0,min({focus_x_expr}-iw/zoom/2,iw-iw/zoom))"
    y_expr = f"max(0,min({focus_y_expr}-ih/zoom/2,ih-ih/zoom))"

    filters = [
        f"crop={crop_w}:{crop_h}:{crop_x}:{crop_y}",
        (
            "zoompan="
            f"z='{zoom_expr}':"
            f"x='{x_expr}':"
            f"y='{y_expr}':"
            f"d={scene.frames}:"
            f"s={OUTPUT_WIDTH}x{OUTPUT_HEIGHT}:"
            f"fps={OUTPUT_FPS}"
        ),
    ]

    if scene.fade_in:
        filters.append("fade=t=in:st=0:d=0.8")

    if scene.highlight and scene.region_index is not None:
        # 在 zoompan 之前绘制高亮层，保证高亮框与卡片完全同步移动和缩放。
        filters.extend(build_focus_overlay_filters_in_crop(scene=scene, crop_box=crop_box))

    filters.append("format=yuv420p")
    return ",".join(filters)


def run_ffmpeg(command: Sequence[str], logger: logging.Logger, step_name: str) -> None:
    """Run ffmpeg subprocess and raise explicit error with stderr details."""
    logger.info("ffmpeg start [%s]", step_name)
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as exc:
        raise RenderVideoError(f"failed to execute ffmpeg for {step_name}: {exc}") from exc

    if result.returncode != 0:
        stderr_text = result.stderr.strip() or "(empty stderr)"
        raise RenderVideoError(
            f"ffmpeg failed at {step_name} with exit code {result.returncode}: {stderr_text}"
        )

    logger.info("ffmpeg end [%s]", step_name)


def ensure_ffmpeg_available(ffmpeg_bin: str) -> str:
    """Resolve ffmpeg executable path, support both PATH name and absolute path."""
    candidate = Path(ffmpeg_bin)
    if candidate.is_absolute():
        if candidate.exists() and candidate.is_file():
            return str(candidate)
        raise RenderVideoError(f"ffmpeg executable not found at: {candidate}")

    resolved = shutil.which(ffmpeg_bin)
    if resolved:
        return resolved

    raise RenderVideoError(
        "ffmpeg is not available. Install ffmpeg and ensure it is in PATH, "
        "or pass --ffmpeg-bin with an absolute executable path."
    )


def build_default_regions_path(template: str) -> Path:
    """Map template key to default video regions config path."""
    return (PROJECT_ROOT / f"config/video_regions_{template}.json").resolve()


def load_layout_card_regions(template: str) -> Dict[int, Region]:
    """Load card geometry from poster layout so video highlight aligns with rendered card boxes."""
    spec = TEMPLATE_REGISTRY.get(template)
    if spec is None:
        raise RenderVideoError(f"template '{template}' not found in template registry")

    layout_path = (PROJECT_ROOT / spec.layout_path).resolve()
    layout_payload = load_json_dict(layout_path, "template layout")

    canvas = layout_payload.get("canvas")
    if not isinstance(canvas, dict):
        raise RenderVideoError(f"template layout canvas must be object: {layout_path}")
    try:
        layout_w = int(canvas.get("width"))
        layout_h = int(canvas.get("height"))
    except (TypeError, ValueError) as exc:
        raise RenderVideoError(f"template layout canvas.width/height must be integers: {layout_path}") from exc

    if layout_w != REQUIRED_CANVAS_WIDTH or layout_h != REQUIRED_CANVAS_HEIGHT:
        raise RenderVideoError(
            f"template layout canvas must be {REQUIRED_CANVAS_WIDTH}x{REQUIRED_CANVAS_HEIGHT}, "
            f"got {layout_w}x{layout_h}: {layout_path}"
        )

    raw_cards = layout_payload.get("news_cards")
    if not isinstance(raw_cards, list) or len(raw_cards) != REQUIRED_NEWS_COUNT:
        raise RenderVideoError(
            f"template layout news_cards must have {REQUIRED_NEWS_COUNT} entries: {layout_path}"
        )

    card_regions: Dict[int, Region] = {}
    for idx, card in enumerate(raw_cards, start=1):
        if not isinstance(card, dict):
            raise RenderVideoError(f"template layout news_cards[{idx - 1}] must be object: {layout_path}")
        try:
            x = int(card.get("x"))
            y = int(card.get("y"))
            w = int(card.get("w"))
            h = int(card.get("h"))
        except (TypeError, ValueError) as exc:
            raise RenderVideoError(
                f"template layout news_cards[{idx - 1}] x/y/w/h must be integers: {layout_path}"
            ) from exc

        if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > layout_w or y + h > layout_h:
            raise RenderVideoError(
                f"template layout news_cards[{idx - 1}] out of bounds: x={x}, y={y}, w={w}, h={h}, "
                f"canvas={layout_w}x{layout_h}, path={layout_path}"
            )
        card_regions[idx] = Region(index=idx, x=x, y=y, w=w, h=h)

    return card_regions


def export_debug_frames(
    video_path: Path,
    scenes: Sequence[ScenePlan],
    debug_frames_dir: Path,
    ffmpeg_bin: str,
    logger: logging.Logger,
) -> None:
    """Export key scene frames from final MP4 for static visual review."""
    debug_frames_dir.mkdir(parents=True, exist_ok=True)

    scene_map = {scene.name: scene for scene in scenes}
    targets = [
        ("01_intro.png", "intro_full", 0.50),
        ("02_focus_1.png", "focus_card_1", 0.85),
        ("06_focus_5.png", "focus_card_5", 0.85),
        ("07_outro.png", "outro_full", 0.50),
    ]

    for file_name, scene_name, probe in targets:
        scene = scene_map.get(scene_name)
        if scene is None:
            raise RenderVideoError(f"cannot export debug frame: scene not found: {scene_name}")

        timestamp = scene.start_sec + (scene.end_sec - scene.start_sec) * probe
        output_frame = debug_frames_dir / file_name
        frame_cmd = [
            ffmpeg_bin,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(video_path),
            "-ss",
            f"{timestamp:.3f}",
            "-frames:v",
            "1",
            str(output_frame),
        ]
        run_ffmpeg(frame_cmd, logger=logger, step_name=f"debug frame {file_name}")
        logger.info(
            "debug frame exported: %s (scene=%s, t=%.2fs, probe=%.2f)",
            output_frame,
            scene_name,
            timestamp,
            probe,
        )


def render_video(
    poster_path: Path,
    brief_path: Path,
    regions_path: Path,
    output_path: Path,
    ffmpeg_bin: str,
    logger: logging.Logger,
    debug_frames_dir: Optional[Path] = None,
) -> None:
    """Main rendering pipeline: validate -> plan scenes -> ffmpeg scenes -> concat MP4."""
    ensure_file_exists(poster_path, "poster")
    ensure_file_exists(brief_path, "brief")
    ensure_file_exists(regions_path, "regions")

    brief = load_json_dict(brief_path, "brief")
    try:
        # 复用现有 daily_brief 严格校验，保证与海报链路格式一致。
        validate_daily_brief(brief)
    except Exception as exc:
        raise RenderVideoError(f"brief JSON schema validation failed: {exc}") from exc

    brief_template = resolve_template_from_brief(brief)

    regions_payload = load_json_dict(regions_path, "regions")
    regions = parse_regions_config(regions_payload)

    if brief_template != regions.template:
        raise RenderVideoError(
            f"template mismatch: brief template '{brief_template}' != regions template '{regions.template}'"
        )

    validate_poster_size(poster_path, regions.canvas_width, regions.canvas_height)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    crop_box = compute_center_crop(regions.canvas_width, regions.canvas_height)
    scenes = build_scene_plan(regions.regions, crop_box)
    layout_card_regions = load_layout_card_regions(brief_template)
    scenes = apply_layout_card_geometry_to_scenes(scenes, layout_card_regions)

    logger.info("render start")
    logger.info("poster path: %s", poster_path)
    logger.info("brief path: %s", brief_path)
    logger.info("template: %s", brief_template)
    logger.info("regions path: %s", regions_path)
    logger.info("highlight source: template layout news_cards")
    logger.info("output path: %s", output_path)
    if debug_frames_dir is not None:
        logger.info("debug frames dir: %s", debug_frames_dir)
    logger.info(
        "duration/fps/resolution: %ss / %sfps / %sx%s",
        OUTPUT_DURATION_SECONDS,
        OUTPUT_FPS,
        OUTPUT_WIDTH,
        OUTPUT_HEIGHT,
    )
    logger.info(
        "center crop (poster->9:16): x=%s y=%s w=%s h=%s",
        crop_box[0],
        crop_box[1],
        crop_box[2],
        crop_box[3],
    )

    for scene in scenes:
        logger.info(
            (
                "scene: %s, start=%.2fs, end=%.2fs, frames=%s, "
                "zoom_start=%.2f, zoom_end=%.2f, "
                "focus_center=(%.2f, %.2f), focus_start=(%.2f, %.2f), focus_end=(%.2f, %.2f), "
                "region_index=%s"
            ),
            scene.name,
            scene.start_sec,
            scene.end_sec,
            scene.frames,
            scene.zoom_start,
            scene.zoom_end,
            scene.focus_end_center[0],
            scene.focus_end_center[1],
            scene.focus_start_center[0],
            scene.focus_start_center[1],
            scene.focus_end_center[0],
            scene.focus_end_center[1],
            scene.region_index if scene.region_index is not None else "-",
        )

        if scene.highlight and scene.region_index is not None:
            mapped_x, mapped_y, mapped_w, mapped_h = estimate_mapped_highlight_box(
                scene=scene,
                crop_box=crop_box,
                progress=0.85,
            )
            logger.info(
                "scene highlight map: scene=%s, region_index=%s, mapped_box=x=%s,y=%s,w=%s,h=%s, probe=0.85",
                scene.name,
                scene.region_index,
                mapped_x,
                mapped_y,
                mapped_w,
                mapped_h,
            )

    for region in regions.regions:
        center_x = region.x + (region.w / 2.0)
        center_y = region.y + (region.h / 2.0)
        logger.info(
            "focus region index=%s, center=(%.2f, %.2f)",
            region.index,
            center_x,
            center_y,
        )

    ffmpeg_resolved = ensure_ffmpeg_available(ffmpeg_bin)
    logger.info("ffmpeg path: %s", ffmpeg_resolved)

    # 记录 ffmpeg 版本，方便后续部署排障。
    version_cmd = [ffmpeg_resolved, "-version"]
    version_result = subprocess.run(version_cmd, check=False, capture_output=True, text=True)
    if version_result.returncode == 0 and version_result.stdout:
        first_line = version_result.stdout.splitlines()[0].strip()
        logger.info("ffmpeg version: %s", first_line)

    with tempfile.TemporaryDirectory(prefix="render_video_") as temp_dir_str:
        temp_dir = Path(temp_dir_str)
        segment_paths: List[Path] = []

        for idx, scene in enumerate(scenes):
            segment_path = temp_dir / f"scene_{idx:02d}_{scene.name}.mp4"
            filter_graph = build_scene_filter(scene, crop_box)

            ffmpeg_cmd = [
                ffmpeg_resolved,
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(poster_path),
                "-vf",
                filter_graph,
                "-frames:v",
                str(scene.frames),
                "-c:v",
                "libx264",
                "-preset",
                "medium",
                "-crf",
                "18",
                "-pix_fmt",
                "yuv420p",
                "-an",
                str(segment_path),
            ]

            run_ffmpeg(ffmpeg_cmd, logger=logger, step_name=f"segment {scene.name}")
            segment_paths.append(segment_path)

        concat_list_path = temp_dir / "segments.txt"
        with concat_list_path.open("w", encoding="utf-8") as file:
            for segment in segment_paths:
                # concat demuxer 需要严格的 `file 'path'` 文本格式。
                file.write(f"file '{segment.as_posix()}'\n")

        concat_cmd = [
            ffmpeg_resolved,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_list_path),
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-r",
            str(OUTPUT_FPS),
            "-movflags",
            "+faststart",
            "-an",
            str(output_path),
        ]

        run_ffmpeg(concat_cmd, logger=logger, step_name="final concat")

    if debug_frames_dir is not None:
        export_debug_frames(
            video_path=output_path,
            scenes=scenes,
            debug_frames_dir=debug_frames_dir,
            ffmpeg_bin=ffmpeg_resolved,
            logger=logger,
        )


def main() -> None:
    """CLI entrypoint with explicit error classes for pipeline integration."""
    args = parse_args()

    poster_path = Path(args.poster).resolve()
    brief_path = Path(args.brief).resolve()
    output_path = Path(args.output).resolve()

    if args.log:
        log_path = Path(args.log).resolve()
    else:
        log_path = (output_path.parent / "render_video.log").resolve()

    debug_frames_dir = Path(args.debug_frames_dir).resolve() if args.debug_frames_dir else None

    logger = setup_logger(log_path)
    logger.info("log path: %s", log_path)

    try:
        # 先解析 brief，才能在未传 --regions 时按 template 自动选择配置文件。
        ensure_file_exists(brief_path, "brief")
        brief_data = load_json_dict(brief_path, "brief")
        try:
            validate_daily_brief(brief_data)
        except Exception as exc:
            raise RenderVideoError(f"brief JSON schema validation failed: {exc}") from exc
        brief_template = resolve_template_from_brief(brief_data)

        if args.regions:
            regions_path = Path(args.regions).resolve()
        else:
            regions_path = build_default_regions_path(brief_template)

        render_video(
            poster_path=poster_path,
            brief_path=brief_path,
            regions_path=regions_path,
            output_path=output_path,
            ffmpeg_bin=args.ffmpeg_bin,
            logger=logger,
            debug_frames_dir=debug_frames_dir,
        )
    except RenderVideoError as exc:
        logger.error("render failed: %s", exc)
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # pragma: no cover - fallback for unexpected runtime exceptions.
        logger.exception("render failed with unexpected exception")
        print(f"[ERROR] unexpected failure: {exc}", file=sys.stderr)
        sys.exit(1)

    logger.info("render success")
    print(f"[OK] Video generated: {output_path}")
    print(f"[OK] Log file: {log_path}")
    if debug_frames_dir is not None:
        print(f"[OK] Debug frames dir: {debug_frames_dir}")


if __name__ == "__main__":
    main()
