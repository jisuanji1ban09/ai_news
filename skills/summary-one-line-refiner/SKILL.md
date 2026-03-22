---
name: summary-one-line-refiner
description: Refine daily_brief summaries to single-line display before poster rendering. Use when poster cards look crowded or summary wraps to two lines; rewrite only overflowing summaries with bounded retries and keep current text on retry exhaustion.
---

# Summary One-Line Refiner

Use this skill before poster rendering when `daily_brief.json` exists and card summaries are visually too dense.

## What It Does

1. Reads `daily_brief.json` and the selected template layout (`a|b|c`).
2. Measures each item summary with the same width/font logic as the poster renderer.
3. Rewrites only the summaries that render in more than one line.
4. Retries up to a per-item limit (default `5`).
5. If still multi-line after retries, keeps current summary and continues.
6. Writes changes back to `daily_brief.json` only. It never edits `top5.json`.

## Run

```bash
python3 scripts/refine_summaries.py \
  --brief /Users/wzh/project/news/ai_news/2026-03-18/data/daily_brief.json \
  --project-root /Users/wzh/project/news/skills/daily-brief-to-poster \
  --max-retries-per-item 5
```

## Output

Prints JSON stats:
- `checked_count`
- `rewritten_count`
- `one_line_count`
- `fallback_kept_count`
- `status`
