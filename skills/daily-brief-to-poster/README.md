# Daily Brief to Poster (Multi-Template MVP)

本项目用于将 `daily_brief.json` 的内容渲染到固定模板底图，输出 AI 每日资讯海报。

## 1. 环境要求

- Python 3.10+
- 本地运行（macOS / Linux / Windows）
- 依赖：Pillow（见 `requirements.txt`）

## 2. 项目结构

```text
daily_brief_to_poster/
  assets/
    template_a_v1.png
    template_b_v1.png
    template_c_v1.png
    fonts/
      SourceHanSansSC-Bold.otf
      SourceHanSansSC-Medium.otf
      SourceHanSansSC-Regular.otf
  config/
    template_a_layout.json
    template_b_layout.json
    template_c_layout.json
  data/
    daily_brief.json
  output/
  scripts/
    openclaw_render.py
  SKILL.md
  render_poster.py
  requirements.txt
  README.md
  AGENTS.md
```

## 3. 安装

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 4. daily_brief.json 字段规则

必须包含：

- `date`：支持 `YYYY.MM.DD` 或 `YYYY-MM-DD`
- `items`：必须严格等于 5 条
- 每条 item 必须含 `title` 和 `summary`

`template` 字段规则（重点）：

1. 允许值：`a|b|c`
2. 字段缺失时：默认 `b`
3. 字段非法时：直接报错
4. CLI `--template` 可覆盖 JSON `template`
5. 输出文件名带模板后缀（`_a` / `_b` / `_c`）

示例：

```json
{
  "date": "2026.03.07",
  "template": "b",
  "items": [
    { "title": "中国五年计划加码AI", "summary": "聚焦芯片、量子等关键技术突破" },
    { "title": "World Labs获10亿美元", "summary": "李飞飞推进3D世界模型研发" },
    { "title": "Anthropic陷供应链风波", "summary": "CEO道歉后被列风险名单" },
    { "title": "马里兰拟推AI玩具法", "summary": "限制AI玩具情感宣传" },
    { "title": "AI材料发现再提速", "summary": "发现周期已压缩至数月" }
  ]
}
```

## 5. 运行方式

默认运行（主流程：从 JSON 读取 template）：

```bash
python3 render_poster.py
```

模板调试覆盖（CLI 覆盖 JSON）：

```bash
python3 render_poster.py --template a
python3 render_poster.py --template b
python3 render_poster.py --template c
```

调试框模式：

```bash
python3 render_poster.py --debug-boxes
```

高级调试覆盖（不建议日常使用）：

```bash
python3 render_poster.py \
  --template b \
  --layout config/template_b_layout.json \
  --template-path assets/template_b_v1.png
```

## 6. 优先级规则

模板选择优先级为：

`CLI --template > JSON template > 默认 b`

## 7. 输出文件

输出目录默认：`output/`

- 正式图：`poster_YYYY_MM_DD_a.png` / `poster_YYYY_MM_DD_b.png` / `poster_YYYY_MM_DD_c.png`
- 调试图：`poster_YYYY_MM_DD_a_debug.png`（b/c 同理）

示例：

- 输入日期：`2026.03.07`
- 模板：`b`
- 输出：`poster_2026_03_07_b.png`

## 8. 已内置渲染约束

- 画布固定：`1365 x 2048`
- 底图尺寸不符直接报错，不自动缩放
- 主标题固定：`AI每日资讯`
- 主标题与日期单行
- 新闻卡片严格 5 条，固定卡片高度
- 新闻标题：优先单行，必要时缩字号，最多两行
- 新闻简介：严格按 `单行 -> 两行 -> 省略号` 处理
- 文本禁止进入底部禁区
- 文本测量统一使用 Pillow `textbbox` / `multiline_textbbox`

## 9. 常见报错

### `template must be one of a|b|c`

含义：模板值非法。

处理：改成 `a`、`b`、`c` 之一。

### `Template size must be 1365x2048`

含义：底图尺寸不合法。

处理：替换为 `1365x2048` 的模板图，脚本不会自动缩放。

### `daily_brief.json items must contain exactly 5 news cards`

含义：新闻条数不是 5。

处理：修正为 5 条。

### `date must match YYYY.MM.DD or YYYY-MM-DD`

含义：日期格式错误。

处理：改为 `2026.03.07` 或 `2026-03-07`。

## 10. OpenClaw Skill 使用

### 10.1 作为 skill 放入 OpenClaw

将本项目目录放到 OpenClaw skills 目录（目录名可自定义，示例为 `daily-brief-to-poster`）：

```bash
mkdir -p ~/.openclaw/workspace/skills
cp -R /path/to/daily-brief-to-poster ~/.openclaw/workspace/skills/daily-brief-to-poster
```

目录中已包含 `SKILL.md`，OpenClaw 会按该文件识别 skill。

### 10.2 在 skill 内执行渲染

默认读取 `data/daily_brief.json`：

```bash
python3 {baseDir}/scripts/openclaw_render.py --input {baseDir}/data/daily_brief.json
```

直接传 JSON（推荐 stdin，避免引号转义问题）：

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

### 10.3 返回结果给 OpenClaw

`scripts/openclaw_render.py` 成功后会输出：

- `MEDIA:/absolute/path/to/poster.png`
- `output_image` 的 JSON 结果行

OpenClaw 可根据 `MEDIA:` 路径直接展示图片，或至少返回可访问的绝对路径。

## 11. 海报转 MP4（本地 MVP）

### 11.1 额外环境要求

- 本机已安装 `ffmpeg`（脚本优先复用系统 `ffmpeg`，不额外引入重依赖）

快速自检：

```bash
ffmpeg -version
```

### 11.2 区域配置文件

已提供模板对应配置：

- `config/video_regions_a.json`
- `config/video_regions_b.json`
- `config/video_regions_c.json`

配置结构包含：

- `template`
- `canvas.width` / `canvas.height`
- `regions`（固定 5 条，含 `index/x/y/w/h`）

说明：这些坐标先用稳定默认值占位（与新闻卡一致），后续可手工微调 JSON 坐标，无需改代码。

### 11.3 运行命令

```bash
python3 scripts/render_video.py \
  --poster output/2026-03-09/poster.png \
  --brief output/2026-03-09/daily_brief.json \
  --regions config/video_regions_b.json \
  --output output/2026-03-09/video.mp4 \
  --log output/2026-03-09/render_video.log
```

也支持省略 `--regions`，脚本会基于 `daily_brief.json` 中 `template` 自动选择：

- `a -> config/video_regions_a.json`
- `b -> config/video_regions_b.json`
- `c -> config/video_regions_c.json`

### 11.4 视频参数（MVP 固定）

- 分辨率：`1080x1920`
- 时长：`15s`
- 帧率：`30fps`
- 编码：`mp4 (H.264, yuv420p, 无音频)`
- 分镜：`0~2s 全图淡入+轻微放大` -> `5条新闻区域逐条聚焦` -> `结尾回全图停留`

### 11.5 输入校验与报错

脚本会对以下情况明确报错并写入日志：

- `poster` / `brief` / `regions` 文件不存在
- `brief` JSON 非法或不满足现有 5 条新闻约束
- `brief.template` 与 `regions.template` 不一致
- 海报尺寸不是 `1365x2048`
- 区域坐标越界或数量/索引非法
- `ffmpeg` 不可用

### 11.6 最小验收步骤

1. 先生成海报（保持现有主链路不变）
2. 准备对应日期的 `poster.png` 和 `daily_brief.json`
3. 执行 `scripts/render_video.py` 命令
4. 检查输出：
   - `video.mp4` 存在且可播放
   - `render_video.log` 包含 scene 时间、focus center、ffmpeg 开始/结束、成功/失败信息
