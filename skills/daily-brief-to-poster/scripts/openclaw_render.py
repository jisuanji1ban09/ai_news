#!/usr/bin/env python3
"""OpenClaw skill entrypoint for AI Daily Poster rendering."""

import argparse
import json
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

# Add project root to import path so this script can import render_poster.py.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from render_poster import ALLOWED_TEMPLATE_KEYS, render_poster  # noqa: E402


def parse_args() -> argparse.Namespace:
    """Parse OpenClaw wrapper CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Render AI daily poster for OpenClaw from file or inline JSON."
    )
    parser.add_argument(
        "--input",
        default="data/daily_brief.json",
        help="Path to daily_brief.json (relative paths are resolved under project root).",
    )
    parser.add_argument(
        "--inline-json",
        default=None,
        help="Inline JSON string for daily_brief payload.",
    )
    parser.add_argument(
        "--stdin-json",
        action="store_true",
        help="Read daily_brief JSON payload from stdin.",
    )
    parser.add_argument(
        "--template",
        default=None,
        choices=ALLOWED_TEMPLATE_KEYS,
        help="Optional template override (a|b|c).",
    )
    parser.add_argument(
        "--output-dir",
        default="output",
        help="Output directory for generated image.",
    )
    parser.add_argument(
        "--debug-boxes",
        action="store_true",
        help="Also export a debug image with layout boxes.",
    )
    parser.add_argument(
        "--keep-temp-input",
        action="store_true",
        help="Keep temporary input JSON file when inline/stdin mode is used.",
    )
    return parser.parse_args()


def parse_json_payload(payload_text: str) -> Dict[str, Any]:
    """Parse and validate inline JSON payload type."""
    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON payload: {exc}") from exc

    if not isinstance(payload, dict):
        raise ValueError("daily_brief payload must be a JSON object")
    return payload


def write_temp_input_file(payload: Dict[str, Any]) -> Path:
    """Write payload to a temporary JSON file for renderer reuse."""
    # NamedTemporaryFile with delete=False gives a concrete path for downstream APIs.
    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".json",
        prefix="openclaw_daily_brief_",
        encoding="utf-8",
        delete=False,
    ) as temp_file:
        json.dump(payload, temp_file, ensure_ascii=False, indent=2)
        temp_file.write("\n")
        return Path(temp_file.name).resolve()


def resolve_input_path(args: argparse.Namespace) -> Tuple[Path, Optional[Path]]:
    """Resolve the final input path and optional temporary path to clean up."""
    if args.inline_json is not None and args.stdin_json:
        raise ValueError("--inline-json and --stdin-json cannot be used together")

    if args.inline_json is not None:
        payload = parse_json_payload(args.inline_json)
        temp_path = write_temp_input_file(payload)
        return temp_path, temp_path

    if args.stdin_json:
        stdin_payload = sys.stdin.read()
        if not stdin_payload.strip():
            raise ValueError("--stdin-json enabled but stdin is empty")
        payload = parse_json_payload(stdin_payload)
        temp_path = write_temp_input_file(payload)
        return temp_path, temp_path

    input_path = Path(args.input)
    if not input_path.is_absolute():
        input_path = (PROJECT_ROOT / input_path).resolve()
    return input_path, None


def main() -> None:
    """Run render pipeline and print OpenClaw-friendly outputs."""
    args = parse_args()
    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = (PROJECT_ROOT / output_dir).resolve()

    temp_input_path: Optional[Path] = None
    try:
        input_path, temp_input_path = resolve_input_path(args)
        output_path, debug_path, selected_template = render_poster(
            project_root=PROJECT_ROOT,
            input_path=input_path,
            output_dir=output_dir,
            debug_boxes=args.debug_boxes,
            cli_template_key=args.template,
            layout_override_path=None,
            template_override_path=None,
        )
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        # Emit machine-readable error payload for easier tool integrations.
        print(json.dumps({"status": "error", "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    finally:
        # Remove temporary payload file unless explicit debug retention is requested.
        if temp_input_path is not None and not args.keep_temp_input and temp_input_path.exists():
            temp_input_path.unlink()

    result = {
        "status": "ok",
        "output_image": str(output_path),
        "debug_image": str(debug_path) if debug_path else None,
        "template": selected_template.key,
        "template_source": selected_template.source,
    }

    print(f"[INFO] Template selected: {selected_template.key}, source={selected_template.source}")
    print(f"[OK] Poster generated: {output_path}")
    # MEDIA line allows OpenClaw clients to pick up image artifact paths.
    print(f"MEDIA:{output_path}")
    if debug_path:
        print(f"[OK] Debug image generated: {debug_path}")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
