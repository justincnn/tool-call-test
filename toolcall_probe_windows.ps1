#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =========================================================
# API Tool Call Probe (Windows PowerShell)
# Supports: Windows PowerShell 5.1+ / PowerShell 7+
# =========================================================

$script:Total = 0
$script:Pass = 0
$script:SoftPass = 0
$script:Fail = 0
$script:Results = @()

function Write-Header {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host "  API Tool Call Probe (OpenAI-Compatible / Windows)" -ForegroundColor Cyan
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

function Get-Models([string]$BaseUrl, [string]$ApiKey) {
    $endpoint = "$BaseUrl/v1/models"
    $headers = @{
        Authorization = "Bearer $ApiKey"
        'Content-Type' = 'application/json'
    }

    try {
        return Invoke-RestMethod -Method Get -Uri $endpoint -Headers $headers -TimeoutSec 60
    }
    catch {
        return $null
    }
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

function Test-ModelToolCall([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $endpoint = "$BaseUrl/v1/chat/completions"

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

    $headers = @{
        Authorization = "Bearer $ApiKey"
        'Content-Type' = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body $payload -TimeoutSec 90

        $message = $null
        if ($null -ne $resp.choices -and $resp.choices.Count -gt 0) {
            $message = $resp.choices[0].message
        }

        if ($null -ne $message -and $null -ne $message.tool_calls -and $message.tool_calls.Count -gt 0) {
            $fnName = $message.tool_calls[0].function.name
            if ([string]::IsNullOrWhiteSpace($fnName)) { $fnName = 'unknown' }
            return [PSCustomObject]@{
                Status = 'PASS'
                Detail = "function=$fnName"
            }
        }

        $content = ''
        if ($null -ne $message -and $null -ne $message.content) {
            $content = [string]$message.content
        }

        if (-not [string]::IsNullOrWhiteSpace($content) -and $content.ToLower().Contains('tool')) {
            return [PSCustomObject]@{
                Status = 'SOFT_PASS'
                Detail = 'content hints tool usage'
            }
        }

        return [PSCustomObject]@{
            Status = 'FAIL'
            Detail = 'no tool_calls'
        }
    }
    catch {
        $statusCode = 'unknown'
        try {
            if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        catch {
            $statusCode = 'unknown'
        }

        return [PSCustomObject]@{
            Status = 'FAIL'
            Detail = "http=$statusCode"
        }
    }
}

function Add-Result([string]$Model, [string]$Status, [string]$Detail) {
    $script:Results += [PSCustomObject]@{
        Model = $Model
        Status = $Status
        Detail = $Detail
    }
}

function Render-Summary {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host "最终 Result 分类" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor DarkGray

    Write-Host "Result 1 · 摘要" -ForegroundColor White
    Write-Host ("  {0,-12} {1}" -f 'TOTAL', $script:Total)
    Write-Host ("  {0,-12} {1}" -f 'PASS', $script:Pass) -ForegroundColor Green
    Write-Host ("  {0,-12} {1}" -f 'SOFT_PASS', $script:SoftPass) -ForegroundColor Yellow
    Write-Host ("  {0,-12} {1}" -f 'FAIL', $script:Fail) -ForegroundColor Red
    Write-Host ""

    Write-Host "Result 2 · PASS（严格命中 tool_calls）" -ForegroundColor White
    $passItems = $script:Results | Where-Object { $_.Status -eq 'PASS' }
    if ($passItems.Count -eq 0) {
        Write-Host "  - 无" -ForegroundColor DarkGray
    }
    else {
        foreach ($item in $passItems) {
            Write-Host ("  ✓ {0,-38} {1}" -f $item.Model, $item.Detail) -ForegroundColor Green
        }
    }
    Write-Host ""

    Write-Host "Result 3 · SOFT_PASS（疑似支持）" -ForegroundColor White
    $softItems = $script:Results | Where-Object { $_.Status -eq 'SOFT_PASS' }
    if ($softItems.Count -eq 0) {
        Write-Host "  - 无" -ForegroundColor DarkGray
    }
    else {
        foreach ($item in $softItems) {
            Write-Host ("  ⚠ {0,-38} {1}" -f $item.Model, $item.Detail) -ForegroundColor Yellow
        }
    }
    Write-Host ""

    Write-Host "Result 4 · FAIL（未通过）" -ForegroundColor White
    $failItems = $script:Results | Where-Object { $_.Status -eq 'FAIL' }
    if ($failItems.Count -eq 0) {
        Write-Host "  - 无" -ForegroundColor DarkGray
    }
    else {
        foreach ($item in $failItems) {
            Write-Host ("  ✗ {0,-38} {1}" -f $item.Model, $item.Detail) -ForegroundColor Red
        }
    }

    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host ""
}

function Main {
    if (-not (Get-Command python -ErrorAction SilentlyContinue) -and -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
        Write-Warn "未检测到 python/python3。该脚本不强依赖 Python，可继续执行。"
    }

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
    $modelJson = Get-Models -BaseUrl $baseUrl -ApiKey $apiKey

    if ($null -eq $modelJson -or $null -eq $modelJson.data) {
        Write-Err "无法拉取模型清单。请检查 URL、Key 或网络。"
        exit 1
    }

    $models = @($modelJson.data | ForEach-Object { $_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($models.Count -eq 0) {
        Write-Err "模型清单为空或返回格式不兼容。"
        exit 1
    }

    Write-Ok "成功获取 $($models.Count) 个模型。"

    $chosenModels = Choose-Models -Models $models
    if ($chosenModels.Count -eq 0) {
        Write-Err "未选择任何模型。"
        exit 1
    }

    Write-Section "开始探测 Tool Call"

    foreach ($m in $chosenModels) {
        $script:Total++
        Write-Host "→ 测试模型: $m" -ForegroundColor DarkGray

        $probe = Test-ModelToolCall -BaseUrl $baseUrl -ApiKey $apiKey -Model $m

        switch ($probe.Status) {
            'PASS' {
                $script:Pass++
                Write-Ok "$m 支持 tool call（$($probe.Detail)）"
                Add-Result -Model $m -Status 'PASS' -Detail $probe.Detail
            }
            'SOFT_PASS' {
                $script:SoftPass++
                Write-Warn "$m 返回内容疑似提及工具，但未严格返回 tool_calls"
                Add-Result -Model $m -Status 'SOFT_PASS' -Detail $probe.Detail
            }
            default {
                $script:Fail++
                Write-Err "$m 未检测到有效 tool_calls（$($probe.Detail)）"
                Add-Result -Model $m -Status 'FAIL' -Detail $probe.Detail
            }
        }
    }

    Render-Summary
    Write-Section "完成"
    Write-Ok "探测结束。"
}

Main
