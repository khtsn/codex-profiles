# cxp - Codex profile switcher. Each profile is its own CODEX_HOME
# (separate login, sessions, history, config) under .\profiles\<name>.
# "home" is the stock ~/.codex. "default" (or no name) is an alias for
# whichever profile `cxp default <name>` picked; home until you pick one.
$ErrorActionPreference = 'Stop'
trap { [Console]::Error.WriteLine("cxp: $_"); exit 1 }   # one-line errors, no stack trace
$cmd = $args[0]; $name = $args[1]   # no param(): codex flags like -c must pass through untouched
$usePw = $false
if ($cmd -in 'backup', 'restore' -and @($args | Where-Object { $_ -in '--password', '-p' }).Count) {   # strip the flag so it can't be taken for a name (-p as in ccp)
    $usePw = $true
    $args = @($args | Where-Object { $_ -notin '--password', '-p' })
    $cmd = $args[0]; $name = $args[1]
}
$credsOnly = $false
if ($cmd -in 'backup', 'restore' -and $args -contains '--creds') {   # the login alone: no config, note or data
    $credsOnly = $true
    $args = @($args | Where-Object { $_ -ne '--creds' })
    $cmd = $args[0]; $name = $args[1]
}
$json = $false
$offline = $false
if ($cmd -in 'usage', 'pick' -and $args -contains '--offline') {
    $offline = $true
    $args = @($args | Where-Object { $_ -ne '--offline' })
    $cmd = $args[0]; $name = $args[1]
}
if ($cmd -in 'usage', 'list', 'pick' -and $args -contains '--json') {   # machine-readable output: JSON on stdout, nothing else
    $json = $true
    $args = @($args | Where-Object { $_ -ne '--json' })
    $cmd = $args[0]; $name = $args[1]
}
$rest = @($args | Select-Object -Skip 2)
$base = $PSScriptRoot
if ($env:CXP_ROOT) { $base = $env:CXP_ROOT }   # keep data elsewhere (also how the tests avoid real profiles)
$root = Join-Path $base 'profiles'
$bakRoot = Join-Path $base 'backups'
$defFile = Join-Path $root '.default'

# Names become folder names: . @ + only singly between word chars, so emails
# work but "..", leading dots (.default) and trailing dots (Windows strips them) don't.
$nameRe = '^[\w-]+([.@+][\w-]+)*$'

function DefaultName {
    if (Test-Path $defFile) { (Get-Content $defFile -TotalCount 1).Trim() } else { 'home' }
}

function Names {   # in `cxp list` order; a profile's number is its position here
    @('home') + @(if (Test-Path $root) { Get-ChildItem $root -Directory | Sort-Object Name | ForEach-Object Name })
}

function Resolve($n) {   # alias, list number, or plain name -> name
    if (-not $n -or $n -eq 'default') { return DefaultName }
    if ($n -match '^\d+$') {
        $all = @(Names)
        if ([int]$n -lt 1 -or [int]$n -gt $all.Count) { throw "No profile #$n (cxp list shows 1-$($all.Count))" }
        return $all[[int]$n - 1]
    }
    $n
}

function ProfileDir($n) {
    if ($n -eq 'home') { return $null }   # null = CODEX_HOME unset = ~/.codex
    if ($n -notmatch $nameRe) { throw "Bad profile name '$n' (letters, digits, - _ and single . @ + between them, e.g. me@example.com)" }
    $dir = Join-Path $root $n
    if (-not (Test-Path $dir)) { throw "No profile '$n'. Create it: cxp add $n" }
    $dir
}

function NewProfileDir($n) {   # path for a profile that must not exist yet
    if (-not $n) { throw 'Missing new profile name' }
    if ($n -in 'home', 'default') { throw "'$n' is reserved" }
    if ($n -match '^\d+$') { throw "A name can't be only digits; numbers are list positions" }
    if ($n -notmatch $nameRe) { throw "Bad profile name '$n' (letters, digits, - _ and single . @ + between them, e.g. me@example.com)" }
    $dir = Join-Path $root $n
    if (Test-Path $dir) { throw "Profile '$n' already exists" }
    $dir
}

function Retarget($old, $new) {   # repoint this terminal and the saved setting if they were on $old
    if ($env:CODEX_HOME -eq $old) { $env:CODEX_HOME = $new }
    if ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') -eq $old) {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $new, 'User')
    }
}

# Permission modes = the two top-level config.toml keys codex itself reads,
# so they apply to plain `codex` after `cxp use` as well as `cxp run`.
$modes = [ordered]@{
    bypass   = 'never', 'danger-full-access'        # no prompts, no sandbox
    auto     = 'on-request', 'workspace-write'      # sandboxed to the project, asks to go beyond
    readonly = 'on-request', 'read-only'            # asks before any write
}

function Mode($m) {   # accepts ccp's name for the read-only mode too -> a key of $modes
    if ($m -eq 'plan') { $m = 'readonly' }
    if (-not $m -or -not $modes.Contains("$m")) { throw "Unknown mode '$m'. Use: $($modes.Keys -join ', ') (plan = readonly)" }
    "$m"
}

function ConfigPath($n) {
    $d = ProfileDir $n
    if (-not $d) { $d = Join-Path $HOME '.codex' }
    Join-Path $d 'config.toml'
}

function IsPermLine($l) { $l -match '^\s*(approval_policy|sandbox_mode)\s*=' }

function GetPerm($cfg) {
    $v = @{}
    if (Test-Path $cfg) {
        foreach ($l in [IO.File]::ReadAllLines($cfg)) {
            if ($l -match '^\s*\[') { break }   # top-level keys end at the first table
            if ($l -match '^\s*(approval_policy|sandbox_mode)\s*=\s*["'']([^"'']*)') { $v[$Matches[1]] = $Matches[2] }
        }
    }
    if ($v.Count -eq 0) { return 'codex-default' }
    foreach ($m in $modes.Keys) {
        if ($modes[$m][0] -eq $v.approval_policy -and $modes[$m][1] -eq $v.sandbox_mode) { return $m }
    }
    "custom: approval_policy=$($v.approval_policy) sandbox_mode=$($v.sandbox_mode)"
}

function SetPerm($cfg, $mode) {
    $mode = Mode $mode
    $text = ''
    if (Test-Path $cfg) { $text = [IO.File]::ReadAllText($cfg) }
    $nl = "`n"
    if ($text.Contains("`r`n")) { $nl = "`r`n" }   # keep the file's own line endings
    $lines = @($text -split "`r?`n")
    $i = 0
    while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*\[') { $i++ }
    $head = @($lines | Select-Object -First $i | Where-Object { -not (IsPermLine $_) })
    $new = @("approval_policy = `"$($modes[$mode][0])`"", "sandbox_mode = `"$($modes[$mode][1])`"") +
        $head + @($lines | Select-Object -Skip $i)
    [IO.File]::WriteAllText($cfg, $new -join $nl)   # UTF-8 without BOM, same as codex writes
}

# A backup is the account, not the data: login + settings per profile.
# ponytail: sessions/history are not backed up (100MB+, sqlite locked while codex runs); zip the profile folder if that's ever needed.
$acctFiles = 'auth.json', 'config.toml', 'cxp-note.txt', 'cxp-pool-off'
# What `backup --creds` / `restore --creds` move: the login alone.
$credFiles = @('auth.json')
$files = $acctFiles
if ($credsOnly) { $files = $credFiles }

function HomeSkills($dir) {   # a new profile starts with home's own skills: copies, since links need admin rights here
    $src = Join-Path $HOME '.codex\skills'
    if (-not (Test-Path $src)) { return }
    foreach ($s in @(Get-ChildItem $src -Directory | Where-Object { $_.Name -notmatch '^\.' })) {   # not .system\, which codex fills in itself
        $dst = Join-Path $dir 'skills'
        New-Item -ItemType Directory -Force $dst | Out-Null
        Copy-Item -LiteralPath $s.FullName -Destination $dst -Recurse
    }
}

function ProfilePath($n) {   # like ProfileDir, but home is a real path and the folder may not exist
    if ($n -eq 'home') { return Join-Path $HOME '.codex' }
    if ($n -notmatch $nameRe) { throw "Bad profile name '$n'" }
    Join-Path $root $n
}

function GetNote($n) {
    $file = Join-Path (ProfilePath $n) 'cxp-note.txt'
    if (Test-Path -LiteralPath $file) { return [IO.File]::ReadAllText($file) }
    ''
}

# Pool = the profiles `cxp pick` may hand to automation. In by default; a marker file takes one out.
function PoolPath($n) {
    $d = ProfileDir $n
    if ($d) { Join-Path $d 'cxp-pool-off' } else { Join-Path $root '.home-pool-off' }
}

function InPool($n) { -not (Test-Path -LiteralPath (PoolPath $n)) }

function Opts { , @(@($name) + $rest | Where-Object { $_ }) }   # everything after the command, for commands whose flags go anywhere

function SaveAccounts($names, $stamp, $base = $bakRoot) {   # -> names actually saved ($files: all account files, or the login alone)
    foreach ($n in $names) {
        $found = @($files | ForEach-Object { Join-Path (ProfilePath $n) $_ } | Where-Object { Test-Path $_ })
        if ($found.Count) {
            $dst = Join-Path (Join-Path $base $stamp) $n
            New-Item -ItemType Directory -Force $dst | Out-Null
            Copy-Item $found $dst
            $n
        }
    }
}

# Encrypted backup = one <stamp>.enc file: "CXP1" | salt(16) | iv(16) | AES-256-CBC(zip) | HMAC-SHA256.
# Keys come from the password via PBKDF2-SHA256; encrypt-then-MAC, so a wrong password
# or a damaged file is rejected before anything is decrypted or written.
$encMagic = [Text.Encoding]::ASCII.GetBytes('CXP1')
$kdfRounds = 200000

function GetPassword($confirm) {
    if ($env:CXP_PASSWORD) { return $env:CXP_PASSWORD }   # for scripts; otherwise prompt, masked
    $p = [Net.NetworkCredential]::new('', (Read-Host 'Backup password' -AsSecureString)).Password
    if (-not $p) { throw 'Empty password' }
    if ($confirm -and $p -ne [Net.NetworkCredential]::new('', (Read-Host 'Repeat password' -AsSecureString)).Password) {
        throw "Passwords don't match"
    }
    $p
}

function DeriveKeys($pass, $salt) {   # -> 32-byte AES key, 32-byte HMAC key
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($pass, $salt, $kdfRounds, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $k = $kdf.GetBytes(64)
    $encKey = [byte[]]$k[0..31]
    $macKey = [byte[]]$k[32..63]
    , @($encKey, $macKey)   # the comma keeps the pipeline from flattening the byte arrays
}

function Pack($srcDir, $pass, $outFile) {   # folder -> encrypted file
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).zip"
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $zip)
        $plain = [IO.File]::ReadAllBytes($zip)
    } finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
    $rng = [Security.Cryptography.RNGCryptoServiceProvider]::new()
    $salt = [byte[]]::new(16); $rng.GetBytes($salt)
    $iv = [byte[]]::new(16); $rng.GetBytes($iv)
    $keys = DeriveKeys $pass $salt
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys[0]; $aes.IV = $iv
    $ct = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    $ms = [IO.MemoryStream]::new()
    foreach ($part in $encMagic, $salt, $iv, $ct) { $ms.Write($part, 0, $part.Length) }
    $body = $ms.ToArray()
    $mac = [Security.Cryptography.HMACSHA256]::new($keys[1]).ComputeHash($body)
    $ms.Write($mac, 0, $mac.Length)
    [IO.File]::WriteAllBytes($outFile, $ms.ToArray())
}

function Unpack($file, $pass) {   # encrypted file -> new temp folder (caller deletes it)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $data = [IO.File]::ReadAllBytes($file)
    if ($data.Length -lt 68 -or [Text.Encoding]::ASCII.GetString($data, 0, 4) -ne 'CXP1') { throw "Not a cxp backup: $file" }
    $n = $data.Length - 32
    $body = [byte[]]$data[0..($n - 1)]
    $mac = [byte[]]$data[$n..($data.Length - 1)]
    $salt = [byte[]]$data[4..19]; $iv = [byte[]]$data[20..35]
    $keys = DeriveKeys $pass $salt
    $calc = [Security.Cryptography.HMACSHA256]::new($keys[1]).ComputeHash($body)
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($calc[$i] -bxor $mac[$i]) }   # constant time
    if ($diff) { throw 'Wrong password, or the backup is damaged' }
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys[0]; $aes.IV = $iv
    $plain = $aes.CreateDecryptor().TransformFinalBlock($body, 36, $body.Length - 36)
    $dir = Join-Path ([IO.Path]::GetTempPath()) "cxp-$([guid]::NewGuid())"
    $zip = "$dir.zip"
    try {
        [IO.File]::WriteAllBytes($zip, $plain)
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    } finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
    $dir
}

function Stamp { Get-Date -Format 'yyyyMMdd-HHmmss' }

function Login($dir, $useKey) {   # browser login, or an API key fed to codex on stdin
    if (-not $useKey) { WithHome $dir { codex login }; return }
    if ([Console]::IsInputRedirected) { $key = [Console]::In.ReadLine() }   # echo $KEY | cxp add x --api-key
    else {
        $sec = Read-Host 'OpenAI API key' -AsSecureString   # masked, never in history or argv
        $key = [Net.NetworkCredential]::new('', $sec).Password
    }
    if (-not $key -or -not $key.Trim()) { throw 'No API key given' }
    WithHome $dir { $key.Trim() | codex login --with-api-key }
    if ($LASTEXITCODE) { throw 'API key login failed' }
}

# Token totals come from local session logs. Account limits are fetched through
# Codex's app server using the profile's own login, without starting a model turn.
# Lookups for several profiles run side by side: every server is started first (StartLimits),
# then each is read in turn (ReadLimits), so the slow part, server start-up, overlaps.
function RpcResult($process, $id, $deadline) {
    while ($true) {
        $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { throw 'lookup timed out' }
        $read = $process.StandardOutput.ReadLineAsync()
        if (-not $read.Wait($remaining)) { throw 'lookup timed out' }
        $line = $read.Result
        if ($null -eq $line) { throw 'Codex app server closed before replying' }
        try { $reply = $line | ConvertFrom-Json } catch { continue }
        if ($reply.id -ne $id) { continue }
        # Do not print server errors: upstream diagnostics may contain private details.
        if ($reply.error) { throw "Codex rejected the lookup (RPC $($reply.error.code)); check this profile's login" }
        return $reply.result
    }
}

function StartLimits($profileHome) {   # -> handle for ReadLimits; never throws, a failure is kept in .Error
    $h = @{ Process = $null; Error = $null; Done = $false; Deadline = [DateTime]::UtcNow.AddSeconds(20) }
    try {
        $launcher = Get-Command codex.exe, codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $launcher) { throw 'codex.exe or codex.cmd was not found on PATH' }
        $start = [Diagnostics.ProcessStartInfo]::new()
        if ([IO.Path]::GetExtension($launcher.Source) -eq '.cmd') {
            $start.FileName = $env:ComSpec
            $start.Arguments = '/d /s /c ""' + $launcher.Source + '" app-server --listen stdio://"'
        } else {
            $start.FileName = $launcher.Source
            $start.Arguments = 'app-server --listen stdio://'
        }
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['CODEX_HOME'] = $profileHome
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'could not start Codex app server' }
        $h.Process = $process
        $h.Stderr = $process.StandardError.ReadToEndAsync() # drain so diagnostics cannot block the child
        $process.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cxp","version":"1.0.0"}}}')
        # the follow-ups are queued right away, so every server is already fetching while the others are read
        $process.StandardInput.WriteLine('{"method":"initialized"}')
        $process.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read"}')
    } catch { $h.Error = $_.Exception.Message }
    $h
}

function StopLimits($h) {   # safe to call twice
    if ($h.Done) { return }
    $h.Done = $true
    $process = $h.Process
    if (-not $process) { return }
    # Kill the launcher and descendants, including npm's node and native Codex.
    try { if (-not $process.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F 2>$null | Out-Null } } catch { }
    $process.Dispose()
}

function ReadLimits($h) {
    try {
        if ($h.Error) { throw $h.Error }
        $process = $h.Process
        # 20 seconds from start; a server that waited behind a slow one still gets a few seconds to answer
        $deadline = $h.Deadline
        $floor = [DateTime]::UtcNow.AddSeconds(5)
        if ($deadline -lt $floor) { $deadline = $floor }
        $null = RpcResult $process 1 $deadline
        $result = RpcResult $process 2 $deadline
        $bucket = $result.rateLimits
        if ($result.rateLimitsByLimitId.codex) { $bucket = $result.rateLimitsByLimitId.codex }
        if (-not $bucket) { throw 'Codex returned no account limits' }
        return $bucket
    } finally { StopLimits $h }
}

function LoginOf($n) {   # auth_mode from the profile's auth.json: chatgpt, apikey, or nothing
    $auth = Join-Path (ProfilePath $n) 'auth.json'
    if (Test-Path $auth) { (Get-Content $auth -Raw | ConvertFrom-Json).auth_mode }
}

function UsageAll($names) {
    $handles = @{}
    try {
        if (-not $offline) {
            foreach ($n in $names) {
                $l = LoginOf $n
                if ($l -and $l -ne '-' -and $l -ne 'apikey') { $handles[$n] = StartLimits (ProfilePath $n) }
            }
        }
        foreach ($n in $names) { UsageOf $n $handles[$n] }
    } finally { foreach ($h in $handles.Values) { StopLimits $h } }
}

function Tok($n) {
    $c = [Globalization.CultureInfo]::InvariantCulture
    if ($n -ge 1e9) { return ($n / 1e9).ToString('0.0', $c) + 'B' }
    if ($n -ge 1e6) { return ($n / 1e6).ToString('0.0', $c) + 'M' }
    if ($n -ge 1e3) { return ($n / 1e3).ToString('0.0', $c) + 'k' }
    "$n"
}

function WindowName($min) {
    if ($min -ge 1440 -and $min % 1440 -eq 0) { return "$($min / 1440)d" }
    if ($min -ge 60 -and $min % 60 -eq 0) { return "$($min / 60)h" }
    "${min}m"
}

function LimitText($w) {   # one rate-limit window -> "2% of 7d, resets Nov 17 15:25"
    if (-not $w) { return $null }
    $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$w.resets_at).LocalDateTime
    if ($reset -lt (Get-Date)) { return "window $(WindowName $w.window_minutes) has reset since" }   # stale percent would mislead
    "$([math]::Round($w.used_percent))% of $(WindowName $w.window_minutes), resets $($reset.ToString('MMM d HH:mm'))"
}

function UsageOf($n, $handle) {   # $handle: a started live lookup (see UsageAll), or nothing for local data only
    $number = 1
    foreach ($listedName in Names) {
        if ($listedName -eq $n) { break }
        $number++
    }
    $home_ = ProfilePath $n
    $login = '-'; $plan = '-'
    $auth = Join-Path $home_ 'auth.json'
    if (Test-Path $auth) {
        $a = Get-Content $auth -Raw | ConvertFrom-Json
        $login = $a.auth_mode
    }
    $dayStart = (Get-Date).Date
    $weekStart = (Get-Date).AddDays(-7)
    $today = 0L; $week = 0L; $all = 0L; $sessions = 0
    $newest = [DateTimeOffset]::MinValue; $newestLine = $null
    $sessDir = Join-Path $home_ 'sessions'
    if (Test-Path $sessDir) {
        foreach ($f in Get-ChildItem $sessDir -Recurse -Filter 'rollout-*.jsonl' -File) {
            $last = $null
            # share-friendly open: codex may be writing this file right now
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            $sr = [IO.StreamReader]::new($fs)
            try { while ($null -ne ($l = $sr.ReadLine())) { if ($l.Contains('"type":"token_count"')) { $last = $l } } }
            finally { $sr.Dispose() }
            if (-not $last -or $last -notmatch '"timestamp":"([^"]+)"') { continue }
            $ts = [DateTimeOffset]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            $ev = $last | ConvertFrom-Json
            $tot = $ev.payload.info.total_token_usage.total_tokens
            if ($null -eq $tot) { continue }   # event without totals (e.g. limits only)
            $sessions++
            $all += $tot
            if ($ts.LocalDateTime -ge $weekStart) { $week += $tot }
            if ($ts.LocalDateTime -ge $dayStart) { $today += $tot }
            if ($ts -gt $newest -and $ev.payload.rate_limits) { $newest = $ts; $newestLine = $ev.payload.rate_limits }
        }
    }
    $source = 'unavailable'; $lookupError = $null
    if ($newestLine) {
        $source = 'local'
        if ($newestLine.plan_type) { $plan = $newestLine.plan_type }
    }
    if ($handle) {
        try {
            $live = ReadLimits $handle
            $newestLine = [pscustomobject]@{ plan_type = $live.planType; primary = $null; secondary = $null }
            foreach ($key in 'primary', 'secondary') {
                $w = $live.$key
                if ($w) {
                    $newestLine.$key = [pscustomobject]@{ window_minutes = $w.windowDurationMins
                        used_percent = $w.usedPercent; resets_at = $w.resetsAt }
                }
            }
            $newest = [DateTimeOffset]::UtcNow
            $source = 'live'
        } catch {
            $lookupError = $_.Exception.Message
            [Console]::Error.WriteLine("cxp: '$n': live limits unavailable ($lookupError); using local logs if available")
        }
    }
    $limits = @()
    if ($newestLine) {
        if ($newestLine.plan_type) { $plan = $newestLine.plan_type }
        foreach ($w in $newestLine.primary, $newestLine.secondary) {
            if ($w) {
                $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$w.resets_at)
                $limits += [pscustomobject]@{ window_minutes = [int]$w.window_minutes; used_percent = [double]$w.used_percent
                    resets_at = $reset.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'); reset_passed = ($reset -lt [DateTimeOffset]::Now)
                    text = LimitText $w }
            }
        }
    }
    if ($login -eq 'apikey') { $limits = @(); $source = 'not_applicable' }   # no ChatGPT rate-limit window
    $asOf = $null
    if ($newestLine) { $asOf = $newest.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    # headroom_percent / available (with path, pool) are shared with `ccp usage --json`,
    # so one script can rank both tools' profiles. The fullest open window decides the room left.
    $headroom = $null; $available = $false
    if ($login -eq 'apikey') { $available = $true }   # can run work; there is just no window to measure
    elseif ($login -and $login -ne '-' -and $source -ne 'unavailable') {
        $used = 0.0
        foreach ($w in $limits) { if (-not $w.reset_passed -and $w.used_percent -gt $used) { $used = $w.used_percent } }
        $headroom = [int][math]::Max(0, [math]::Floor(100 - $used))
        $available = $headroom -gt 0
    }
    [pscustomobject]@{ number = $number; profile = $n; note = GetNote $n
        login = $login; plan = $plan; limits = $limits; limits_as_of = $asOf
        limits_source = $source; limits_error = $lookupError
        tokens = [pscustomobject]@{ today = $today; last_7d = $week; all = $all }; sessions = $sessions
        path = $home_; pool = InPool $n; headroom_percent = $headroom; available = $available }
}

function UsageRow($u) {   # raw usage object -> one human-readable table row
    $limit = '-'
    if ($u.login -eq 'apikey') { $limit = 'n/a (API key)' }
    elseif ($u.limits.Count) { $limit = ($u.limits | ForEach-Object text) -join '; ' }
    if ($u.limits_source -eq 'local') { $limit = "[local, $($u.limits_as_of)] $limit" }
    elseif ($u.limits_error) { $limit = 'unavailable (live lookup failed)' }
    $free = '-'
    if ($null -ne $u.headroom_percent) { $free = "$($u.headroom_percent)%" }
    $pool = ''
    if (-not $u.pool) { $pool = 'off' }
    [pscustomobject]@{ '#' = $u.number; Profile = $u.profile; Note = $u.note; Login = $u.login; Plan = $u.plan; Limit = $limit
        Free = $free; Pool = $pool
        Today = Tok $u.tokens.today; Last7d = Tok $u.tokens.last_7d; All = Tok $u.tokens.all; Sessions = $u.sessions }
}

# --- Repair ----------------------------------------------------------------------------------
# Codex's SQLite databases record a checksum of every schema migration they ran, and the Windows
# build checksums the same migrations differently from the macOS / Linux one. So a profile folder
# copied between them won't open ("failed to initialize sqlite state runtime"). Repair takes the
# checksums from databases this codex has just made, and writes them only where the applied
# migrations and the resulting schema already match. cxp.bash does the same with the same rules.
# Only single quotes in the SQL: Windows PowerShell 5.1 mangles double quotes in native arguments.
function Sql($db, $query) {
    $out = & sqlite3 -cmd '.timeout 5000' $db $query 2>$null
    if ($LASTEXITCODE) { throw "sqlite3 failed on $db" }
    $out
}
function Schema($db) {   # its schema with line endings and spacing evened out
    ((Sql $db "select type, name, sql from sqlite_master where name not like 'sqlite_%' order by type, name") -join ' ') -replace '\s+', ' '
}
function Migrations($db) { try { Sql $db 'select group_concat(version) from (select version from _sqlx_migrations order by version)' } catch { $null } }
function Checksums($db) { try { (Sql $db "select version || ':' || hex(checksum) from _sqlx_migrations order by version") -join ',' } catch { $null } }

function RefDbs($ref) {   # fills the empty folder $ref with databases made by this codex
    New-Item -ItemType Directory -Path $ref | Out-Null
    $h = StartLimits $ref   # the app server creates its databases on start; the lookup itself just fails
    try { $null = ReadLimits $h } catch { }
    if (-not (Get-ChildItem -LiteralPath $ref -Filter '*.sqlite')) {
        if ($h.Error) { throw "Codex did not create its databases: $($h.Error)" }
        throw 'Codex did not create its databases'
    }
}

function Repair($dir, $n, $ref) {   # -> how many databases it fixed; says why it left any alone
    $fixed = 0
    foreach ($r in Get-ChildItem -LiteralPath $ref -Filter '*.sqlite') {
        $db = Join-Path $dir $r.Name
        if (-not (Test-Path -LiteralPath $db)) { continue }
        if ((Checksums $db) -eq (Checksums $r.FullName)) { continue }
        if ((Migrations $db) -ne (Migrations $r.FullName)) {
            Write-Host "Left '$n' $($r.Name) alone: made by a different Codex version (update Codex on both machines, then repair again)"
            continue
        }
        if ((Schema $db) -ne (Schema $r.FullName)) { Write-Host "Left '$n' $($r.Name) alone: its tables differ from this Codex's"; continue }
        $set = (Sql $r.FullName "select 'update _sqlx_migrations set checksum = x''' || hex(checksum) || ''' where version = ' || version || ';' from _sqlx_migrations") -join ' '
        try { $null = Sql $db "begin; $set commit;" } catch { throw "Could not update '$n' $($r.Name) (close Codex and try again)" }
        $fixed++
    }
    $fixed
}

function WithHome($dir, [scriptblock]$body) {
    $old = $env:CODEX_HOME
    $env:CODEX_HOME = $dir
    try { & $body } finally { $env:CODEX_HOME = $old }
}

switch ($cmd) {
    'list' {
        $def = DefaultName
        $i = 0
        $rows = @()
        foreach ($n in Names) {
            $i++
            $mark = ' '
            if ((ProfileDir $n) -eq $env:CODEX_HOME) { $mark = '*' }
            $tag = ''
            if ($n -eq $def) { $tag = ' (default)' }
            if ($json) {
                $rows += [pscustomobject]@{ number = $i; name = $n; active = ($mark -eq '*'); default = ($n -eq $def)
                    path = ProfilePath $n; permissions = GetPerm (ConfigPath $n); note = GetNote $n; pool = InPool $n }
            } else {
                $note = GetNote $n
                $suffix = if ($note) { " - $note" } else { '' }
                if (-not (InPool $n)) { $suffix = " [pool off]$suffix" }
                "$mark $i $n$tag [$(GetPerm (ConfigPath $n))]$suffix"
            }
        }
        if ($json) { ConvertTo-Json -InputObject @($rows) -Depth 3 }
    }
    'add' {
        $dir = NewProfileDir $name
        New-Item -ItemType Directory $dir | Out-Null
        $cfg = Join-Path $HOME '.codex\config.toml'
        if (Test-Path $cfg) { Copy-Item $cfg $dir }   # start from your current settings
        SetPerm (Join-Path $dir 'config.toml') 'auto'   # safe default; `cxp perm <name> bypass` opts out of prompts and sandbox
        HomeSkills $dir
        Login $dir ([bool]@($rest | Where-Object { $_ -in '--api-key', '--key' }).Count)   # --key as in ccp
        "Created '$name'. Switch to it: cxp use $name"
    }
    'use' {   # cxp use [name] [--local]
        $o = Opts
        $name = Resolve (@($o -ne '--local')[0])
        $dir = ProfileDir $name
        $env:CODEX_HOME = $dir                                          # this terminal
        if ($o -contains '--local') { "Now using '$name' (this terminal only)" }
        else {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $dir, 'User') # new terminals / apps
            "Now using '$name'"
        }
    }
    'path' {   # the profile's CODEX_HOME folder. --env: the value CODEX_HOME needs (nothing for home); cxp.sh uses it
        $o = Opts
        $name = Resolve (@($o | Where-Object { $_ -notin '--env', '--local' })[0])
        if ($o -contains '--env') { ProfileDir $name } else { ProfileDir $name | Out-Null; ProfilePath $name }
    }
    'run' {   # cxp run <name> [--perm <mode>] [codex args]
        $name = Resolve $name
        if ($rest[0] -eq '--perm') {   # only as the first argument, so codex's own flags stay untouched
            $m = $modes[(Mode $rest[1])]
            $rest = @('-c', "approval_policy=$($m[0])", '-c', "sandbox_mode=$($m[1])") + @($rest | Select-Object -Skip 2)
        }
        WithHome (ProfileDir $name) { codex @rest }
        exit $LASTEXITCODE   # scripts need codex's own exit code
    }
    'pool' {   # cxp pool <name> [on|off]
        $name = Resolve $name
        $f = PoolPath $name
        switch ("$($rest[0])") {
            ''    { }
            'on'  { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f } }
            'off' { New-Item -ItemType Directory -Force $root | Out-Null; [IO.File]::WriteAllText($f, '') }
            default { throw 'Use: cxp pool <name> [on|off]' }
        }
        if (InPool $name) { "'$name' is in the pool" } else { "'$name' is out of the pool (cxp pick skips it)" }
    }
    'pick' {   # cxp pick [-n <count>] [--json] [--offline]: pool profiles with room left, most headroom first
        $o = Opts
        $count = 1
        $i = [array]::IndexOf([object[]]$o, '-n')
        if ($i -ge 0) {
            if ("$($o[$i + 1])" -notmatch '^[1-9]\d*$') { throw '-n needs a number, e.g. cxp pick -n 3' }
            $count = [int]$o[$i + 1]
        }
        # out-of-pool profiles are skipped before any lookup
        $rows = @(UsageAll @(Names | Where-Object { InPool $_ })) | Where-Object { $_.available }
        $rows = @($rows | Sort-Object @{ Expression = { if ($null -eq $_.headroom_percent) { -1 } else { $_.headroom_percent } }; Descending = $true },
            @{ Expression = { $_.number } } | Select-Object -First $count)   # API-key profiles (no known headroom) go last
        if (-not $rows.Count) { throw 'No profile available: all are out of the pool, at their limit, or not logged in (see: cxp usage)' }
        if ($json) {
            $rows | ForEach-Object { $_.limits = @($_.limits | Select-Object window_minutes, used_percent, resets_at, reset_passed) }
            ConvertTo-Json -InputObject $rows -Depth 5
        } else { $rows.profile }
    }
    'default' {
        if ($name) {
            $name = Resolve $name
            ProfileDir $name | Out-Null   # must exist
            New-Item -ItemType Directory -Force $root | Out-Null
            Set-Content $defFile $name
            "Default is now '$name'"
        } else { "Default is '$(DefaultName)'" }
    }
    'rename' {
        $name = Resolve $name
        $old = ProfileDir $name
        if (-not $old) { throw "'home' is ~/.codex and can't be renamed" }
        $new = NewProfileDir $rest[0]
        Rename-Item $old $new
        if ((DefaultName) -eq $name) { Set-Content $defFile $rest[0] }
        Retarget $old $new
        "Renamed '$name' to '$($rest[0])'"
    }
    'remove' {
        $name = Resolve $name
        $dir = ProfileDir $name
        if (-not $dir) { throw "'home' is ~/.codex and can't be removed" }
        if ($rest -notcontains '-y') {
            $ans = Read-Host "Delete '$name' and ALL its data (login, sessions, history)? Type the name to confirm"
            if ($ans -ne $name) { throw 'Cancelled, nothing deleted' }
        }
        Remove-Item -Recurse -Force $dir
        if ((DefaultName) -eq $name) { Remove-Item $defFile }   # default falls back to home
        Retarget $dir $null                                      # if it was active, back to home
        "Removed '$name'"
    }
    'perm' {
        $name = Resolve $name
        $cfg = ConfigPath $name
        if ($rest.Count) { SetPerm $cfg $rest[0] }
        "'$name' permissions: $(GetPerm $cfg)"
    }
    'note' {
        if (-not $name) { throw 'Use: cxp note <name> [text | --clear]' }
        $name = Resolve $name
        ProfileDir $name | Out-Null
        $file = Join-Path (ProfilePath $name) 'cxp-note.txt'
        if ($rest.Count -eq 1 -and $rest[0] -eq '--clear') {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
            "Cleared note for '$name'"
        } elseif ($rest.Count) {
            $note = $rest -join ' '
            if ($note -match '[\r\n]') { throw 'Use a single line for a quick note' }
            $null = New-Item -ItemType Directory -Force (ProfilePath $name)
            [IO.File]::WriteAllText($file, $note)
            "Note for '$name': $note"
        } else { GetNote $name }
    }
    'usage' {
        $names = @(Names)
        if ($name) { $name = Resolve $name; ProfileDir $name | Out-Null; $names = @($name) }
        $all = @(UsageAll $names)
        if ($json) {
            # limits[].text is display-only; drop it so the schema is just data
            $out = $all | ForEach-Object { $_.limits = @($_.limits | Select-Object window_minutes, used_percent, resets_at, reset_passed); $_ }
            ConvertTo-Json -InputObject @($out) -Depth 5
            return
        }
        $all | ForEach-Object { UsageRow $_ } |
            Format-Table '#', Profile, Login, Plan, Limit, Free, Pool, Today, Last7d, All, Sessions, Note -AutoSize -Wrap | Out-String -Width 260
        'Tokens are local session totals (cached input included), counted at each session''s last activity. Limits are live unless marked local. Use --offline to skip live lookups.'
    }
    'install' {   # idempotent: safe to run again
        # PowerShell: this folder on the user PATH. Raw registry read so %VARS% in PATH are not flattened.
        $userPath = (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        if (($userPath -split ';') -contains $PSScriptRoot) { "PowerShell: already on PATH" }
        else {
            [Environment]::SetEnvironmentVariable('PATH', ($userPath.TrimEnd(';') + ';' + $PSScriptRoot).TrimStart(';'), 'User')
            $env:PATH += ";$PSScriptRoot"
            "PowerShell: added $PSScriptRoot to PATH"
        }
        # Git Bash: source cxp.sh from ~/.bashrc (cxp must be a shell function there, so `use` can set CODEX_HOME).
        # ponytail: drive-letter paths only (F:\x -> /f/x); UNC installs need the line added by hand
        $sh = '/' + $PSScriptRoot.Substring(0, 1).ToLower() + $PSScriptRoot.Substring(2).Replace('\', '/') + '/cxp.sh'
        # Git Bash windows are login shells: they read the first of these that exists and never
        # .bashrc unless that file sources it. So: .bashrc (plain shells) + the login file if any.
        # With no login file, Git Bash creates a .bash_profile that sources .bashrc by itself.
        $login = '.bash_profile', '.bash_login', '.profile' | Where-Object { Test-Path (Join-Path $HOME $_) } | Select-Object -First 1
        $files = @('.bashrc') + @($login | Where-Object { $_ })
        if (-not ($login -or (Test-Path (Join-Path $HOME '.bashrc')) -or (Get-Command bash -ErrorAction SilentlyContinue))) {
            "Git Bash: not found, skipped"
        } else {
            foreach ($f in $files) {
                $rc = Join-Path $HOME $f
                if ((Test-Path $rc) -and [IO.File]::ReadAllText($rc).Contains($sh)) { "Git Bash: already in ~/$f" }
                else {
                    [IO.File]::AppendAllText($rc, "`nsource `"$sh`"`n")   # LF endings; CRLF would break bash
                    "Git Bash: added to ~/$f"
                }
            }
        }
        "Open a new terminal, then run: cxp list"
    }
    'backup' {
        $names = @(Names)
        if ($name) { $name = Resolve $name; ProfileDir $name | Out-Null; $names = @($name) }
        $stamp = Stamp
        $what = 'login + config'
        if ($credsOnly) { $stamp += '-creds'; $what = 'login only' }
        if (-not $usePw) {
            $saved = @(SaveAccounts $names $stamp)
            if (-not $saved.Count) { throw 'Nothing to back up (no login or config found)' }
            "Backed up $($saved -join ', ') ($what) to $(Join-Path $bakRoot $stamp)"
        } else {
            $pass = GetPassword $true
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cxp-$([guid]::NewGuid())"
            try {
                $saved = @(SaveAccounts $names $stamp $tmp)
                if (-not $saved.Count) { throw 'Nothing to back up (no login or config found)' }
                New-Item -ItemType Directory -Force $bakRoot | Out-Null
                $out = Join-Path $bakRoot "$stamp.enc"
                Pack (Join-Path $tmp $stamp) $pass $out
            } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
            "Backed up $($saved -join ', ') ($what) to $out (encrypted)"
        }
    }
    'backups' {
        if (Test-Path $bakRoot) {
            $items = @(Get-ChildItem $bakRoot | Where-Object { $_.PSIsContainer -or $_.Extension -eq '.enc' } | Sort-Object BaseName)
            foreach ($i in $items) {
                if ($i.PSIsContainer) { "$($i.Name)  $((Get-ChildItem $i.FullName -Directory | ForEach-Object Name) -join ', ')" }
                else { "$($i.BaseName)  (encrypted)" }
            }
        }
    }
    'repair' {   # cxp repair [name]: databases from a profile folder copied from macOS / Linux (or to it) open again
        if (@($args | Where-Object { $_ -in '--paths', '--from', '--apply' }).Count) {
            & (Join-Path $PSScriptRoot 'repair.ps1') -Tool cxp -Root $base -RepairArguments @($args | Select-Object -Skip 1)
            break
        }
        if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) { throw 'sqlite3 is required (winget install SQLite.SQLite)' }
        if ($name) { $name = Resolve $name; ProfileDir $name | Out-Null; $names = @($name) } else { $names = Names }
        $ref = Join-Path ([IO.Path]::GetTempPath()) "cxp-ref-$([guid]::NewGuid().ToString('N'))"
        try {
            RefDbs $ref
            foreach ($n in $names) {
                $dir = ProfilePath $n
                if (-not (Test-Path -LiteralPath $dir)) { continue }
                $fixed = Repair $dir $n $ref
                if ($fixed) { "Repaired $fixed database(s) in '$n'" } else { "'$n': nothing to repair" }
            }
        } finally { Remove-Item -LiteralPath $ref -Recurse -Force -ErrorAction SilentlyContinue }
    }
    'restore' {
        $stamp = $rest[0]
        # a lone backup id works too: `cxp restore 20261110-165355`
        if ($name -and -not $stamp -and $name -match '^\d{8}-\d{6}' -and -not (Test-Path (Join-Path $root $name)) -and
            ((Test-Path (Join-Path $bakRoot $name)) -or (Test-Path (Join-Path $bakRoot "$name.enc")))) { $stamp = $name; $name = $null }
        if ($name) { $name = Resolve $name }   # no name = every profile in the backup
        $tmp = $null   # decrypted copy of an encrypted backup, always deleted at the end
        try {
            $src = $null
            if ($stamp) {
                if ($stamp -notmatch '^[\w-]+$') { throw "No backup '$stamp' (see: cxp backups)" }
                $encFile = Join-Path $bakRoot "$stamp.enc"
                if (Test-Path $encFile) { $tmp = Unpack $encFile (GetPassword $false); $src = $tmp }   # an encrypted id is recognised by itself
                elseif (Test-Path (Join-Path $bakRoot $stamp)) { $src = Join-Path $bakRoot $stamp }
                else { throw "No backup '$stamp' (see: cxp backups)" }
            } elseif ($usePw) {
                $encs = @()
                if (Test-Path $bakRoot) { $encs = @(Get-ChildItem $bakRoot -Filter *.enc | Sort-Object BaseName -Descending) }
                if (-not $encs.Count) { throw 'No encrypted backup to restore from. Make one: cxp backup --password' }
                $pass = GetPassword $false
                foreach ($f in $encs) {   # newest that has what we need
                    $d = Unpack $f.FullName $pass
                    if (-not $name -or (Test-Path (Join-Path $d $name))) { $tmp = $d; $stamp = $f.BaseName; $src = $d; break }
                    Remove-Item $d -Recurse -Force
                }
                if (-not $src) { throw "No encrypted backup has '$name' (see: cxp backups)" }
            } else {
                # newest plain backup that has what we need; automatic pre-restore snapshots only by explicit id
                if (Test-Path $bakRoot) {
                    $stamp = Get-ChildItem $bakRoot -Directory | Sort-Object Name -Descending | ForEach-Object Name |
                        Where-Object { $_ -notlike '*-before-restore' -and (-not $name -or (Test-Path (Join-Path (Join-Path $bakRoot $_) $name))) } |
                        Select-Object -First 1
                }
                if (-not $stamp) { throw 'No backup to restore from. Make one: cxp backup' }
                $src = Join-Path $bakRoot $stamp
            }
            $names = @(Get-ChildItem $src -Directory | ForEach-Object Name)
            if ($name) {
                if ($names -notcontains $name) { throw "Backup $stamp has no '$name' (see: cxp backups)" }
                $names = @($name)
            }
            $pre = "$(Stamp)-before-restore"
            $kept = @(SaveAccounts $names $pre)   # what is about to be overwritten (plain, like the live files)
            $restored = @(foreach ($n in $names) {
                $found = @($files | ForEach-Object { Join-Path (Join-Path $src $n) $_ } | Where-Object { Test-Path $_ })
                if (-not $found.Count) { [Console]::Error.WriteLine("cxp: skipped '$n': nothing to restore in this backup"); continue }
                $dst = ProfilePath $n
                New-Item -ItemType Directory -Force $dst | Out-Null   # brings back a removed profile
                Copy-Item $found $dst -Force
                $n
            })
            if (-not $restored.Count) { throw 'Nothing restored' }
        } finally { if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
        $what = ''
        if ($credsOnly) { $what = 'login for ' }
        "Restored $what$($restored -join ', ') from backup $stamp"
        if ($kept.Count) { "Previous login/config kept as backup $pre" }
    }
    default {
        @'
cxp install            one-time setup: `cxp` in every new PowerShell and Git Bash terminal
cxp repair --paths [--from <old-folder>] [--apply]
                       preview relocation repairs; --apply writes with backups (Python 3.11+)
cxp list [--json]      show profiles (* = active in this terminal)
cxp add <name> [--api-key]
                       create a profile and log in to it (browser, or an OpenAI
                       API key: prompted masked, or piped in on stdin)
                       (--key works too)
cxp use [name] [--local]
                       switch (this terminal + all new ones); no name = default;
                       --local switches this terminal only
cxp run <name> [--perm <mode>] [args]
                       run codex once under a profile without switching;
                       --perm overrides the permission mode for this run only
cxp path <name>        print the profile's CODEX_HOME folder
cxp default [name]     show / pick the default profile
cxp note <name> [text | --clear]
                       show / set / clear a quick account note (also shown in list and usage)
cxp perm <name> [mode] show / set permissions: bypass (no prompts, no sandbox),
                       auto (sandboxed to project), readonly (also accepted as plan).
                       New profiles get auto.
cxp usage [name] [--json] [--offline]
                       local tokens (today / 7 days / all time) and live account limits;
                       --offline reads only local session logs
cxp pool <name> [on|off]
                       show / set whether `cxp pick` may choose this profile
cxp pick [-n <count>] [--json] [--offline]
                       print the pool profile(s) with the most room left
cxp rename <old> <new> rename a profile
cxp remove <name> [-y] delete a profile and all its data (-y skips the prompt)
cxp backup [name] [--password] [--creds]
                       save login + config + note (not sessions) of one / all profiles;
                       --password (or -p) encrypts it (AES-256, asks for a password);
                       --creds saves only the login (auth.json), nothing else
cxp backups            list backups
cxp restore [name] [id] [--password] [--creds]
                       restore one / all profiles from the newest backup, or backup <id>;
                       --password picks the newest encrypted one (an encrypted <id> asks
                       for the password on its own); recreates removed profiles, keeps
                       what it overwrites as a backup; --creds restores only the login
cxp repair [name]      after copying profile folders between Windows and macOS / Linux:
                       makes their Codex databases open here (one / all profiles)
"home" is your original ~/.codex. Anywhere a name goes you can also give
"default" or the number from `cxp list` (cxp use 2).
'@
    }
}
