# Integration checks with an isolated profile and a fake Codex app server.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'cxp.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('cxp-usage-' + [guid]::NewGuid())
$savedPath = $env:PATH; $savedRoot = $env:CXP_ROOT; $savedMode = $env:CXP_TEST_MODE
$savedHome = $env:CODEX_HOME; $savedPw = $env:CXP_PASSWORD
$savedUser = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Assert($ok, $message) { if (-not $ok) { throw $message } }
function ExitCode($arguments, $stdin) {   # a real child process, the way scripts call cxp; errors go to a file
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") + $arguments
    $extra = @{}
    if ($stdin) { $extra.RedirectStandardInput = $stdin }
    $p = Start-Process $ps -ArgumentList $list -Wait -PassThru -NoNewWindow @extra `
        -RedirectStandardOutput (Join-Path $fixture 'out') -RedirectStandardError (Join-Path $fixture 'err')
    $p.ExitCode
}
try {
    $profile = Join-Path $fixture 'profiles\test'
    $null = New-Item -ItemType Directory -Path (Join-Path $profile 'sessions') -Force
    Set-Content -LiteralPath (Join-Path $profile 'auth.json') -Value '{"auth_mode":"chatgpt"}'
    $event = @{ timestamp = [DateTimeOffset]::UtcNow.ToString('o'); type = 'event_msg'; payload = @{
        type = 'token_count'; info = @{ total_token_usage = @{ total_tokens = 123 } }
        rate_limits = @{ plan_type = 'pro'; primary = @{ used_percent = 40; window_minutes = 300; resets_at = 2000000000 } }
    } } | ConvertTo-Json -Depth 8 -Compress
    Set-Content -LiteralPath (Join-Path $profile 'sessions\rollout-test.jsonl') -Value $event
    # fake codex: the app server below; `login` succeeds; anything else records its profile and arguments, then fails with 7
    Set-Content -LiteralPath (Join-Path $fixture 'codex.cmd') -Value '@echo off
if "%~1"=="app-server" goto server
if "%~1"=="login" exit /b 0
>"%~dp0ran" echo [%CODEX_HOME%] %*
exit /b 7
:server
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"'
    Set-Content -LiteralPath (Join-Path $fixture 'server.ps1') -Value @'
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'launches') -Value $env:CODEX_HOME
$stdin = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false), $false)   # keep a BOM visible
while ($null -ne ($line = $stdin.ReadLine())) {
    if ($line.Length -and $line[0] -eq [char]0xFEFF) { continue }   # like real codex: a BOM-prefixed line is not valid JSON-RPC
    $request = $line | ConvertFrom-Json
    if ($request.method -eq 'initialize') {
        [Console]::WriteLine('{"id":1,"result":{}}')
    } elseif ($request.method -eq 'account/rateLimits/read') {
        if ($env:CXP_TEST_MODE -eq 'timeout') { Start-Sleep -Seconds 60; exit }
        if ($env:CXP_TEST_MODE -eq 'exit') { exit }
        if ($env:CXP_TEST_MODE -eq 'failure') {
            [Console]::WriteLine('{"id":2,"error":{"code":-32000,"message":"SECRET_MUST_NOT_PRINT"}}')
        } else {
            [Console]::WriteLine('{"method":"account/updated","params":{}}')
            [Console]::WriteLine('{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":2000000000}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":2000000000}}}}}')
        }
    }
}
'@
    $env:PATH = $fixture # only the mock Codex; system executables use absolute paths
    $env:CXP_ROOT = $fixture
    $env:CXP_TEST_MODE = 'success'
    & $scriptPath note 2 'Renew next month - team account' | Out-Null
    Assert ((& $scriptPath note test) -eq 'Renew next month - team account') 'Note did not round-trip by profile number/name'
    $listed = (& $scriptPath list --json | Out-String) | ConvertFrom-Json
    Assert ($listed[1].note -eq 'Renew next month - team account') 'List JSON omitted note'
    $live = (& $scriptPath usage test --json | Out-String) | ConvertFrom-Json
    Assert ($live[0].number -eq $listed[1].number -and $live[0].number -eq 2) 'Filtered usage number differs from list'
    Assert ($live[0].note -eq $listed[1].note) 'Usage JSON omitted note'
    Assert ($live.Count -eq 1 -and $live[0].limits_source -eq 'live') 'Live lookup did not succeed'
    Assert ($live[0].limits.Count -eq 2 -and $live[0].limits[0].used_percent -eq 17) 'Live windows / canonical bucket were not used'
    Assert ($live[0].tokens.all -eq 123) 'Local token totals changed'
    Assert ($live[0].headroom_percent -eq 37 -and $live[0].available -eq $true) 'Headroom should come from the fullest window'
    Assert ($live[0].path -eq $profile -and $live[0].pool -eq $true) 'Usage JSON shared fields wrong'
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'launches')) -eq $profile) 'Wrong profile home passed to server'
    Assert ($env:CODEX_HOME -eq $savedHome) 'Parent profile changed'
    $savedEnc = [Console]::InputEncoding   # a UTF-8-with-BOM console must not put a BOM on the server's stdin
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($true)
        $bom = (& $scriptPath usage test --json | Out-String) | ConvertFrom-Json
        Assert ($bom[0].limits_source -eq 'live') 'Live lookup failed with a UTF-8-with-BOM console'
        Assert ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'usage did not restore the console input encoding'
    } finally { [Console]::InputEncoding = $savedEnc }
    $local = (& $scriptPath usage --offline test --json | Out-String) | ConvertFrom-Json
    Assert ($local[0].limits_source -eq 'local' -and $local[0].limits[0].used_percent -eq 40) 'Offline limits incorrect'
    Assert ($local[0].headroom_percent -eq 60) 'Offline headroom incorrect'
    $table = & $scriptPath usage test --offline | Out-String
    Assert ($table -match '#\s+Profile' -and $table -match '2\s+test' -and $table.Contains('Renew next month')) 'Usage table omitted index or note'
    $upper = (& $scriptPath usage TEST --offline --json | Out-String) | ConvertFrom-Json
    Assert ($upper[0].number -eq 2) 'Case-insensitive profile lookup changed the usage index'
    Assert (@(Get-Content -LiteralPath (Join-Path $fixture 'launches')).Count -eq 2) 'Offline mode started a server'
    foreach ($mode in 'failure', 'exit', 'timeout') {
        $env:CXP_TEST_MODE = $mode
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $output = & $scriptPath usage test --json 2> (Join-Path $fixture 'errors') | Out-String
        $fallback = $output | ConvertFrom-Json
        Assert ($fallback[0].limits_source -eq 'local' -and $fallback[0].limits_error) "Missing fallback for $mode"
        Assert ($fallback[0].limits[0].used_percent -eq 40) "Lost local limits for $mode"
        Assert (('' + (Get-Content -LiteralPath (Join-Path $fixture 'errors') -Raw)) -notmatch 'SECRET_MUST_NOT_PRINT') 'Server error leaked'
        Assert ($watch.Elapsed.TotalSeconds -lt 30) "Lookup did not stop promptly for $mode"
    }
    $launchCount = @(Get-Content -LiteralPath (Join-Path $fixture 'launches')).Count
    Set-Content -LiteralPath (Join-Path $profile 'auth.json') -Value '{"auth_mode":"apikey"}'
    $api = (& $scriptPath usage test --json | Out-String) | ConvertFrom-Json
    Assert ($api[0].limits.Count -eq 0 -and $api[0].limits_source -eq 'not_applicable') 'API-key profile limits incorrect'
    Assert (@(Get-Content -LiteralPath (Join-Path $fixture 'launches')).Count -eq $launchCount) 'API-key profile started a server'
    Assert ($api[0].available -eq $true -and $null -eq $api[0].headroom_percent) 'API-key profile should be available with unknown headroom'
    & $scriptPath backup test | Out-Null
    & $scriptPath note test --clear | Out-Null
    Assert ((& $scriptPath note test | Out-String).Trim() -eq '') 'Note was not cleared'
    & $scriptPath restore test | Out-Null
    Assert ((& $scriptPath note test) -eq 'Renew next month - team account') 'Backup did not preserve note'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'profiles\other')
    Assert ((& $scriptPath note other | Out-String).Trim() -eq '') 'Note leaked to another account'
    $numbered = (& $scriptPath usage --offline --json | Out-String) | ConvertFrom-Json
    Assert (($numbered.number -join ',') -eq '1,2,3' -and $numbered[2].profile -eq 'test') 'All-profile usage ordering differs from list'
    Assert ($numbered[1].available -eq $false) 'A profile without a login should not be available'

    # pool + pick. home leaves the pool first, so nothing below depends on the real ~/.codex.
    & $scriptPath pool home off | Out-Null
    Assert (Test-Path (Join-Path $fixture 'profiles\.home-pool-off')) 'Home pool marker is not under CXP_ROOT'
    $listed = (& $scriptPath list --json | Out-String) | ConvertFrom-Json
    Assert ($listed[0].pool -eq $false -and $listed[2].pool -eq $true) 'List JSON pool wrong'
    Assert (((& $scriptPath pick -n 5 --offline) -join ',') -eq 'test') 'pick should return only available pool profiles'
    $picked = (& $scriptPath pick --json --offline | Out-String) | ConvertFrom-Json
    Assert ($picked.Count -eq 1 -and $picked[0].profile -eq 'test' -and $picked[0].available) 'pick --json wrong'
    & $scriptPath pool test off | Out-Null
    Assert ((& $scriptPath list | Out-String) -match 'test \[[^\]]+\] \[pool off\]') 'list does not show pool off'
    Assert ((ExitCode @('pick', '--offline')) -eq 1) 'pick with an empty pool should fail'
    $env:CXP_PASSWORD = 'test-password'
    & $scriptPath backup test -p | Out-Null
    Assert (@(Get-ChildItem (Join-Path $fixture 'backups') -Filter '*.enc').Count -eq 1) 'backup -p did not write an encrypted backup'
    & $scriptPath pool test on | Out-Null
    & $scriptPath restore test -p | Out-Null
    Assert (((& $scriptPath list --json | Out-String) | ConvertFrom-Json)[2].pool -eq $false) 'Backup did not preserve pool off'
    & $scriptPath pool test on | Out-Null

    # run: profile isolation, exit code, --perm
    & $scriptPath run test exec hi
    Assert ($LASTEXITCODE -eq 7) 'run did not pass on the exit code'
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'ran')).Trim() -eq "[$profile] exec hi") 'run changed the arguments or the profile'
    Assert ($env:CODEX_HOME -eq $savedHome) 'run changed this terminal'
    & $scriptPath run test --perm plan exec hi
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'ran')).Trim() -eq "[$profile] -c approval_policy=on-request -c sandbox_mode=read-only exec hi") 'run --perm wrong'
    Remove-Item -LiteralPath (Join-Path $fixture 'ran')
    Assert ((ExitCode @('run', 'test', '--perm', 'nonsense', 'exec', 'hi')) -eq 1 -and -not (Test-Path (Join-Path $fixture 'ran'))) 'run with a bad --perm should fail before starting codex'
    Assert ((ExitCode @('run', 'test', 'exec', 'hi')) -eq 7) 'run exit code lost when called as a process'

    # use --local: this process only, saved setting untouched
    & $scriptPath use test --local | Out-Null
    Assert ($env:CODEX_HOME -eq $profile) 'use --local did not switch this terminal'
    $env:CODEX_HOME = $savedHome
    Assert ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') -eq $savedUser) 'use --local changed the saved setting'
    Assert ((& $scriptPath path test) -eq $profile -and (& $scriptPath path 3 --env) -eq $profile) 'path wrong'
    Assert (-not (& $scriptPath path home --env)) 'path --env should print nothing for home'

    # add: --key spelling, and the safe default mode
    Set-Content -LiteralPath (Join-Path $fixture 'key') -Value 'sk-test'
    Assert ((ExitCode @('add', 'fresh', '--key') (Join-Path $fixture 'key')) -eq 0) 'add --key failed'
    $fresh = ((& $scriptPath list --json | Out-String) | ConvertFrom-Json) | Where-Object name -eq 'fresh'
    Assert ($fresh.permissions -eq 'auto') 'New profiles should start in auto'
    'PASS: live limits, profile isolation, JSON, offline, RPC error, early exit, timeout, API key, notes, backup, usage indexes,'
    '      headroom, pool, pick, run --perm, exit code, use --local, path, add defaults'
} finally {
    $env:PATH = $savedPath; $env:CXP_ROOT = $savedRoot; $env:CXP_TEST_MODE = $savedMode
    $env:CODEX_HOME = $savedHome; $env:CXP_PASSWORD = $savedPw
    # Only remove this test's GUID directory under the system temp directory.
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'cxp-usage-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
