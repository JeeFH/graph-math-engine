<#
.SYNOPSIS
  CalcEngine 仓库结构与发布就绪度检查（无需 HarmonyOS SDK）。

.DESCRIPTION
  校验仓库层面的不变量，作为 CI 与本地提交前自检使用：
  1. 四个包是否各具备最小发布文件集
  2. 四个包的版本号是否一致
  3. 内部依赖形态是否统一（全开发态 file: 或全发布态 ^版本，不允许混用）
  4. 发布态下内部依赖的版本区间是否与工作区版本一致
  5. 源码与包文档中是否残留改名前的旧模块名
  6. 根级文档是否齐备

  注意：本脚本不做编译，也不需要 SDK —— 它只校验静态结构，因此可以在任意
  CI runner 上运行。编译校验需 DevEco Studio / HarmonyOS SDK，属另一层。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-repo-health.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
} else {
  $scriptDir = $PSScriptRoot
}
$Root = (Resolve-Path -LiteralPath (Split-Path -Parent $scriptDir)).ProviderPath

# 发布顺序即依赖顺序
$packages = @('calcengine-core', 'calcengine-exp', 'calcengine-graph', 'calcengine-graph-ui')
# 每个包的内部依赖（仅直接依赖）
$internalDeps = @{
  'calcengine-core'     = @()
  'calcengine-exp'      = @()
  'calcengine-graph'    = @('calcengine-core')
  'calcengine-graph-ui' = @('calcengine-core', 'calcengine-exp', 'calcengine-graph')
}
# 包内应具备的最小文件集
$requiredFiles = @('oh-package.json5', 'Index.ets', 'build-profile.json5', 'hvigorfile.ts',
  'README.md', 'LICENSE', 'src\main\module.json5')
# 根级文档
$rootDocs = @('README.md', 'API.md', 'ARCHITECTURE.md', 'CHANGELOG.md',
  'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md', 'LICENSE')
# 改名前的旧名，不应再作为模块/包标识出现
$staleNames = @('mathkit', 'exprrender', 'graph-ui')

$errors = New-Object System.Collections.Generic.List[string]
$warns = New-Object System.Collections.Generic.List[string]

function Read-Text {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  return $text
}

# ---------- 1/2/4 包级检查 ----------
$versions = @{}
$forms = @{}
foreach ($pkg in $packages) {
  $dir = Join-Path $Root $pkg
  if (-not (Test-Path $dir)) {
    $errors.Add("missing package directory: $pkg")
    continue
  }
  foreach ($f in $requiredFiles) {
    if (-not (Test-Path (Join-Path $dir $f))) {
      $errors.Add("$pkg is missing required file: $f")
    }
  }
  $pkgJsonPath = Join-Path $dir 'oh-package.json5'
  if (-not (Test-Path $pkgJsonPath)) { continue }
  $text = Read-Text -Path $pkgJsonPath

  $m = [regex]::Match($text, '"version"\s*:\s*"([^"]+)"')
  $versions[$pkg] = if ($m.Success) { $m.Groups[1].Value } else { '' }

  $nm = [regex]::Match($text, '"name"\s*:\s*"([^"]+)"')
  if (-not $nm.Success -or $nm.Groups[1].Value -ne $pkg) {
    $errors.Add("$pkg declares a different package name: '$($nm.Groups[1].Value)'")
  }
  if ($text -notmatch '"packageType"\s*:\s*"har"') {
    $errors.Add("$pkg is not declared as packageType har")
  }
  if ($text -notmatch '"repository"') {
    $warns.Add("$pkg has no repository metadata")
  }

  foreach ($dep in $internalDeps[$pkg]) {
    $dm = [regex]::Match($text, '"' + [regex]::Escape($dep) + '"\s*:\s*"([^"]*)"')
    if (-not $dm.Success) {
      $errors.Add("$pkg does not declare internal dependency $dep")
      continue
    }
    $val = $dm.Groups[1].Value
    $form = if ($val.StartsWith('file:')) { 'dev' } else { 'publish' }
    if (-not $forms.ContainsKey($form)) { $forms[$form] = @() }
    $forms[$form] += "$pkg->$dep"
  }
}

# 版本一致
$distinct = @($versions.Values | Where-Object { $_ -ne '' } | Sort-Object -Unique)
if ($distinct.Count -gt 1) {
  $errors.Add("package versions are inconsistent: " +
    (($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
}
$version = if ($distinct.Count -eq 1) { $distinct[0] } else { '' }

# 依赖形态统一
if ($forms.ContainsKey('dev') -and $forms.ContainsKey('publish')) {
  $errors.Add("mixed dependency forms: dev=[$($forms['dev'] -join ', ')] publish=[$($forms['publish'] -join ', ')]")
}

# 发布态的版本区间应与被依赖包的实际版本一致
if ($version -ne '' -and $forms.ContainsKey('publish')) {
  foreach ($pkg in $packages) {
    $text = Read-Text -Path (Join-Path $Root "$pkg\oh-package.json5")
    foreach ($dep in $internalDeps[$pkg]) {
      $dm = [regex]::Match($text, '"' + [regex]::Escape($dep) + '"\s*:\s*"(\^[0-9][^"]*)"')
      if ($dm.Success -and $dm.Groups[1].Value -ne "^$version") {
        $errors.Add("$pkg depends on $dep as '$($dm.Groups[1].Value)' but the workspace version is $version")
      }
    }
  }
}

# ---------- 5 旧名残留（源码 + 包文档）----------
$scanTargets = @()
foreach ($pkg in $packages) { $scanTargets += (Join-Path $Root $pkg) }
foreach ($p in @('README.md', 'API.md', 'ARCHITECTURE.md', 'CONTRIBUTING.md')) {
  $scanTargets += (Join-Path $Root $p)
}
foreach ($target in $scanTargets) {
  if (-not (Test-Path $target)) { continue }
  if ((Get-Item $target).PSIsContainer) {
    $files = Get-ChildItem $target -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object {
        $_.FullName -notmatch '\\(oh_modules|build|\.test|\.preview|\.hvigor)\\' -and
        ($_.Extension -eq '.ets' -or $_.Extension -eq '.ts' -or $_.Extension -eq '.md')
      }
  } else {
    $files = @(Get-Item $target)
  }
  foreach ($f in $files) {
    $t = Read-Text -Path $f.FullName
    foreach ($stale in $staleNames) {
      # 只查"作为模块标识"的用法：import 说明符、相对路径片段、Index 路径
      if ($t -match ("from\s+'" + [regex]::Escape($stale) + "'") -or
          $t -match ("from\s+'\.\./" + [regex]::Escape($stale) + "/") -or
          $t -match ([regex]::Escape($stale) + "/Index\.ets")) {
        $rel = $f.FullName.Substring($Root.Length + 1)
        $errors.Add("stale module name '$stale' referenced in $rel")
      }
    }
  }
}

# ---------- 6 根级文档 ----------
foreach ($d in $rootDocs) {
  if (-not (Test-Path (Join-Path $Root $d))) {
    $errors.Add("missing root document: $d")
  }
}

# ---------- 报告 ----------
Write-Host '=== package versions ===' -ForegroundColor Cyan
foreach ($pkg in $packages) {
  Write-Host ("  {0,-24} {1}" -f $pkg, $versions[$pkg])
}
Write-Host '=== dependency form ===' -ForegroundColor Cyan
if ($forms.Count -eq 0) {
  Write-Host '  (no internal dependencies)'
} else {
  foreach ($k in $forms.Keys) {
    Write-Host ("  {0,-10} {1} entry(ies)" -f $k, $forms[$k].Count)
  }
}

if ($warns.Count -gt 0) {
  Write-Host ''
  foreach ($w in $warns) { Write-Host "[WARN] $w" -ForegroundColor Yellow }
}
if ($errors.Count -gt 0) {
  Write-Host ''
  foreach ($e in $errors) { Write-Host "[FAIL] $e" -ForegroundColor Red }
  Write-Host ''
  Write-Host "[FAILED] $($errors.Count) problem(s)" -ForegroundColor Red
  exit 1
}
Write-Host ''
Write-Host '[OK] packages, versions, dependency form, naming and docs are consistent' -ForegroundColor Green
exit 0
