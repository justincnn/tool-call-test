# API Capability Probe

一个用于快速检测 **OpenAI 兼容 API** 下不同模型能力支持情况的命令行工具。

支持探测能力：

- `chat_completions`（是否支持 `/v1/chat/completions`）
- `stream`（是否接受流式请求）
- `responses`（是否支持 `/v1/responses`）
- `tool_call`（函数调用，严格/软支持）
- `web_search`（是否支持搜索类工具参数）
- `reasoning`（是否支持 reasoning 参数）
- `structured_output`（是否支持 `json_schema` 结构化输出）

---

## 文件说明

- `toolcall_probe.sh`：macOS / Linux 版 Bash 脚本
- `toolcall_probe_windows.ps1`：Windows 版 PowerShell 脚本

---

## 依赖要求

### macOS / Linux（Bash）

请确保系统已安装：

- `bash`
- `curl`
- `python3`

检查命令：

```bash
bash --version
curl --version
python3 --version
```

### Windows（PowerShell）

请确保系统已安装：

- `PowerShell`（Windows 自带 `powershell`，推荐 `pwsh` 7+）

检查命令：

```powershell
$PSVersionTable.PSVersion
```

---

## 快速开始

### macOS / Linux（Bash）

```bash
chmod +x ./toolcall_probe.sh
./toolcall_probe.sh
```

### Windows（PowerShell）

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
pwsh -File .\toolcall_probe_windows.ps1
```

或：

```powershell
powershell -File .\toolcall_probe_windows.ps1
```

---

## 环境变量方式（可选）

### macOS / Linux

```bash
export API_BASE_URL="https://api.openai.com"
export API_KEY="<YOUR_API_KEY>"
./toolcall_probe.sh
```

### Windows PowerShell

```powershell
$env:API_BASE_URL = "https://api.openai.com"
$env:API_KEY = "<YOUR_API_KEY>"
pwsh -File .\toolcall_probe_windows.ps1
```

---

## 检测逻辑说明

每个模型会执行以下探测：

1. `chat_completions`：发送最小消息到 `/v1/chat/completions`
2. `stream`：在 `/v1/chat/completions` 携带 `stream=true`
3. `responses`：发送最小输入到 `/v1/responses`
4. `tool_call`：在 chat-completions 中携带 function tool
5. `web_search`：在 responses 中携带 `web_search_preview`
6. `reasoning`：在 responses 中携带 `reasoning.effort`
7. `structured_output`：在 chat-completions 中携带 `response_format=json_schema`

状态说明：

- `Y`：支持
- `N`：不支持/请求失败
- `~`：软支持（目前用于 tool_call，文本疑似提及工具但非标准 `tool_calls`）

> 注意：不同服务商对 OpenAI 兼容接口实现存在差异；同一能力在不同模型上可能表现不一致。

---

## 输出示例（按最终 Result 分类）

```text
最终 Result 分类

Result 1 · 能力摘要
  chat_completions   3/3
  stream             2/3
  responses          2/3
  tool_call(strict)  1/3
  web_search         1/3
  reasoning          2/3

Result 2 · 接口支持分类
- 同时支持 chat_completions + responses
  ✓ gpt-4o-mini
- 仅支持 chat_completions
  ✓ gpt-4.1-mini
- 仅支持 responses
  - 无
- 两者都不支持
  ✓ legacy-model

Result 3 · 模型能力矩阵
MODEL                    | CHAT | STREAM | RESP | TOOL   | SEARCH | REASONING | STRUCTURED
------------------------------------------------------------------------------------------------
gpt-4o-mini              | Y    | Y      | Y    | Y      | Y      | Y         | Y
gpt-4.1-mini             | Y    | Y      | Y    | ~      | N      | Y         | N
legacy-model             | N    | N      | N    | N      | N      | N         | N

Result 4 · 按能力分类（支持）
- chat_completions
  ✓ gpt-4o-mini
  ✓ gpt-4.1-mini
  ✓ legacy-model
- stream
  ✓ gpt-4o-mini
  ✓ gpt-4.1-mini
- structured_output(json_schema)
  ✓ gpt-4o-mini
...
```

---

## 上传到 GitHub

```bash
git add .
git commit -m "feat: extend capability probes for stream/responses/search/reasoning"
git push origin HEAD
```

---

## 安全建议

- 不要把真实 `API Key` 写入脚本或提交到 GitHub。
- 建议使用环境变量或本地安全凭据管理工具。

---

## 免责声明

该工具用于“快速探测与对比”，不是协议一致性认证工具。实际可用性以你的服务商文档与线上行为为准。
