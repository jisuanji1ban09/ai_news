---
name: daily-brief-to-poster
description: Render a fixed 9:16 AI daily-news poster (1365x2048) from daily_brief JSON with template a|b|c. Use this skill when the user asks to generate/update/export a poster from daily_brief.json or inline JSON and return the generated PNG path/media.
user-invocable: true
metadata: {"clawdbot":{"emoji":"📰","requires":{"bins":["python3"]}}}
---

# AI Daily Poster Skill

Generate one poster image from `daily_brief` content with strict layout constraints.

## Run Command

Prefer this wrapper entrypoint:

```bash
python3 {baseDir}/scripts/openclaw_render.py --input {baseDir}/data/daily_brief.json
```

If the user provides JSON directly, use stdin mode to avoid shell quoting issues:

```bash
cat <<'JSON' | python3 {baseDir}/scripts/openclaw_render.py --stdin-json
{
  "date": "2026.03.07",
  "template": "b",
  "items": [
    {"title": "新闻1", "summary": "摘要1"},
    {"title": "新闻2", "summary": "摘要2"},
    {"title": "新闻3", "summary": "摘要3"},
    {"title": "新闻4", "summary": "摘要4"},
    {"title": "新闻5", "summary": "摘要5"}
  ]
}
JSON
```

## Input Rules

- Keep `date` in `YYYY.MM.DD` or `YYYY-MM-DD`.
- Keep `items` count exactly `5`.
- Keep each item with `title` and `summary`.
- `template` supports only `a|b|c` (defaults to `b` when missing).

## Output Behavior

- The wrapper prints `MEDIA:/absolute/path/to/output.png`.
- Return the generated image path to the user.
- If rendering fails, surface the exact error message and ask for corrected JSON.
