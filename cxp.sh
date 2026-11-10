# cxp for Git Bash. `cxp install` adds the line that sources this to ~/.bashrc.
# Thin wrapper over cxp.ps1 (one implementation); only adds what a child
# process can't do: updating CODEX_HOME in this shell after `use`.
CXP_DIR="$(cygpath -w "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"

cxp() {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CXP_DIR\\cxp.ps1" "$@" || return
    if [ "$1" = use ] && [[ " $* " == *" --local "* ]]; then
        # this shell only: ask cxp.ps1 what the variable should be (nothing for home)
        CODEX_HOME="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CXP_DIR\\cxp.ps1" path --env "${@:2}" | tr -d '\r')"
    # after use, or when rename/remove took this shell's profile folder away
    elif [ "$1" = use ] || { [ -n "$CODEX_HOME" ] && [ ! -d "$CODEX_HOME" ]; }; then
        # read back what `use` just persisted, so "default"/no-name resolve in one place
        CODEX_HOME="$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('CODEX_HOME','User')" | tr -d '\r')"
    else
        return 0
    fi
    if [ -n "$CODEX_HOME" ]; then export CODEX_HOME; else unset CODEX_HOME; fi
}
