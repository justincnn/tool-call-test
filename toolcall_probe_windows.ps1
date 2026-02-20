#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =========================================================
# API Capability Probe (Windows PowerShell)
# Supports: Windows PowerShell 5.1+ / PowerShell 7+
# =========================================================

$script:Total = 0
$script:Results = @()

function Write-Header {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host "  API Capability Probe (OpenAI-Compatible / Windows)" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host ""
}

function Write-Section([string]$Title) {
    Write-Host "▶ $Title" -ForegroundColor Blue
}

function Write-Ok([string]$Message) {
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Err([string]$Message) {
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Prompt-WithDefault([string]$Prompt, [string]$DefaultValue) {
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        $input = Read-Host "$Prompt [$DefaultValue]"
        if ([string]::IsNullOrWhiteSpace($input)) {
            return $DefaultValue
        }
        return $input
    }
    return (Read-Host $Prompt)
}

function Normalize-BaseUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    $trimmed = $Url.Trim().TrimEnd('/')
    if ($trimmed.ToLower().EndsWith('/v1')) {
        return $trimmed.Substring(0, $trimmed.Length - 3)
    }
    return $trimmed
}

function Invoke-ApiJson([string]$Uri, [string]$ApiKey, [string]$Method, [string]$JsonBody, [int]$TimeoutSec = 60) {
    $headers = @{
        Authorization = "Bearer $ApiKey"
        'Content-Type' = 'application/json'
    }

    try {
        if ($Method -eq 'GET') {
            $resp = Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec $TimeoutSec
        }
        else {
            $resp = Invoke-RestMethod -Method Post -Uri $Uri -Headers $headers -Body $JsonBody -TimeoutSec $TimeoutSec
        }

        return [PSCustomObject]@{
            Ok = $true
            StatusCode = 200
            Data = $resp
            Error = ''
        }
    }
    catch {
        $statusCode = -1
        try {
            if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        catch {
            $statusCode = -1
        }

        return [PSCustomObject]@{
            Ok = $false
            StatusCode = $statusCode
            Data = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-Models([string]$BaseUrl, [string]$ApiKey) {
    $result = Invoke-ApiJson -Uri "$BaseUrl/v1/models" -ApiKey $ApiKey -Method 'GET' -JsonBody '' -TimeoutSec 60
    if (-not $result.Ok) {
        return @()
    }

    if ($null -eq $result.Data -or $null -eq $result.Data.data) {
        return @()
    }

    return @($result.Data.data | ForEach-Object { $_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Choose-Models([string[]]$Models) {
    Write-Host ""
    Write-Section "可用模型列表"

    for ($i = 0; $i -lt $Models.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Models[$i])"
    }

    Write-Host ""
    Write-Host "选择方式："
    Write-Host "  1) all（全选）"
    Write-Host "  2) 输入编号（逗号分隔），例如: 1,3,5"

    $pick = (Read-Host "请输入选择").Trim().ToLower()

    if ([string]::IsNullOrWhiteSpace($pick)) {
        Write-Warn "未输入选择，默认全选。"
        return $Models
    }

    if ($pick -eq 'all' -or $pick -eq '1') {
        return $Models
    }

    $selected = New-Object System.Collections.Generic.List[string]
    $parts = $pick.Split(',')

    foreach ($raw in $parts) {
        $idxText = $raw.Trim()
        $idx = 0

        if ([int]::TryParse($idxText, [ref]$idx)) {
            if ($idx -ge 1 -and $idx -le $Models.Count) {
                $selected.Add($Models[$idx - 1])
            }
            else {
                Write-Warn "编号超出范围: $idx（已忽略）"
            }
        }
        else {
            Write-Warn "无效编号: $idxText（已忽略）"
        }
    }

    if ($selected.Count -eq 0) {
        Write-Warn "未选中有效模型，默认全选。"
        return $Models
    }

    return $selected.ToArray()
}

function New-Result([string]$Model, [string]$Chat, [string]$Stream, [string]$Responses, [string]$ToolCall, [string]$Search, [string]$Reasoning, [string]$Notes) {
    return [PSCustomObject]@{
        Model = $Model
        Chat = $Chat
        Stream = $Stream
        Responses = $Responses
        ToolCall = $ToolCall
        Search = $Search
        Reasoning = $Reasoning
        Notes = $Notes
    }
}

function Test-ChatCompletions([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $payload = @{
        model = $Model
        messages = @(@{ role = 'user'; content = '请回复 ok' })
        temperature = 0
    } | ConvertTo-Json -Depth 10

    $result = Invoke-ApiJson -Uri "$BaseUrl/v1/chat/completions" -ApiKey $ApiKey -Method 'POST' -JsonBody $payload -TimeoutSec 60
    if (-not $result.Ok) {
        return [PSCustomObject]@{ Flag = 'N'; Detail = "http=$($result.StatusCode)" }
    }

    if ($null -ne $result.Data.choices -and $result.Data.choices.Count -gt 0) {
        return [PSCustomObject]@{ Flag = 'Y'; Detail = 'ok' }
    }

    return [PSCustomObject]@{ Flag = 'N'; Detail = 'invalid_response' }
}

function Test-ToolCall([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $payload = @{
        model = $Model
        messages = @(
            @{ role = 'system'; content = 'You are a helpful assistant.' },
            @{ role = 'user'; content = '请调用工具 get_time 来获取当前时间。不要直接回答时间。' }
        )
        tools = @(
            @{
                type = 'function'
                function = @{
                    name = 'get_time'
                    description = '获取当前时间'
                    parameters = @{
                        type = 'object'
                        properties = @{
                            timezone = @{ type = 'string'; description = 'IANA 时区' }
                        }
                        required = @('timezone')
                    }
                }
            }
        )
        tool_choice = 'auto'
        temperature = 0
    } | ConvertTo-Json -Depth 20

    $result = Invoke-ApiJson -Uri "$BaseUrl/v1/chat/completions" -ApiKey $ApiKey -Method 'POST' -JsonBody $payload -TimeoutSec 90
    if (-not $result.Ok) {
        return [PSCustomObject]@{ Flag = 'N'; Detail = "http=$($result.StatusCode)" }
    }

    $message = $null
    if ($null -ne $result.Data.choices -and $result.Data.choices.Count -gt 0) {
        $message = $result.Data.choices[0].message
    }

    if ($null -ne $message -and $null -ne $message.tool_calls -and $message.tool_calls.Count -gt 0) {
        $fnName = $message.tool_calls[0].function.name
        if ([string]::IsNullOrWhiteSpace($fnName)) { $fnName = 'unknown' }
        return [PSCustomObject]@{ Flag = 'Y'; Detail = "function=$fnName" }
    }

    $content = ''
    if ($null -ne $message -and $null -ne $message.content) {
        $content = [string]$message.content
    }
    if (-not [string]::IsNullOrWhiteSpace($content) -and $content.ToLower().Contains('tool')) {
        return [PSCustomObject]@{ Flag = '~'; Detail = 'content_hints_tool' }
    }

    return [PSCustomObject]@{ Flag = 'N'; Detail = 'no_tool_calls' }
}

function Test-Stream([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $payload = @{
        model = $Model
        messages = @(@{ role = 'user'; content = '请简单回复 hi' })
        stream = $true
        temperature = 0
    } | ConvertTo-Json -Depth 10

    # 用普通 JSON 请求做兼容探测：多数兼容服务会接受 stream=true 并返回流/或常规结构
    $result = Invoke-ApiJson -Uri "$BaseUrl/v1/chat/completions" -ApiKey $ApiKey -Method 'POST' -JsonBody $payload -TimeoutSec 60
    if (-not $result.Ok) {
        return [PSCustomObject]@{ Flag = 'N'; Detail = "http=$($result.StatusCode)" }
    }

    return [PSCustomObject]@{ Flag = 'Y'; Detail = 'request_accepted' }
}

function Test-Responses([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $payload = @{
        model = $Model
        input = '请回复 ok'
    } | ConvertTo-Json -Depth 10

    $result = Invoke-ApiJson -Uri "$BaseUrl/v1/responses" -ApiKey $ApiKey -Method 'POST' -JsonBody $payload -TimeoutSec 60
    if (-not $result.Ok) {
        return [PSCustomObject]@{ Flag = 'N'; Detail = "http=$($result.StatusCode)" }
    }

    if ($null -ne $result.Data.id -or $null -ne $result.Data.output) {
        return [PSCustomObject]@{ Flag = 'Y'; Detail = 'ok' }
    }

    return [PSCustomObject]@{ Flag = 'N'; Detail = 'invalid_response' }
}

function Test-Search([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $payload = @{
        model = $Model
        input = '请搜索今天的科技新闻并给一条标题。'
        tools = @(@{ type = 'web_search_preview' })
    } | ConvertTo-Json -Depth 10

    $result = Invoke-ApiJson -Uri "$BaseUrl/v1/responses" -ApiKey $ApiKey -Method 'POST' -JsonBody $payload -TimeoutSec 75
    if (-not $result.Ok) {
        return [PSCustomObject]@{ Flag = 'N'; Detail = "http=$($result.StatusCode)" }
    }

    return [PSCustomObject]@{ Flag = 'Y'; Detail = 'ok' }
}

function Test-Reasoning([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $payload = @{
        model = $Model
        input = '比较 17*19 与 18*18 的大小并说明理由。'
        reasoning = @{ effort = 'medium' }
    } | ConvertTo-Json -Depth 10

    $result = Invoke-ApiJson -Uri "$BaseUrl/v1/responses" -ApiKey $ApiKey -Method 'POST' -JsonBody $payload -TimeoutSec 75
    if (-not $result.Ok) {
        return [PSCustomObject]@{ Flag = 'N'; Detail = "http=$($result.StatusCode)" }
    }

    return [PSCustomObject]@{ Flag = 'Y'; Detail = 'ok' }
}

function Count-Yes([string]$PropertyName) {
    return @($script:Results | Where-Object { $_.$PropertyName -eq 'Y' }).Count
}

function Print-SupportList([string]$PropertyName, [string]$Value, [string]$Icon, [string]$Color) {
    $items = @($script:Results | Where-Object { $_.$PropertyName -eq $Value })
    if ($items.Count -eq 0) {
        Write-Host "  - 无" -ForegroundColor DarkGray
        return
    }

    foreach ($item in $items) {
        Write-Host ("  {0} {1,-34} {2}" -f $Icon, $item.Model, $item.Notes) -ForegroundColor $Color
    }
}

function Render-Summary {
    $chatYes = Count-Yes -PropertyName 'Chat'
    $streamYes = Count-Yes -PropertyName 'Stream'
    $respYes = Count-Yes -PropertyName 'Responses'
    $toolYes = Count-Yes -PropertyName 'ToolCall'
    $searchYes = Count-Yes -PropertyName 'Search'
    $reasonYes = Count-Yes -PropertyName 'Reasoning'

    Write-Host ""
    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host "最终 Result 分类" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor DarkGray

    Write-Host "Result 1 · 能力摘要" -ForegroundColor White
    Write-Host ("  {0,-18} {1}/{2}" -f 'chat_completions', $chatYes, $script:Total)
    Write-Host ("  {0,-18} {1}/{2}" -f 'stream', $streamYes, $script:Total)
    Write-Host ("  {0,-18} {1}/{2}" -f 'responses', $respYes, $script:Total)
    Write-Host ("  {0,-18} {1}/{2}" -f 'tool_call(strict)', $toolYes, $script:Total)
    Write-Host ("  {0,-18} {1}/{2}" -f 'web_search', $searchYes, $script:Total)
    Write-Host ("  {0,-18} {1}/{2}" -f 'reasoning', $reasonYes, $script:Total)
    Write-Host ""

    Write-Host "Result 2 · 模型能力矩阵" -ForegroundColor White
    Write-Host ("{0,-28} | {1,-4} | {2,-6} | {3,-4} | {4,-6} | {5,-6} | {6,-9}" -f 'MODEL', 'CHAT', 'STREAM', 'RESP', 'TOOL', 'SEARCH', 'REASONING')
    Write-Host ("".PadLeft(95, '-'))
    foreach ($r in $script:Results) {
        Write-Host ("{0,-28} | {1,-4} | {2,-6} | {3,-4} | {4,-6} | {5,-6} | {6,-9}" -f $r.Model, $r.Chat, $r.Stream, $r.Responses, $r.ToolCall, $r.Search, $r.Reasoning)
    }
    Write-Host ""

    Write-Host "Result 3 · 按能力分类（支持）" -ForegroundColor White
    Write-Host "- chat_completions" -ForegroundColor Cyan
    Print-SupportList -PropertyName 'Chat' -Value 'Y' -Icon '✓' -Color 'Green'
    Write-Host "- stream" -ForegroundColor Cyan
    Print-SupportList -PropertyName 'Stream' -Value 'Y' -Icon '✓' -Color 'Green'
    Write-Host "- responses" -ForegroundColor Cyan
    Print-SupportList -PropertyName 'Responses' -Value 'Y' -Icon '✓' -Color 'Green'
    Write-Host "- tool_call（严格）" -ForegroundColor Cyan
    Print-SupportList -PropertyName 'ToolCall' -Value 'Y' -Icon '✓' -Color 'Green'
    Write-Host "- tool_call（软支持）" -ForegroundColor Cyan
    Print-SupportList -PropertyName 'ToolCall' -Value '~' -Icon '⚠' -Color 'Yellow'
    Write-Host "- web_search" -ForegroundColor Cyan
    Print-SupportList -PropertyName 'Search' -Value 'Y' -Icon '✓' -Color 'Green'
    Write-Host "- reasoning" -ForegroundColor Cyan
    Print-SupportList -PropertyName 'Reasoning' -Value 'Y' -Icon '✓' -Color 'Green'

    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host ""
}

function Main {
    Write-Header
    Write-Section "输入连接信息"

    $defaultUrl = $env:API_BASE_URL
    $defaultKey = $env:API_KEY

    $baseUrl = Prompt-WithDefault "请输入 API Base URL（例如 https://api.openai.com）" $defaultUrl
    $apiKey = Prompt-WithDefault "请输入 API Key" $defaultKey
    $baseUrl = Normalize-BaseUrl $baseUrl

    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Err "URL 或 Key 不能为空。"
        exit 1
    }

    Write-Section "拉取模型清单"
    $models = @(Get-Models -BaseUrl $baseUrl -ApiKey $apiKey)

    if ($models.Count -eq 0) {
        Write-Err "模型清单为空或返回格式不兼容。"
        exit 1
    }

    Write-Ok "成功获取 $($models.Count) 个模型。"

    $chosenModels = @(Choose-Models -Models $models)
    if ($chosenModels.Count -eq 0) {
        Write-Err "未选择任何模型。"
        exit 1
    }

    Write-Section "开始探测模型能力（chat / stream / responses / tool / search / reasoning）"

    foreach ($m in $chosenModels) {
        $script:Total++
        Write-Host "→ 测试模型: $m" -ForegroundColor DarkGray

        $chat = Test-ChatCompletions -BaseUrl $baseUrl -ApiKey $apiKey -Model $m
        $stream = Test-Stream -BaseUrl $baseUrl -ApiKey $apiKey -Model $m
        $resp = Test-Responses -BaseUrl $baseUrl -ApiKey $apiKey -Model $m
        $tool = Test-ToolCall -BaseUrl $baseUrl -ApiKey $apiKey -Model $m
        $search = Test-Search -BaseUrl $baseUrl -ApiKey $apiKey -Model $m
        $reasoning = Test-Reasoning -BaseUrl $baseUrl -ApiKey $apiKey -Model $m

        $notes = "chat=$($chat.Detail);stream=$($stream.Detail);resp=$($resp.Detail);tool=$($tool.Detail);search=$($search.Detail);reasoning=$($reasoning.Detail)"

        $script:Results += New-Result -Model $m -Chat $chat.Flag -Stream $stream.Flag -Responses $resp.Flag -ToolCall $tool.Flag -Search $search.Flag -Reasoning $reasoning.Flag -Notes $notes

        Write-Ok "$m => chat:$($chat.Flag) stream:$($stream.Flag) responses:$($resp.Flag) tool:$($tool.Flag) search:$($search.Flag) reasoning:$($reasoning.Flag)"
    }

    Render-Summary

    Write-Section "完成"
    Write-Ok "探测结束。"
}

Main
