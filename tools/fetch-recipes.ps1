# ==============================================================================
#  fetch-recipes.ps1
#
#    식약처 오픈API  ──▶  data/raw-cookrcp01.json
#                          (API 응답 원본 그대로 보존)
#
#  실행:
#    .\tools\fetch-recipes.ps1 -ApiKey "발급받은인증키"    전체 1,156건
#    .\tools\fetch-recipes.ps1                            키 없이 샘플 5건만
#
#  인증키는 https://www.foodsafetykorea.go.kr/apiMain.do 에서 무료로 받는다.
#  ※ 키를 파일에 적어두지 말 것. 명령줄 인자로만 넘긴다.
#    수집 결과에는 키가 들어가지 않으므로 GitHub 에 올려도 안전하다.
#
#  이 스크립트는 한 번만 돌리면 된다. 이후 가공 규칙 수정은 build-recipes.ps1 로.
# ==============================================================================
param(
  [string]$ApiKey = "sample",
  [int]$PageSize = 1000
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root    = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root "data"
$outFile = Join-Path $dataDir "raw-cookrcp01.json"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$isSample = ($ApiKey -eq "sample")
if ($isSample) {
  Write-Host "[!] No API key given - fetching the 5-row public sample only." -ForegroundColor Yellow
  Write-Host "    Get a key at https://www.foodsafetykorea.go.kr/apiMain.do  ('OpenAPI 인증키 신청')"
  $PageSize = 5
}

$all   = @()
$start = 1
$total = $null

while ($true) {
  $end = $start + $PageSize - 1
  $url = "http://openapi.foodsafetykorea.go.kr/api/$ApiKey/COOKRCP01/json/$start/$end"
  Write-Host ("  fetching {0,5} - {1,5} ..." -f $start, $end) -NoNewline

  $res = Invoke-RestMethod -Uri $url -TimeoutSec 60
  $svc = $res.COOKRCP01

  if ($null -eq $svc) { throw "Unexpected response shape. Check the API key." }
  $code = $svc.RESULT.CODE
  if ($code -ne "INFO-000") {
    if ($code -eq "INFO-200") { Write-Host " (no more rows)"; break }   # 해당 데이터 없음
    throw "API error $code : $($svc.RESULT.MSG)"
  }

  if ($null -eq $total) {
    $total = [int]$svc.total_count
    Write-Host ""
    Write-Host "  total_count = $total" -ForegroundColor Cyan
    Write-Host ("  fetching {0,5} - {1,5} ..." -f $start, $end) -NoNewline
  }

  $rows = @($svc.row)
  $all += $rows
  Write-Host (" got {0,4}  (accumulated {1})" -f $rows.Count, $all.Count)

  if ($isSample) { break }
  if ($all.Count -ge $total -or $rows.Count -eq 0) { break }
  $start = $end + 1
  Start-Sleep -Milliseconds 300           # 서버 부담 완화
}

$payload = [ordered]@{
  source      = "식품의약품안전처 조리식품의 레시피 DB (COOKRCP01)"
  sourceUrl   = "https://www.data.go.kr/data/15060073/openapi.do"
  fetchedAt   = (Get-Date).ToString("yyyy-MM-dd")
  sampleOnly  = $isSample
  totalCount  = $all.Count
  rows        = $all
}

$json = $payload | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "OK  $($all.Count) rows -> $outFile" -ForegroundColor Green
Write-Host "Next: .\tools\build-recipes.ps1"
