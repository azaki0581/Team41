# ==============================================================================
#  build-recipes.ps1
#
#    data/raw-cookrcp01.json  ──▶  recipes.js
#    (API 원본 스냅샷)              (앱이 읽는 파일)
#
#  실행:  .\tools\build-recipes.ps1
#         원본은 그대로 두고 가공 규칙만 바꿀 때 이것만 반복 실행하면 된다.
#
#  하는 일
#    1) 재료 텍스트에서 이름/계량을 분리하고 표준 이름을 붙인다
#       원본이 정형화되어 있지 않아 '양파(20g)', '(속재료)고구마', '<br>' 등
#       여러 형태를 처리한다 (README 의 '재료 파싱에서 잡은 것들' 참고)
#    2) 재료가 진짜 식재료인지 양념인지 코퍼스 전체를 보고 판정한다 (2패스)
#    3) 조리 단계를 정리한다 (번호·이미지 마커 제거, 단계별 사진 연결)
#    4) 조리시간을 계산한다 (문장에 적힌 시간 + 동작 기준 추정, 대기시간 분리)
#    5) 작업량을 계산한다 (지시문 분량 + 재료 수 + 실패 위험 기법)
#    6) 앱의 '양념·조미료' 체크 목록을 사용 빈도순으로 뽑는다
#
#  ※ 한글이 들어가는 값은 전부 tools/rules.json 에 두고 여기서는 로직만 다룬다.
#    (Windows PowerShell 5.1 의 한글 인코딩 문제를 피하기 위함)
#    이 스크립트를 편집할 때는 반드시 UTF-8 BOM 으로 저장할 것.
# ==============================================================================
param(
  [switch]$Verbose
)

$ErrorActionPreference = "Stop"

$root    = Split-Path -Parent $PSScriptRoot
$rawFile = Join-Path $root "data\raw-cookrcp01.json"
$outFile = Join-Path $root "recipes.js"
$rulesF  = Join-Path $PSScriptRoot "rules.json"

if (-not (Test-Path $rawFile)) { throw "No raw data. Run .\tools\fetch-recipes.ps1 first." }

$rules = Get-Content -LiteralPath $rulesF  -Raw -Encoding UTF8 | ConvertFrom-Json
$raw   = Get-Content -LiteralPath $rawFile -Raw -Encoding UTF8 | ConvertFrom-Json

$MIN = $rules.timeUnitMinute
$HR  = $rules.timeUnitHour

# hashtable 변환 (PSCustomObject -> lookup)
function ToMap($obj) {
  $m = @{}
  if ($null -ne $obj) { $obj.PSObject.Properties | ForEach-Object { $m[$_.Name] = $_.Value } }
  return $m
}
$aliasMap   = ToMap $rules.ingredientAliases
$seasonSet  = @{}; $rules.seasoningKeys | ForEach-Object { $seasonSet[$_] = $true }
$stapleSet  = @{}; $rules.pantryStaples | ForEach-Object { $stapleSet[$_] = $true }

# ------------------------------------------------------------
# 재료 표준명: 수식어 제거 -> 별칭 매핑
# ------------------------------------------------------------
function Get-IngredientKey([string]$name) {
  $k = $name -replace '\s',''
  foreach ($m in $rules.modifierStrip) {
    $mm = $m -replace '\s',''
    if ($k.Length -gt $mm.Length -and $k.StartsWith($mm)) { $k = $k.Substring($mm.Length) }
  }
  if ($aliasMap.ContainsKey($k)) { $k = $aliasMap[$k] }
  return $k
}

# ------------------------------------------------------------
# RCP_PARTS_DTLS 파싱
#   "연두부 75g(3/4모), 칵테일새우 20g(5마리)" -> [{name, amount}]
# ------------------------------------------------------------
# "물녹말(녹말가루 10g, 물 10g), 설탕 5g" 처럼 괄호 안에 쉼표가 들어가는 경우가 있다.
# 그냥 ',' 로 쪼개면 "물녹말(녹말가루" 같은 쓰레기가 생기므로 괄호 밖 쉼표에서만 자른다.
function Split-TopLevel([string]$line) {
  $parts = @(); $buf = ""; $depth = 0
  foreach ($ch in $line.ToCharArray()) {
    if     ($ch -eq '(') { $depth++ }
    elseif ($ch -eq ')') { if ($depth -gt 0) { $depth-- } }
    if ($ch -eq ',' -and $depth -eq 0) { $parts += $buf; $buf = "" }
    else { $buf += $ch }
  }
  if ($buf.Trim() -ne "") { $parts += $buf }
  return $parts
}

function Test-SeasonGroup([string]$group) {
  if ($group -eq "") { return $false }
  foreach ($h in $rules.groupSeasonHints) { if ($group.Contains($h)) { return $true } }
  return $false
}

function Parse-Ingredients([string]$text, [string]$recipeName) {
  $out = @()
  if ([string]::IsNullOrWhiteSpace($text)) { return $out }

  # 원문에 <br> 태그가 줄바꿈 대신 쓰인 경우가 많다. 먼저 진짜 줄바꿈으로 바꾼다.
  $text = [regex]::Replace($text, '(?i)<br\s*/?>', "`n")
  $text = [regex]::Replace($text, '<[^>]{1,20}>', '')      # 남은 HTML 태그 제거

  $lines = $text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
  $group = ""          # 현재 구획명 (예: "양념장")

  foreach ($rawLine in $lines) {
    $line = $rawLine
    foreach ($b in $rules.bulletChars) { $line = $line.TrimStart($b).Trim() }   # ●, · 등 제거
    $line = [regex]::Replace($line, '^\[[^\]]*\]\s*', '')                       # "[1인분]" 제거
    if ($line -eq "") { continue }
    if ($line -match $rules.servingHeaderPattern) { continue }                  # "1인분 기준" 같은 줄

    # "양념장 : 저염간장 3g, ..." / "●양념장 :" (단독 줄)  ->  구획명 갱신
    $gm = [regex]::Match($line, '^(?<g>[^,:]{1,15}?)\s*:\s*(?<rest>.*)$')
    if ($gm.Success) {
      $group = $gm.Groups['g'].Value.Trim()
      $line  = $gm.Groups['rest'].Value.Trim()
      if ($line -eq "") { continue }
    }

    # 숫자도 쉼표도 없는 줄 = 레시피명 반복 또는 "고명" 같은 구획 제목
    if ($line -notmatch '\d' -and -not $line.Contains(',')) {
      $group = $line
      continue
    }

    $groupIsSeason = Test-SeasonGroup $group

    foreach ($tok in (Split-TopLevel $line)) {
      $t = $tok.Trim().Trim('"', "'", [char]0x201C, [char]0x201D)
      # "(속재료)고구마 50g" 처럼 괄호로 구획을 표시하는 형태도 있다.
      # 구획명으로 옮기고 재료명에서는 떼어낸다.
      $gp = [regex]::Match($t, '^\((?<g>[^)]{1,14})\)\s*(?<rest>.+)$')
      if ($gp.Success -and $gp.Groups['rest'].Value.Trim() -ne "") {
        $group = $gp.Groups['g'].Value.Trim()
        $groupIsSeason = Test-SeasonGroup $group
        $t = $gp.Groups['rest'].Value.Trim()
      }
      $t = $t.Trim().TrimEnd('.')
      # 계량의 "(3/4모)" 는 살리고, 짝 없는 닫는 괄호만 제거
      while ($t.EndsWith(')') -and
             ([regex]::Matches($t, '\)').Count -gt [regex]::Matches($t, '\(').Count)) {
        $t = $t.Substring(0, $t.Length - 1).Trim()
      }
      if ($t -eq "") { continue }

      $nm = $t; $amt = ""
      # (1) "양파(20g)" 처럼 이름 뒤 괄호에 계량이 통째로 들어간 형태
      $mp = [regex]::Match($t, '^(?<n>[^()]+?)\s*\((?<a>[^()]*\d[^()]*)\)$')
      $m  = [regex]::Match($t, '^(?<n>[^0-9]+?)\s*(?<a>[0-9].*)$')
      # 이름에 숫자가 있으면 (1)이 아니다. "달걀 50g(1개)" 를 이름 "달걀 50g" 으로
      # 잘못 잡던 문제 때문에 반드시 확인한다.
      if ($mp.Success -and $mp.Groups['n'].Value -notmatch '\d') {
        $nm  = $mp.Groups['n'].Value.Trim()
        $amt = $mp.Groups['a'].Value.Trim()
      } elseif ($m.Success) {
        # (2) "연두부 75g(3/4모)" 처럼 이름 뒤 공백 + 숫자로 시작하는 형태
        $nm  = $m.Groups['n'].Value.Trim()
        $amt = $m.Groups['a'].Value.Trim()
        # 이름 끝에 여는 괄호가 남으면 계량 쪽으로 넘긴다
        if ($nm.EndsWith('(')) { $nm = $nm.TrimEnd('(').Trim(); $amt = "(" + $amt }
      } else {
        foreach ($w in $rules.amountOnlyWords) {                       # "소금 약간"
          $i = $t.IndexOf($w)
          if ($i -gt 0) { $nm = $t.Substring(0, $i).Trim(); $amt = $t.Substring($i).Trim(); break }
        }
      }
      if ($nm -eq "" -or $nm.Length -gt 20) { continue }

      $key = Get-IngredientKey $nm
      if ($key -eq "") { continue }

      # 최종 양념 여부는 전체 코퍼스를 한 번 훑은 뒤 결정한다(2패스).
      # 여기서는 판단 근거만 남긴다.
      $out += [ordered]@{
        name          = $nm
        amount        = $amt
        key           = $key
        group         = $group
        inSeasonGroup = [bool]$groupIsSeason        # ●양념장: 구획 안에 있었나
        isSeasonWord  = [bool]$seasonSet.ContainsKey($key)   # 소금·간장처럼 그 자체가 양념인가
      }
    }
  }

  # 표준명 기준 중복 제거
  $seen = @{}; $uniq = @()
  foreach ($i in $out) {
    if (-not $seen.ContainsKey($i.key)) { $seen[$i.key] = $true; $uniq += $i }
  }
  return $uniq
}

# ------------------------------------------------------------
# 조리 단계 정리: "3. ~~~ 찐다.c" -> "~~~ 찐다."
# ------------------------------------------------------------
# 원본 이미지 URL이 http:// 라서 https 배포(Vercel)에서 차단된다. https로 교체.
function Fix-Url([string]$u) {
  if ([string]::IsNullOrWhiteSpace($u)) { return "" }
  return ($u.Trim() -replace '^http://', 'https://')
}

function Clean-Step([string]$s) {
  $t = $s.Trim()
  $t = [regex]::Replace($t, '^\s*\d+\s*[.)]\s*', '')      # 앞 번호
  $t = [regex]::Replace($t, '\s*[a-zA-Z]\s*$', '')        # 끝 이미지 마커(a,b,c)
  return $t.Trim()
}

# ------------------------------------------------------------
# 단계 텍스트에서 시간 추출 (분 / 시간, "3~4분" 범위 지원)
# ------------------------------------------------------------
function Get-StatedMinutes([string]$t) {
  $total = 0; $found = $false
  $rxMin = '(\d+)\s*(?:~\s*(\d+)\s*)?' + [regex]::Escape($MIN)
  foreach ($m in [regex]::Matches($t, $rxMin)) {
    $v = [int]$m.Groups[1].Value
    if ($m.Groups[2].Success) { $v = [int]$m.Groups[2].Value }   # 범위면 큰 값
    $total += $v; $found = $true
  }
  $rxHr = '(\d+)\s*' + [regex]::Escape($HR)
  foreach ($m in [regex]::Matches($t, $rxHr)) {
    $total += ([int]$m.Groups[1].Value) * 60; $found = $true
  }
  return @{ minutes = $total; stated = $found }
}

function Get-VerbMinutes([string]$t) {
  foreach ($v in $rules.verbMinutes) {
    if ($t.Contains($v.stem)) { return [int]$v.min }
  }
  return [int]$rules.defaultStepMinutes
}

function Test-WaitStep([string]$t) {
  foreach ($w in $rules.waitVerbs) { if ($t.Contains($w)) { return $true } }
  return $false
}

# ------------------------------------------------------------
# 메인 변환
# ------------------------------------------------------------
$recipes = @()
$skipped = 0
$stats   = @{ levels = @{}; statedSteps = 0; allSteps = 0 }   # 요약용 (출력 데이터와 분리)

# ------------------------------------------------------------
#  1패스: 어떤 재료가 '진짜 식재료'인지 데이터로 판정한다.
#
#  ●양념장: 구획 안에 있다는 이유만으로 양파·대파·당근까지 양념 취급되던 문제가 있었다.
#  손으로 예외 목록을 관리하는 대신, 코퍼스 전체에서 그 재료가 양념 구획 '밖'에
#  주재료로 몇 번 등장하는지 세어서 판단한다. 자주 등장하면 진짜 식재료다.
# ------------------------------------------------------------
$mainKeyCount = @{}
foreach ($row in $raw.rows) {
  foreach ($i in (Parse-Ingredients $row.RCP_PARTS_DTLS ($row.RCP_NM))) {
    if (-not $i.inSeasonGroup -and -not $i.isSeasonWord) {
      $mainKeyCount[$i.key] = [int]$mainKeyCount[$i.key] + 1
    }
  }
}
$MAIN_MIN = 3   # 주재료로 3번 이상 등장하면 양념 구획에 있어도 식재료로 본다
$RARE_MAX = 5   # 코퍼스 전체에서 5번 미만이면 '구하기 어려운 재료'로 본다
Write-Host ("  pass1: {0} distinct ingredient keys seen as real food" -f
            @($mainKeyCount.Keys | Where-Object { $mainKeyCount[$_] -ge $MAIN_MIN }).Count)

foreach ($row in $raw.rows) {
  $name = ($row.RCP_NM).Trim()
  if ([string]::IsNullOrWhiteSpace($name)) { $skipped++; continue }

  # --- 단계 ---
  $steps = @()
  for ($i = 1; $i -le 20; $i++) {
    $f  = "MANUAL{0:D2}" -f $i
    $fi = "MANUAL_IMG{0:D2}" -f $i
    $txt = $row.$f
    if ([string]::IsNullOrWhiteSpace($txt)) { continue }
    $clean = Clean-Step $txt
    if ($clean -eq "") { continue }

    $st   = Get-StatedMinutes $clean
    $wait = Test-WaitStep $clean
    $mins = if ($st.stated) { $st.minutes } else { Get-VerbMinutes $clean }

    # 계산에 쓰는 값은 여기 로컬 변수로만 두고, 최종 출력에는 화면에 쓰는 것만 담는다
    $steps += [ordered]@{
      text    = $clean
      img     = Fix-Url $row.$fi
      minutes = $mins
      stated  = [bool]$st.stated
      wait    = [bool]$wait
    }
  }
  if ($steps.Count -eq 0) { $skipped++; continue }

  # --- 재료 (1패스 결과로 최종 판정) ---
  $ings = @()
  foreach ($i in (Parse-Ingredients $row.RCP_PARTS_DTLS $name)) {
    if ($i.isSeasonWord) {
      $isSeason = $true                       # 소금·간장 등은 언제나 양념
    } elseif ($i.inSeasonGroup) {
      # 양념장 구획 안이라도, 다른 레시피에서 주재료로 자주 쓰이면 식재료로 본다
      $isSeason = ([int]$mainKeyCount[$i.key] -lt $MAIN_MIN)
    } else {
      $isSeason = $false
    }
    $i.seasoning = $isSeason
    # 기본 양념(소금·간장 등)이면 true. false 면 '따로 사야 할 수도 있는 양념'
    $i.staple = [bool]($isSeason -and $stapleSet.ContainsKey($i.key))
    # 코퍼스 전체에서 거의 안 쓰이는 재료(락교·머위대 등)는 사러 가기도 어렵다.
    # 이런 재료를 요구하는 레시피는 앱에서 뒤로 밀기 위해 표시해 둔다.
    $i.rare = [bool](-not $isSeason -and [int]$mainKeyCount[$i.key] -lt $RARE_MAX)
    $ings += $i
  }
  if ($ings.Count -eq 0) { $skipped++; continue }

  # --- 시간: 조리 / 대기 분리, 근거 보존 ---
  $active = 0; $wait = 0; $statedCount = 0
  foreach ($s in $steps) {
    if ($s.wait) { $wait += $s.minutes } else { $active += $s.minutes }
    if ($s.stated) { $statedCount++ }
  }
  $tmin = [int][Math]::Max(5, [Math]::Round($active * 0.9))
  $tmax = [int][Math]::Max($tmin + 5, [Math]::Round($active * 1.3))

  # --- 난이도: 관측 가능한 요소로 계산 ---
  $techs = @()
  $allText = ($steps | ForEach-Object { $_.text }) -join " "
  foreach ($t in $rules.techniques) {
    foreach ($mm in $t.match) {
      if ($allText.Contains($mm)) { if ($techs -notcontains $t.key) { $techs += $t.key }; break }
    }
  }
  $hard = $false
  foreach ($h in $rules.hardTechniques)  { if ($techs -contains $h) { $hard = $true; break } }
  if (-not $hard) { foreach ($h in $rules.hardTextHints) { if ($allText.Contains($h)) { $hard = $true; break } } }

  # 작업량 = 조리 지시문 분량 + 재료 수 + 실패 위험 기법 여부
  # (조리 '실력'은 데이터로 알 수 없으므로 추정하지 않는다)
  $charCount = ($steps | ForEach-Object { $_.text.Length } | Measure-Object -Sum).Sum
  $score = [Math]::Floor($charCount / 100) + [Math]::Floor($ings.Count / 4) + ($steps.Count * 0.5)
  if ($hard) { $score += 3 }
  $score = [Math]::Round($score, 1)

  $level = 3
  if     ($score -le $rules.workloadThresholds.easy)   { $level = 1 }
  elseif ($score -le $rules.workloadThresholds.normal) { $level = 2 }

  $stats.levels["$level"] = [int]$stats.levels["$level"] + 1
  $stats.statedSteps += $statedCount
  $stats.allSteps    += $steps.Count

  # --- 출력: 화면에서 실제로 쓰는 것만 담는다 (파일 크기 = 첫 로딩 속도) ---
  $outIngs = @()
  foreach ($i in $ings) {
    $outIngs += [ordered]@{
      name = $i.name; amount = $i.amount; key = $i.key
      seasoning = $i.seasoning; staple = $i.staple; rare = $i.rare
    }
  }
  $outSteps = @()
  foreach ($s in $steps) {
    $outSteps += [ordered]@{ text = $s.text; img = $s.img }
  }

  $recipes += [ordered]@{
    id    = "$($row.RCP_SEQ)"
    name  = $name
    cat   = ($row.RCP_PAT2).Trim()
    ings  = $outIngs
    steps = $outSteps
    time  = [ordered]@{ min = $tmin; max = $tmax; wait = $wait }
    work  = $level
    nutri = [ordered]@{
      kcal = "$($row.INFO_ENG)"; carb = "$($row.INFO_CAR)"
      pro  = "$($row.INFO_PRO)"; fat  = "$($row.INFO_FAT)"; na = "$($row.INFO_NA)"
    }
    wgt   = "$($row.INFO_WGT)"
    tip   = "$($row.RCP_NA_TIP)".Trim()
    img   = Fix-Url $row.ATT_FILE_NO_MAIN
  }
}

# ------------------------------------------------------------
#  앱의 '양념·조미료' 체크 목록을 만든다.
#  사용자가 집에 있는 양념을 직접 고르면 매칭률에 반영되므로,
#  실제로 자주 쓰이는 것부터 보여준다.
# ------------------------------------------------------------
$seasonCount = @{}
foreach ($r in $recipes) {
  foreach ($i in $r.ings) {
    if ($i.seasoning) { $seasonCount[$i.key] = [int]$seasonCount[$i.key] + 1 }
  }
}
$alwaysSet = @{}; $rules.alwaysHave | ForEach-Object { $alwaysSet[$_] = $true }
$seasonList = @()
foreach ($k in ($seasonCount.Keys | Sort-Object { -$seasonCount[$_] })) {
  if ($k.Length -gt 8 -or $k -match '\d') { continue }        # 파싱 잔재 제외
  if ($alwaysSet.ContainsKey($k)) { continue }                # 물 등은 체크 목록에서 뺀다
  $seasonList += [ordered]@{
    key    = $k
    count  = $seasonCount[$k]
    staple = [bool]$stapleSet.ContainsKey($k)                  # 기본으로 체크해 둘 것
  }
  if ($seasonList.Count -ge 24) { break }
}

$db = [ordered]@{
  source     = $raw.source
  sourceUrl  = $raw.sourceUrl
  fetchedAt  = $raw.fetchedAt
  sampleOnly = $raw.sampleOnly
  aliases    = $rules.userInputAliases
  seasonings = $seasonList
  alwaysHave = $rules.alwaysHave
  count      = $recipes.Count
  recipes    = $recipes
}

$json = $db | ConvertTo-Json -Depth 8 -Compress

# ConvertTo-Json 은 한글을 \uXXXX 로 이스케이프한다(글자당 6바이트).
# 그대로 두면 파일이 3배로 불어나므로 실제 문자로 되돌린다. (제어문자/따옴표는 건드리지 않음)
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
  param($m)
  $code = [Convert]::ToInt32($m.Groups[1].Value, 16)
  if ($code -gt 0x7F) { [char]$code } else { $m.Value }
})

$js = "/* 자동 생성 파일 - 직접 수정하지 마세요. tools/build-recipes.ps1 이 만듭니다. */" + "`r`n" +
      "window.RECIPE_DB = " + $json + ";" + "`r`n"
[System.IO.File]::WriteAllText($outFile, $js, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "OK  $($recipes.Count) recipes -> $outFile  (skipped $skipped)" -ForegroundColor Green

# --- 요약 통계 ---
Write-Host "  workload:" -NoNewline
foreach ($k in ($stats.levels.Keys | Sort-Object)) { Write-Host ("  L{0}={1}" -f $k, $stats.levels[$k]) -NoNewline }
Write-Host ""
$pct = if ($stats.allSteps -gt 0) { [Math]::Round($stats.statedSteps * 100 / $stats.allSteps) } else { 0 }
Write-Host "  steps with an explicit time in the source text: $pct%"
$topIng = $recipes | ForEach-Object { $_.ings } | ForEach-Object { $_.key } |
          Group-Object | Sort-Object Count -Descending | Select-Object -First 25
Write-Host "  top ingredient keys:"
Write-Host ("    " + (($topIng | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ", "))
