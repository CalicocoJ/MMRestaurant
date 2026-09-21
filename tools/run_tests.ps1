# 一键跑测试 / 截图 / UI 体检
#
#   .\tools\run_tests.ps1                    # 跑全部测试
#   .\tools\run_tests.ps1 -Screenshot         # 跑测试 + 出一张游戏截图
#   .\tools\run_tests.ps1 -GodotPath "D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
#
# 为什么用 console 版 exe：windowed 版不往 stdout 打印，
# 脚本就拿不到测试结果了。
#
# 【Godot 路径怎么找】没传 -GodotPath 时按这个顺序：
#   ① 环境变量 $env:GODOT  ② PATH 上的 godot ③ 几个常见安装位置
# 找不到就报错并提示怎么传 —— 换台机器 clone 下来不用改脚本。

param(
    [string]$GodotPath = "",
    [switch]$Screenshot,
    [switch]$DumpUI
)

$ErrorActionPreference = "Continue"
$project = Split-Path -Parent $PSScriptRoot

# 【控制台编码】Godot 输出的是 UTF-8，而 Windows PowerShell 默认按本机代码页
# （中文系统是 GBK）解读子进程输出，于是脚本里和 Godot 里的中文全变乱码。
# 先把控制台输出编码设成 UTF-8，中英文才都能正常显示。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
chcp 65001 > $null 2>&1

function Find-Godot {
    if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }
    foreach ($name in @("godot", "godot4", "Godot")) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $cands = @(
        "$env:ProgramFiles\Godot\Godot_v4.7.2-stable_win64_console.exe",
        "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.2-stable_win64_console.exe",
        "C:\Godot\Godot_v4.7.2-stable_win64_console.exe",
        "C:\DS\godot\Godot_v4.7.2-stable_win64_console.exe"
    )
    foreach ($p in $cands) { if (Test-Path $p) { return $p } }
    return ""
}

if ($GodotPath -eq "") { $GodotPath = Find-Godot }

if (-not $GodotPath -or -not (Test-Path $GodotPath)) {
    Write-Host "找不到 Godot（需要 4.7.x 的 console 版）。" -ForegroundColor Red
    Write-Host "三种解决办法，任选其一："
    Write-Host '  ① 把 exe 路径传给脚本：.\tools\run_tests.ps1 -GodotPath "D:\Godot\Godot_v4.7.2-stable_win64_console.exe"'
    Write-Host '  ② 设环境变量：$env:GODOT = "D:\Godot\Godot_v4.7.2-stable_win64_console.exe"'
    Write-Host "  ③ 把 Godot 加进 PATH"
    exit 1
}
Write-Host "Godot: $GodotPath" -ForegroundColor DarkGray

function Invoke-Godot {
    param([string[]]$GodotArgs, [string]$Label)
    Write-Host "--- $Label ---" -ForegroundColor Cyan
    $out = & $GodotPath @GodotArgs 2>&1
    $code = $LASTEXITCODE
    # Godot 把 >user:// 之类的无害错误也写到 stderr，
    # 这里只把真正的脚本错误显示出来，避免噪音淹没结论。
    $noise = 'user://|shader cache|root certificate|Godot_v4|OpenGL API|ui_font\.tres|initialize_theme|^\s*at:|RasterizerGLES3'
    $out | Where-Object { $_ -notmatch $noise }
    return $code
}

$fail = 0

if ((Invoke-Godot -GodotArgs @("--headless", "--path", $project, "res://tools/run_tests.tscn") -Label "单元 + 集成测试") -ne 0) {
    $fail = 1
}

if ($DumpUI) {
    Invoke-Godot -GodotArgs @("--path", $project, "--resolution", "1280x720", "res://tools/dump_ui.tscn", "--", "popups") -Label "UI 布局体检" | Out-Null
}

if ($Screenshot) {
    Invoke-Godot -GodotArgs @("--path", $project, "--resolution", "1280x720",
        "res://tools/screenshot.tscn", "--", "res://.artifacts/game.png", "9") -Label "截图" | Out-Null
    Write-Host "截图：$project\.artifacts\game.png" -ForegroundColor Green
}

if ($fail -eq 0) {
    Write-Host "OK" -ForegroundColor Green
} else {
    Write-Host "FAILED" -ForegroundColor Red
}
exit $fail
