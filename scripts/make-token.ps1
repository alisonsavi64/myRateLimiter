param(
    [string]$User   = "user-123",
    [string]$Type   = "basic",
    [string]$Secret = "mysecret",
    [long]$Exp      = 9999999999
)

function ConvertTo-Base64Url([byte[]]$data) {
    [Convert]::ToBase64String($data) -replace '=+$','' -replace '\+','-' -replace '/','_'
}

$headerJson  = '{"alg":"HS256","typ":"JWT"}'
$payloadJson = "{`"sub`":`"$User`",`"user_type`":`"$Type`",`"exp`":$Exp}"

$headerB64  = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($headerJson))
$payloadB64 = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
$input      = "$headerB64.$payloadB64"

$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
$sig = ConvertTo-Base64Url ($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($input)))

$token = "$input.$sig"

Write-Host ""
Write-Host "Bearer $token" -ForegroundColor Green
Write-Host ""
Write-Host "curl.exe http://localhost:8080/api/search -H `"Authorization: Bearer $token`""
