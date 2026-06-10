param(
    [switch]$BuildOnly,
    [switch]$SkipBuild,
    [string]$Threads = ""
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Build-CppProject {
    $gpp = Get-Command g++.exe -ErrorAction SilentlyContinue
    if (-not $gpp) {
        $gpp = Get-Command g++ -ErrorAction SilentlyContinue
    }

    if (-not $gpp) {
        Write-Host "[ERROR] g++ not found in PATH." -ForegroundColor Red
        Write-Host "[HINT ] Install MinGW-w64 or MSYS2 g++ and add it to PATH." -ForegroundColor Yellow
        return 1
    }

    $buildCommand = '"{0}" -O3 -std=c++17 -pthread template_matching.cpp -o template_matching.exe' -f $gpp.Source
    Write-Host "[INFO] Building: $buildCommand"
    Invoke-Expression $buildCommand

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Build failed." -ForegroundColor Red
        return [int]$LASTEXITCODE
    }

    return 0
}

function Invoke-Case([int]$id, [string]$small, [string]$large, [string]$threadsArg) {
    Write-Host ""
    Write-Host "==============================="
    Write-Host "Case $id"
    Write-Host "==============================="

    $cmd = ".\template_matching.exe --small $small --large $large"
    if ($threadsArg) {
        $cmd += " --threads `"$threadsArg`""
    }

    Invoke-Expression $cmd
    return [int]$LASTEXITCODE
}

if (-not $SkipBuild) {
    $buildCode = Build-CppProject
    if ($buildCode -ne 0) {
        exit $buildCode
    }
}

if ($BuildOnly) {
    Write-Host "[DONE] Build only completed."
    exit 0
}

$cases = @(
    @{ id = 1; small = "data/1/S1_3_3.txt"; large = "data/1/T1_3750_4320.txt" },
    @{ id = 2; small = "data/2/S2_5_5.txt"; large = "data/2/T2_7750_1320.txt" },
    @{ id = 3; small = "data/3/S3_3_3.txt"; large = "data/3/T3_8140_9925.txt" },
    @{ id = 4; small = "data/4/S4_5_5.txt"; large = "data/4/T4_50_50.txt" },
    @{ id = 5; small = "data/5/S5_5_5.txt"; large = "data/5/T5_5000_5000.txt" }
)

foreach ($c in $cases) {
    $code = Invoke-Case -id $c.id -small $c.small -large $c.large -threadsArg $Threads
    if ($code -ne 0) {
        Write-Host "[ERROR] Case $($c.id) failed." -ForegroundColor Red
        exit $code
    }
}

Write-Host ""
Write-Host "[DONE] All cases finished." -ForegroundColor Green
exit 0
