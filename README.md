# AI Daily Poster Plus

这个目录已经包含 `daily-ai-poster-plus.sh` 运行链路需要的本地文件，不再依赖 `~/.openclaw/workspace` 里的脚本和资源。

## 目录

- `scripts/daily-ai-poster-plus.sh`：主入口，抓取 AI 新闻、筛选 Top5、精修摘要、渲染海报、生成口播并发送到飞书
- `scripts/generate_voiceover.py`：口播文案生成
- `skills/tavily-search`：Tavily 新闻检索脚本
- `skills/summary-one-line-refiner`：摘要单行压缩脚本
- `skills/daily-brief-to-poster`：海报渲染项目、字体、模板与布局配置
- `ai_news/`：运行后自动生成的日期化数据、日志和海报输出

## 运行

1. 准备依赖：`python3`、`node`、`openclaw`
2. 安装 Python 依赖：`pip install -r skills/daily-brief-to-poster/requirements.txt`
3. 在仓库根目录创建 `.env`，可参考 `.env.example`
4. 执行：`bash scripts/daily-ai-poster-plus.sh`

默认输出会落在 `ai_news/YYYY-MM-DD/` 下。
