# cxp for bash and zsh: Git Bash on Windows, and macOS / Linux. `cxp install` adds the line
# that sources this to your shell's rc file.
# Thin wrapper over the implementation (cxp.ps1 on Windows, cxp.bash elsewhere); it only adds
# what a child process can't do: updating CODEX_HOME in this shell after `use`.
if [ -n "$ZSH_VERSION" ]; then eval 'CXP_DIR=${${(%):-%x}:A:h}'
else CXP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; fi
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) CXP_WIN=1; CXP_DIR="$(cygpath -w "$CXP_DIR")" ;;
    *) CXP_WIN= ;;
esac

_cxp() {
    if [ -n "$CXP_WIN" ]; then powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CXP_DIR\\cxp.ps1" "$@"
    else "$CXP_DIR/cxp.bash" "$@"; fi
}

_cxp_saved() {   # what `cxp use` saved for new terminals; fails if nothing was saved
    if [ -n "$CXP_WIN" ]; then
        powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('CODEX_HOME','User')" | tr -d '\r'
    else _cxp path --saved 2>/dev/null; fi
}

_cxp_set() {
    CODEX_HOME="$1"
    if [ -n "$CODEX_HOME" ]; then export CODEX_HOME; else unset CODEX_HOME; fi
}

cxp() {
    _cxp "$@" || return
    local v
    case " $* " in *" --local "*) local in_local=1 ;; *) local in_local= ;; esac
    if [ "$1" = use ] && [ -n "$in_local" ]; then
        # this shell only: ask cxp what the variable should be (nothing for home)
        shift
        v="$(_cxp path --env "$@" | tr -d '\r')" || return
    # after use, or when rename/remove took this shell's profile folder away
    elif [ "$1" = use ] || { [ -n "$CODEX_HOME" ] && [ ! -d "$CODEX_HOME" ]; }; then
        # read back what `use` just persisted, so "default"/no-name resolve in one place
        v="$(_cxp_saved)"
    else
        return 0
    fi
    _cxp_set "$v"
}

# New terminals start on the profile `cxp use` saved (Windows does this through a user variable).
if [ -z "$CXP_WIN" ] && _cxp_saved_v="$(_cxp_saved)"; then _cxp_set "$_cxp_saved_v"; fi
unset _cxp_saved_v
