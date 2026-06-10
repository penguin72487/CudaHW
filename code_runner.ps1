param(
    # 只編譯，不執行測資。
    [switch]$BuildOnly,
    # 跳過編譯，直接執行現有二進位檔。
    [switch]$SkipBuild,
    # 可選：傳給 template_matching.exe 的 block 清單。
    [string]$Blocks = ""
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Get-VsDevCmdPath {
    # 透過 vswhere 尋找 Visual Studio 開發者命令腳本。
    $vswhere = Join-Path "${env:ProgramFiles(x86)}" "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        return $null
    }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installPath) {
        return $null
    }

    $devCmd = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
    if (Test-Path $devCmd) {
        return $devCmd
    }
    return $null
}

function Get-VcToolsRoot {
    # 定位 MSVC 工具根目錄，用於檢查 cl.exe 是否存在。
    $vswhere = Join-Path "${env:ProgramFiles(x86)}" "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        return $null
    }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installPath) {
        return $null
    }

    $vcRoot = Join-Path $installPath "VC\Tools\MSVC"
    if (Test-Path $vcRoot) {
        return $vcRoot
    }
    return $null
}

function Test-VCCompilerInstalled {
    # 確認 VS 安裝中是否包含 C++ 編譯工具鏈。
    $vcRoot = Get-VcToolsRoot
    if (-not $vcRoot) {
        return $false
    }

    $cl = Get-ChildItem $vcRoot -Recurse -Filter cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -ne $cl)
}

function Show-MsvcInstallHint {
    # 統一輸出缺少 MSVC 時的安裝提示。
    Write-Host "[ERROR] MSVC C++ compiler is missing (cl.exe not found)." -ForegroundColor Red
    Write-Host "[HINT ] Open Visual Studio Installer and modify your Visual Studio installation." -ForegroundColor Yellow
    Write-Host "[HINT ] Install workload: Desktop development with C++." -ForegroundColor Yellow
    Write-Host "[HINT ] Make sure component Microsoft.VisualStudio.Component.VC.Tools.x86.x64 is selected." -ForegroundColor Yellow
}

function Invoke-InVsDevShell([string]$command) {
    # 若系統已可找到 cl.exe，直接執行命令。
    $clPath = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
    if ($clPath) {
        cmd /c $command | Out-Host
        return [int]$LASTEXITCODE
    }

    # 否則先初始化 VS 開發環境，再執行命令。
    $vsDevCmd = Get-VsDevCmdPath
    if (-not $vsDevCmd) {
        Show-MsvcInstallHint
        Write-Host "[HINT ] Also ensure CUDA Toolkit is installed and nvcc is in PATH." -ForegroundColor Yellow
        return 1
    }

    $full = "call `"$vsDevCmd`" -no_logo -arch=amd64 && cd /d `"$PSScriptRoot`" && $command"
    cmd /c $full | Out-Host

    if ($LASTEXITCODE -ne 0 -and -not (Test-VCCompilerInstalled)) {
        Show-MsvcInstallHint
    }

    return [int]$LASTEXITCODE
}

function Build-CudaProject {
    # 編譯 CUDA 程式為 template_matching.exe。
    if (-not (Get-Command nvcc.exe -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] nvcc not found in PATH. Please install CUDA Toolkit." -ForegroundColor Red
        return 1
    }

    $buildCommand = "nvcc -O3 -std=c++17 template_matching.cu -o template_matching.exe"
    Write-Host "[INFO] Building: $buildCommand"
    $code = [int](Invoke-InVsDevShell $buildCommand)
    if ($code -ne 0) {
        Write-Host "[ERROR] Build failed." -ForegroundColor Red
    }
    return $code
}

function Invoke-Case([int]$id, [string]$small, [string]$large, [string]$blocksArg) {
    Write-Host ""
    Write-Host "==============================="
    Write-Host "Case $id"
    Write-Host "==============================="

    $cmd = "template_matching.exe --small $small --large $large"
    # 呼叫端有提供值時，才附加 --blocks 參數。
    if ($blocksArg) {
        $cmd += " --blocks `"$blocksArg`""
    }

    $code = [int](Invoke-InVsDevShell $cmd)
    return $code
}

if (-not $SkipBuild) {
    $buildCode = Build-CudaProject
    if ($buildCode -ne 0) {
        exit $buildCode
    }
}

if ($BuildOnly) {
    Write-Host "[DONE] Build only completed."
    exit 0
}

$cases = @(
    # 作業各組資料對應表。
    @{ id = 1; small = "data\1\S1_3_3.txt"; large = "data\1\T1_3750_4320.txt" },
    @{ id = 2; small = "data\2\S2_5_5.txt"; large = "data\2\T2_7750_1320.txt" },
    @{ id = 3; small = "data\3\S3_3_3.txt"; large = "data\3\T3_8140_9925.txt" },
    @{ id = 4; small = "data\4\S4_5_5.txt"; large = "data\4\T4_50_50.txt" },
    @{ id = 5; small = "data\5\S5_5_5.txt"; large = "data\5\T5_5000_5000.txt" }
)

foreach ($c in $cases) {
    $code = Invoke-Case -id $c.id -small $c.small -large $c.large -blocksArg $Blocks
    if ($code -ne 0) {
        Write-Host "[ERROR] Case $($c.id) failed." -ForegroundColor Red
        exit $code
    }
}

Write-Host ""
Write-Host "[DONE] All cases finished." -ForegroundColor Green
exit 0
