# Called by ccp/cxp. Keep Python optional for every other switcher command.
param([string]$Tool, [string]$Root, [string[]]$RepairArguments)
$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw 'Repair needs Python 3.11+ on PATH. Other commands do not require Python.' }
& $python.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'
if ($LASTEXITCODE -ne 0) { throw 'Repair needs Python 3.11+ on PATH.' }
if ($RepairArguments -contains '--apply') {
    if (Get-Process -Name claude,codex,codex-app-server -ErrorAction SilentlyContinue) {
        throw 'Close Claude/Codex and their editor integrations before applying repair. Preview works while they are open.'
    }
}
$outputFile = Join-Path ([IO.Path]::GetTempPath()) ('profile-repair-' + [guid]::NewGuid() + '.json')
try {
    & $python.Source (Join-Path $PSScriptRoot 'repair.py') --tool $Tool --root $Root --script-root $PSScriptRoot --environment-output $outputFile @RepairArguments
    if ($LASTEXITCODE -ne 0) { throw 'Repair failed; see the error above. Backups of any changed files are under backups/repair-*.' }
    if (Test-Path -LiteralPath $outputFile) {
        $changes = [IO.File]::ReadAllText($outputFile) | ConvertFrom-Json
        foreach ($property in $changes.PSObject.Properties) {
            [Environment]::SetEnvironmentVariable($property.Name, $property.Value, 'Process')
        }
        # Broadcast saved environment changes to Explorer without changing another setting.
        [Environment]::SetEnvironmentVariable(($Tool.ToUpper() + '_REPAIR_NOTIFY'), $null, 'User')
    }
} finally {
    if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile }
}
