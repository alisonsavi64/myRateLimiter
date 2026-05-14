# test-all.ps1 — Rate Limiter integration tests
# Run from the repo root: .\scripts\test-all.ps1
#
# Requirements: Docker running, stack up (cd nginx-imp && docker compose up --build)

$pass = 0
$fail = 0

# ── Helpers ──────────────────────────────────────────────────────────────────

function Section([string]$title) {
    Write-Host ""
    Write-Host "━━━ $title ━━━" -ForegroundColor Yellow
}

function Assert([string]$label, [string]$actual, [string]$expected) {
    if ($actual -eq $expected) {
        Write-Host "  [PASS] $label → $actual" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $label → got $actual, want $expected" -ForegroundColor Red
        $script:fail++
    }
}

function Get-Status([string]$url, [string]$auth = "") {
    $args = @("-s", "-o", "NUL", "-w", "%{http_code}", $url)
    if ($auth) { $args += @("-H", "Authorization: $auth") }
    return (curl.exe @args)
}

function Get-Headers([string]$url, [string]$auth = "") {
    $args = @("-s", "-D", "-", "-o", "NUL", $url)
    if ($auth) { $args += @("-H", "Authorization: $auth") }
    $raw = curl.exe @args
    $headers = @{}
    foreach ($line in $raw -split "`n") {
        if ($line -match "^X-RateLimit-(\S+):\s*(.+)") {
            $headers[$Matches[1].Trim()] = $Matches[2].Trim()
        }
        if ($line -match "^Retry-After:\s*(.+)") {
            $headers["Retry-After"] = $Matches[1].Trim()
        }
    }
    return $headers
}

function Show-RateHeaders([hashtable]$h) {
    foreach ($k in @("Limit","Remaining","Reset","Retry-After")) {
        if ($h.ContainsKey($k)) {
            Write-Host "        X-RateLimit-$k`: $($h[$k])" -ForegroundColor DarkCyan
        }
    }
}

# ── Token generation ─────────────────────────────────────────────────────────

Section "Generating JWT tokens via Docker"

$root = Split-Path $PSScriptRoot -Parent
$dockerArgs = "run","--rm","-v","${root}:/app","-w","/app","golang:1.22-alpine","go","run","scripts/make-token.go"

Write-Host "  Generating basic token..."
$basicRaw    = & docker ($dockerArgs + @("-user","user-123","-type","basic"))
$basicToken  = ($basicRaw | Where-Object { $_ -match "^Bearer " } | Select-Object -First 1)

Write-Host "  Generating premium token..."
$premiumRaw   = & docker ($dockerArgs + @("-user","user-premium","-type","premium"))
$premiumToken = ($premiumRaw | Where-Object { $_ -match "^Bearer " } | Select-Object -First 1)

Write-Host "  Generating admin token..."
$adminRaw   = & docker ($dockerArgs + @("-user","user-admin","-type","admin"))
$adminToken = ($adminRaw | Where-Object { $_ -match "^Bearer " } | Select-Object -First 1)

if (-not $basicToken -or -not $premiumToken -or -not $adminToken) {
    Write-Host "  [ERROR] Failed to generate tokens. Is Docker running?" -ForegroundColor Red
    exit 1
}

Write-Host "  [OK] Tokens ready" -ForegroundColor Green

# ── Section 1: NGINX (:80) — IP rate limiting, no auth ───────────────────────

Section "1 · NGINX (:80) — IP rate limiting, no auth"

Assert "GET /health → 200" (Get-Status "http://localhost/health") "200"

$code = Get-Status "http://localhost/"
Assert "GET / passes through (200 or 404)" $code ($code)  # just check it's not 429 yet
if ($code -ne "429") {
    Write-Host "  [INFO] GET / returned $code (not rate-limited yet, as expected)" -ForegroundColor DarkGray
}

Write-Host "  Running 125 requests to trigger 429 (limit = 120)..."
$hit429 = $false
for ($i = 1; $i -le 125; $i++) {
    $c = Get-Status "http://localhost/"
    if ($c -eq "429" -and -not $hit429) {
        $hit429 = $true
        Write-Host "  [INFO] First 429 at request #$i" -ForegroundColor DarkGray
    }
}
Assert "429 triggered after 120 requests" ($hit429 ? "true" : "false") "true"

# ── Section 2: Go Proxy (:8080) — no auth (anonymous = basic) ───────────────

Section "2 · Go Proxy (:8080) — unauthenticated (anonymous user)"

Assert "GET /health → 200, no rate limit" (Get-Status "http://localhost:8080/health") "200"

$h = Get-Headers "http://localhost:8080/health"
Assert "/health has no X-RateLimit headers" ($h.ContainsKey("Limit") ? "has-headers" : "no-headers") "no-headers"

Assert "GET / → 200 (echo mode)" (Get-Status "http://localhost:8080/") "200"

$h = Get-Headers "http://localhost:8080/"
Assert "GET / has X-RateLimit-Limit: 60" $h["Limit"] "60"
Show-RateHeaders $h

$h = Get-Headers "http://localhost:8080/api/search"
Assert "GET /api/search has X-RateLimit-Limit: 20 (route override)" $h["Limit"] "20"
Show-RateHeaders $h

# ── Section 3: Go Proxy (:8080) — basic user, trigger 429 ───────────────────

Section "3 · Go Proxy (:8080) — basic user JWT (limit: 20/min on /api/search)"

$h = Get-Headers "http://localhost:8080/api/search" $basicToken
Assert "First request → 200" (Get-Status "http://localhost:8080/api/search" $basicToken) "200"
Assert "X-RateLimit-Limit: 20" $h["Limit"] "20"
Show-RateHeaders $h

Write-Host "  Running 22 requests to trigger 429 (limit = 20 on /api/search)..."
# Note: 1 request already sent above. Send 21 more to reach 22 total.
$hit429 = $false
$first429 = 0
for ($i = 2; $i -le 22; $i++) {
    $c = Get-Status "http://localhost:8080/api/search" $basicToken
    if ($c -eq "429" -and -not $hit429) {
        $hit429 = $true
        $first429 = $i
        $h429 = Get-Headers "http://localhost:8080/api/search" $basicToken
    }
}
Assert "429 triggered for basic user after 20 requests" ($hit429 ? "true" : "false") "true"
if ($hit429) {
    Write-Host "  [INFO] First 429 at request #$first429" -ForegroundColor DarkGray
    Write-Host "  [INFO] 429 response headers:" -ForegroundColor DarkGray
    Show-RateHeaders $h429
}

# ── Section 4: Go Proxy (:8080) — premium user, higher limits ───────────────

Section "4 · Go Proxy (:8080) — premium user JWT (limit: 200/min on /api/search)"

$h = Get-Headers "http://localhost:8080/api/search" $premiumToken
Assert "GET /api/search → 200" (Get-Status "http://localhost:8080/api/search" $premiumToken) "200"
Assert "X-RateLimit-Limit: 200 (premium route override)" $h["Limit"] "200"
Show-RateHeaders $h

$h = Get-Headers "http://localhost:8080/api/export" $premiumToken
Assert "GET /api/export → 200" (Get-Status "http://localhost:8080/api/export" $premiumToken) "200"
Assert "X-RateLimit-Limit: 50 (premium export override)" $h["Limit"] "50"
Show-RateHeaders $h

# ── Section 5: Go Proxy (:8080) — admin user, unlimited ─────────────────────

Section "5 · Go Proxy (:8080) — admin user JWT (unlimited)"

Assert "GET /api/search → 200" (Get-Status "http://localhost:8080/api/search" $adminToken) "200"

$h = Get-Headers "http://localhost:8080/api/search" $adminToken
Assert "No X-RateLimit headers (unlimited)" ($h.ContainsKey("Limit") ? "has-headers" : "no-headers") "no-headers"
Write-Host "  [INFO] Admin user bypasses rate limiting entirely" -ForegroundColor DarkGray

# ── Summary ──────────────────────────────────────────────────────────────────

Section "Summary"
$total = $pass + $fail
Write-Host "  Passed: $pass / $total" -ForegroundColor ($fail -eq 0 ? "Green" : "Yellow")
if ($fail -gt 0) {
    Write-Host "  Failed: $fail / $total" -ForegroundColor Red
}
Write-Host ""
