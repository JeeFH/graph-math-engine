<#
.SYNOPSIS
  CalcEngine 跨包导出面校验（无需编译器即可发现"导入了未导出的符号"）。

.DESCRIPTION
  HAR 包的公开面由其 Index.ets 决定。模块重组后最常见、且只有编译才暴露的错误是：
  消费方 import 了某个符号，而目标包的 Index.ets 并未导出它。

  本脚本静态解析两侧并做差集：
    1. 从每个包的 Index.ets 收集导出符号（`export { A, type B, C as D } from ...`
       与 `export class/function/const/enum/interface X`）
    2. 从所有消费方源码收集 `import { ... } from '<pkg>'` 的符号
    3. 报告"被导入但未被导出"的符号

  同时校验：源码中出现的包说明符是否都在该模块 oh-package.json5 的 dependencies 里声明
  （ohpm 要求直接导入的包必须直接声明，传递依赖不可直接 import）。

.PARAMETER Root
  仓库根目录绝对路径。默认取脚本所在目录的上一级。

.EXAMPLE
  pwsh scripts/check-exports.ps1
  退出码 0 = 全部一致；1 = 发现缺口。
#>
[CmdletBinding()]
param(
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot 在 param() 默认值表达式里尚未赋值，故在体内解析：
# 仓库根 = 本脚本所在 scripts/ 的上一级
if (-not $Root) {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
  $Root = Split-Path -Parent $scriptDir
}
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath

# 包名 -> 模块目录名（本仓两者一致）
$packages = @('calcengine-core', 'calcengine-exp', 'calcengine-graph', 'calcengine-graph-ui')

function Read-Text {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  return $text
}

function Get-ExportedName {
  # `export { A as B }` 对外暴露的名字是 B（as 之后）
  param([string]$Part)
  $n = $Part -replace '^\s*type\s+', ''
  $n = $n.Trim()
  if ($n -match '^(.*?)\s+as\s+(\w+)\s*$') { return $Matches[2] }
  return $n
}

function Get-ImportedName {
  # `import { A as B }` 要求包导出的是 A（as 之前），B 只是本地别名
  param([string]$Part)
  $n = $Part -replace '^\s*type\s+', ''
  $n = $n.Trim()
  if ($n -match '^(\w+)\s+as\s+.*$') { return $Matches[1] }
  return $n
}

# ---------- 1. 收集每个包的导出符号 ----------
$exports = @{}
foreach ($p in $packages) {
  $indexPath = Join-Path $Root "$p\Index.ets"
  if (-not (Test-Path $indexPath)) {
    Write-Host "[WARN] missing Index.ets for $p" -ForegroundColor Yellow
    $exports[$p] = @()
    continue
  }
  $text = Read-Text -Path $indexPath
  $syms = New-Object System.Collections.Generic.List[string]

  # export { A, type B, C as D } from '...'
  foreach ($m in [regex]::Matches($text, 'export\s+(?:type\s+)?\{([^}]*)\}\s*from')) {
    foreach ($part in ($m.Groups[1].Value -split ',')) {
      $name = Get-ExportedName -Part $part
      if ($name) { $syms.Add($name) }
    }
  }
  # export class / function / const / enum / interface X
  foreach ($m in [regex]::Matches($text, 'export\s+(?:default\s+)?(?:class|function|const|enum|interface)\s+(\w+)')) {
    $syms.Add($m.Groups[1].Value)
  }
  $exports[$p] = ($syms | Sort-Object -Unique)
}

# ---------- 2. 收集每个模块声明的依赖 ----------
$declaredDeps = @{}
foreach ($p in ($packages + 'demo')) {
  $pkgPath = Join-Path $Root "$p\oh-package.json5"
  $declaredDeps[$p] = @()
  if (-not (Test-Path $pkgPath)) { continue }
  $text = Read-Text -Path $pkgPath
  $dm = [regex]::Match($text, '"dependencies"\s*:\s*\{([^}]*)\}', 'Singleline')
  if ($dm.Success) {
    foreach ($km in [regex]::Matches($dm.Groups[1].Value, '"([^"]+)"\s*:')) {
      $declaredDeps[$p] += $km.Groups[1].Value
    }
  }
}

# ---------- 3. 扫描消费方源码的包导入 ----------
$problems = New-Object System.Collections.Generic.List[string]
$importCount = 0

foreach ($p in ($packages + 'demo')) {
  $srcRoot = Join-Path $Root $p
  if (-not (Test-Path $srcRoot)) { continue }
  $files = Get-ChildItem -Path $srcRoot -Recurse -File -Filter '*.ets' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(oh_modules|build|\.test|\.preview)\\' }

  foreach ($f in $files) {
    $text = Read-Text -Path $f.FullName
    $rel = $f.FullName.Substring($Root.Length + 1)

    foreach ($m in [regex]::Matches($text, 'import\s+(?:type\s+)?\{([^}]*)\}\s*from\s*[''"]([\w@./-]+)[''"]', 'Singleline')) {
      $spec = $m.Groups[2].Value
      if ($packages -notcontains $spec) { continue }
      if ($spec -eq $p) { continue }   # 自引用不合法但不在本脚本职责内

      $importCount++

      # 3a. 依赖是否已声明
      if ($declaredDeps[$p] -notcontains $spec) {
        $problems.Add("[$p] $rel imports '$spec' but it is NOT declared in $p/oh-package.json5 dependencies")
      }

      # 3b. 符号是否已导出
      foreach ($part in ($m.Groups[1].Value -split ',')) {
        $name = Get-ImportedName -Part $part
        if (-not $name) { continue }
        if ($exports[$spec] -notcontains $name) {
          $problems.Add("[$p] $rel imports '$name' from '$spec' but $spec/Index.ets does NOT export it")
        }
      }
    }
  }
}

# ---------- 4. 报告 ----------
Write-Host ''
Write-Host '=== export surface ===' -ForegroundColor Cyan
foreach ($p in $packages) {
  Write-Host ("  {0,-24} {1} exported symbols" -f $p, $exports[$p].Count)
}
Write-Host ''
Write-Host "=== cross-package imports checked: $importCount ===" -ForegroundColor Cyan

if ($problems.Count -eq 0) {
  Write-Host '[OK] every imported symbol is exported, every imported package is declared' -ForegroundColor Green
  exit 0
} else {
  Write-Host "[FAIL] $($problems.Count) problem(s):" -ForegroundColor Red
  $problems | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
