# API Tool Call Probe

一个用于快速检测 **OpenAI 兼容 API** 下不同模型是否支持 `tool call`（函数调用）的命令行工具。

脚本特点：

- 兼容 **macOS / Linux**（Bash）
- 交互式输入 `Base URL` 与 `API Key`
- 自动拉取模型清单（`/v1/models`）
- 支持全选或按编号选择模型
- 逐个模型探测 `tool call` 能力
- 以友好的终端表格汇总结果（偏 mac 风格输出）

---

## 文件说明

- `toolcall_probe.sh`：主检测脚本

---

## 依赖要求

请确保系统已安装：

- `bash`（macOS / Linux 默认通常具备）
- `curl`
- `python3`

可用以下命令检查：

```bash
bash --version
curl --version
python3 --version
```

---

## 快速开始

### 1) 赋予执行权限

```bash
chmod +x ./toolcall_probe.sh
```

### 2) 运行脚本

```bash
./toolcall_probe.sh
```

随后按提示输入：

- API Base URL（例如 `https://api.openai.com`）
- API Key

脚本会拉取模型列表并让你选择：

- 输入 `all`（或 `1`）全选
- 输入编号（逗号分隔）按需选择，例如：`1,3,5`

---

## 环境变量方式（可选）

你也可以先设置环境变量，脚本会把它们作为默认值：

```bash
export API_BASE_URL="https://api.openai.com"
export API_KEY="<YOUR_API_KEY>"
./toolcall_probe.sh
```

---

## 检测逻辑说明

脚本会对每个选中模型调用：

- `POST /v1/chat/completions`
- 携带 `tools`（包含一个 `get_time` 函数定义）
- 提示模型调用该工具

结果判定：

- `PASS`：响应中出现标准 `message.tool_calls`
- `SOFT_PASS`：未出现标准字段，但文本疑似提及工具调用
- `FAIL`：未检测到有效工具调用，或请求失败

---

## 输出示例（按最终 Result 分类）

```text
最终 Result 分类

Result 1 · 摘要
  TOTAL        3
  PASS         1
  SOFT_PASS    1
  FAIL         1

Result 2 · PASS（严格命中 tool_calls）
  ✓ gpt-4o-mini                            function=get_time

Result 3 · SOFT_PASS（疑似支持）
  ⚠ some-model                             content hints tool usage

Result 4 · FAIL（未通过）
  ✗ legacy-model                           no tool_calls
```

---

## 上传到 GitHub

> 先在 GitHub 网页创建一个空仓库（例如：`api-toolcall-probe`），再在本地执行：

```bash
git init
git add .
git commit -m "feat: add api tool call probe script"
git branch -M main
git remote add origin <YOUR_GITHUB_REPO_URL>
git push -u origin main
```

例如：

- HTTPS: `https://github.com/<your_name>/api-toolcall-probe.git`
- SSH: `git@github.com:<your_name>/api-toolcall-probe.git`

---

## 安全建议

- 不要把真实 `API Key` 写入脚本或提交到 GitHub。
- 建议使用环境变量或本地安全凭据管理工具。

---

## 免责声明

不同服务商对 OpenAI 兼容程度不一。即便接口路径一致，`tool call` 字段格式也可能存在差异。该工具用于快速探测与对比，不保证覆盖所有私有扩展行为。
