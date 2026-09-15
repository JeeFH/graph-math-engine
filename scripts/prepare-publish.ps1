<#
.SYNOPSIS
  CalcEngine 发布前依赖形态切换：开发态（file:）<-> 发布态（^版本）。

.DESCRIPTION
  开发态：oh-package.json5 用相对路径直连兄弟模块，改动即时生效，便于联动调试。
  发布态：必须改成版本区间，因为 `ohpm publish` 的 --disallow_nested_package
          会检测并拒绝"相对路径的嵌套 .har/.tgz 依赖"。

  本脚本在两种形态之间切换，避免手工改漏。它只改写 `"<包名>": "<值>"` 形式
  的内部依赖项；`"name"` 字段与 `keywords` 不受影响。

.PARAMETER Mode
  dev     -> 切为 file:../<包名>
  publish -> 切为 ^<该包自身 version>
  省略则只报告当前形态（等同 -Check）。

.PARAMETER Check
  只报告不写入。发现混合形态（部分 dev 部分 publish）时以非零码退出。

.PARAMETER ShowOrder
  额外打印 ohpm 发布顺序与命令模板。

.EXAMPLE
  pwsh scripts/prepare-publish.ps1                    # 报告当前形态
  pwsh scripts/prepare-publish.ps1 -Mode publish      # 切为发布态
  pwsh scripts/prepare-publish.ps1 -Mode dev          # 切回开发态
  pwsh scripts/prepare-publish.ps1 -ShowOrder         # 看发布顺序
#>
[CmdletBinding()]
param(
  [ValidateSet('dev', 'publish')]
  [string]$Mode = '',
  [switch]$Check,
  [switch]$ShowOrder
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
} else {
  $scriptDir = $PSScriptRoot
}
$Root = (Resolve-Path -LiteralPath (Split-Path -Parent $scriptDir)).ProviderPath

# 发布顺序即依赖顺序：被依赖者先发
$order = @('calcengine-core', 'calcengine-exp', 'calcengine-graph', 'calcengine-graph-ui')

# 每个包的内部依赖（仅列直接依赖）
$internalDeps = @{
  'calcengine-core'     = @()
  'calcengine-exp'      = @()
  'calcengine-graph'    = @('calcengine-core')
  'calcengine-graph-ui' = @('calcengine-core', 'calcengine-exp', 'calcengine-graph')
}

function Read-Text {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  return $text
}

function Get-Version {
  param([string]$Text)
  $m = [regex]::Match($Text, '"version"\s*:\s*"([^"]+)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

# ---------- 扫描现状 ----------
$report = New-Object System.Collections.Generic.List[object]
$hasDev = $false
$hasPublish = $false

foreach ($pkg in $order) {
  $pkgPath = Join-Path $Root "$pkg\oh-package.json5"
  if (-not (Test-Path $pkgPath)) {
    Write-Host "[WARN] missing $pkg/oh-package.json5" -ForegroundColor Yellow
    continue
  }
  $text = Read-Text -Path $pkgPath
  $ver = Get-Version -Text $text

  foreach ($dep in $internalDeps[$pkg]) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($dep) + '"\s*:\s*"([^"]*)"')
    if (-not $m.Success) {
      Write-Host "[WARN] $pkg does not declare internal dep $dep" -ForegroundColor Yellow
      continue
    }
    $cur = $m.Groups[1].Value
    $isDev = $cur.StartsWith('file:')
    if ($isDev) { $hasDev = $true } else { $hasPublish = $true }
    $report.Add([pscustomobject]@{
      Package = $pkg
      Version = $ver
      Dep     = $dep
      Current = $cur
      Form    = if ($isDev) { 'dev' } else { 'publish' }
    })
  }
}

# ---------- 报告 ----------
Write-Host ''
Write-Host '=== internal dependency form ===' -ForegroundColor Cyan
if ($report.Count -eq 0) {
  Write-Host '  (no internal dependencies)'
} else {
  $report | ForEach-Object {
    Write-Host ("  {0,-22} -> {1,-20} {2,-44} [{3}]" -f $_.Package, $_.Dep, $_.Current, $_.Form)
  }
}

$mixed = $hasDev -and $hasPublish
if ($mixed) {
  Write-Host ''
  Write-Host '[MIXED] some packages are in dev form while others are in publish form' -ForegroundColor Yellow
}

if ($ShowOrder) {
  Write-Host ''
  Write-Host '=== publish order (ohpm) ===' -ForegroundColor Cyan
  $i = 1
  foreach ($pkg in $order) {
    $ver = (Get-Version -Text (Read-Text -Path (Join-Path $Root "$pkg\oh-package.json5")))
    Write-Host "  $i. $pkg @ $ver"
    Write-Host "     `$hvigor assembleHar -p module=$($pkg -replace '-','')@default -p product=default"
    Write-Host "     `$ohpm prepublish <$pkg.har>"
    Write-Host "     `$ohpm publish <$pkg.har> --publish_id <id> --key_path <key> --disallow_nested_package --ensure_dependency_include"
    $i++
  }
  Write-Host ''
  Write-Host '  注意：-p module= 取模块名（去连字符），与包名不同。'
}

if ($Mode -eq '' -or $Check) {
  if ($Check -and $mixed) { exit 1 }
  exit 0
}

# ---------- 写入 ----------
$changed = 0
foreach ($pkg in $order) {
  $pkgPath = Join-Path $Root "$pkg\oh-package.json5"
  if (-not (Test-Path $pkgPath)) { continue }

  $bytes = [System.IO.File]::ReadAllBytes($pkgPath)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = Read-Text -Path $pkgPath
  $ver = Get-Version -Text $text
  $orig = $text

  foreach ($dep in $internalDeps[$pkg]) {
    if ($Mode -eq 'dev') {
      $target = "file:../$dep"
    } else {
      $depVer = Get-Version -Text (Read-Text -Path (Join-Path $Root "$dep\oh-package.json5"))
      if (-not $depVer) {
        Write-Host "[ERROR] cannot read version of $dep" -ForegroundColor Red
        exit 1
      }
      $target = "^$depVer"
    }
    $text = [regex]::Replace($text,
      '"' + [regex]::Escape($dep) + '"\s*:\s*"[^"]*"',
      '"' + $dep + '": "' + $target + '"')
  }

  if ($text -ne $orig) {
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($pkgPath, $text, $enc)
    Write-Host "  updated $pkg/oh-package.json5 -> $Mode" -ForegroundColor Green
    $changed++
  }
}

Write-Host ''
Write-Host "[DONE] mode=$Mode, $changed file(s) updated" -ForegroundColor Green
if ($Mode -eq 'publish') {
  Write-Host '  reminder: run ohpm install after switching to re-resolve, then build HARs.'
} else {
  Write-Host '  reminder: run ohpm install to relink local modules.'
}
exit 0
