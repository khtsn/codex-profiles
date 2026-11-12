#!/usr/bin/env bash
# cxp - Codex profile switcher for macOS and Linux. Each profile is its own CODEX_HOME
# (separate login, sessions, history, config) under ./profiles/<name>.
# "home" is the stock ~/.codex. "default" (or no name) is an alias for
# whichever profile `cxp default <name>` picked; home until you pick one.
# cxp.ps1 is the Windows implementation: same profiles/ and backups/ layout and the same
# encrypted backup format, so a profile folder or a backup moves between the two. Keep them in step.
# Needs bash 3.2+ (macOS's own), jq, zip/unzip, and OpenSSL 3 for encrypted backups.

die() { printf 'cxp: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die 'jq is required (macOS: brew install jq; Linux: your package manager)'

# Flags taken out of the argument list up front, so they can't be taken for a name.
# No getopts: codex flags like -c must pass through `run` untouched.
usePw=; credsOnly=; offline=; json=
cmd=$1
args=()
for a in "$@"; do
    case "$cmd:$a" in
        backup:--password | backup:-p | restore:--password | restore:-p) usePw=1 ;;   # -p as in ccp
        backup:--creds | restore:--creds) credsOnly=1 ;;
        usage:--offline | pick:--offline) offline=1 ;;
        usage:--json | list:--json | pick:--json) json=1 ;;   # machine-readable output: JSON on stdout, nothing else
        *) args+=("$a") ;;
    esac
done
name=${args[1]}
rest=("${args[@]:2}")
self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
base=${CXP_ROOT:-$self_dir}   # keep data elsewhere (also how the tests avoid real profiles)
[ -d "$base" ] && base=$(cd "$base" && pwd -P)
root=$base/profiles
bakRoot=$base/backups
defFile=$root/.default
# Where `cxp use` saves the profile for new terminals (cxp.ps1 uses a Windows user variable).
# Holds the CODEX_HOME value; empty means home. cxp.sh reads it through `path --saved`.
useFile=$root/.use
isMac=; [ "$(uname -s)" = Darwin ] && isMac=1

# Names become folder names: . @ + only singly between word chars, so emails
# work but "..", leading dots (.default) and trailing dots (Windows strips them) don't.
nameRe='^[A-Za-z0-9_-]+([.@+][A-Za-z0-9_-]+)*$'

DefaultName() {
    if [ -f "$defFile" ]; then head -n 1 "$defFile" | tr -d '[:space:]'; else echo home; fi
}

Names() {   # in `cxp list` order; a profile's number is its position here
    echo home
    [ -d "$root" ] || return 0
    local d
    for d in "$root"/*/; do [ -d "$d" ] && basename "$d"; done | LC_ALL=C sort -f
}

Resolve() {   # alias, list number, or plain name -> name
    local n=$1
    if [ -z "$n" ] || [ "$n" = default ]; then DefaultName; return; fi
    if [[ $n =~ ^[0-9]+$ ]]; then
        local all count
        all=$(Names); count=$(printf '%s\n' "$all" | wc -l | tr -d ' ')
        if [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then die "No profile #$n (cxp list shows 1-$count)"; fi
        printf '%s\n' "$all" | sed -n "${n}p"
        return
    fi
    echo "$n"
}

CheckName() {
    [[ $1 =~ $nameRe ]] || die "Bad profile name '$1' (letters, digits, - _ and single . @ + between them, e.g. me@example.com)"
}

ProfileDir() {   # empty for home = CODEX_HOME unset = ~/.codex
    [ "$1" = home ] && return 0
    CheckName "$1"
    [ -d "$root/$1" ] || die "No profile '$1'. Create it: cxp add $1"
    echo "$root/$1"
}

NewProfileDir() {   # path for a profile that must not exist yet
    local n=$1
    [ -n "$n" ] || die 'Missing new profile name'
    if [ "$n" = home ] || [ "$n" = default ]; then die "'$n' is reserved"; fi
    [[ $n =~ ^[0-9]+$ ]] && die "A name can't be only digits; numbers are list positions"
    CheckName "$n"
    [ -e "$root/$n" ] && die "Profile '$n' already exists"
    echo "$root/$n"
}

ProfilePath() {   # like ProfileDir, but home is a real path and the folder may not exist
    if [ "$1" = home ]; then echo "$HOME/.codex"; return; fi
    [[ $1 =~ $nameRe ]] || die "Bad profile name '$1'"
    echo "$root/$1"
}

Retarget() {   # repoint the saved setting if it was on $1 (cxp.sh repoints this shell)
    if [ -f "$useFile" ] && [ "$(cat "$useFile")" = "$1" ]; then printf '%s' "$2" > "$useFile"; fi
}

# Permission modes = the two top-level config.toml keys codex itself reads,
# so they apply to plain `codex` after `cxp use` as well as `cxp run`.
modeKeys='bypass auto readonly'
ModeValues() {   # -> approval_policy sandbox_mode
    case $1 in
        bypass) echo never danger-full-access ;;          # no prompts, no sandbox
        auto) echo on-request workspace-write ;;          # sandboxed to the project, asks to go beyond
        readonly) echo on-request read-only ;;            # asks before any write
    esac
}

Mode() {   # accepts ccp's name for the read-only mode too -> a mode key
    local m=$1
    [ "$m" = plan ] && m=readonly
    case " $modeKeys " in *" $m "*) [ -n "$m" ] && { echo "$m"; return; } ;; esac
    die "Unknown mode '$m'. Use: ${modeKeys// /, } (plan = readonly)"
}

ConfigPath() {
    local d; d=$(ProfileDir "$1") || exit 1
    [ -n "$d" ] || d=$HOME/.codex
    echo "$d/config.toml"
}

GetPerm() {
    local v ap sm
    # top-level keys end at the first table
    [ -f "$1" ] && v=$(tr -d '\r' < "$1" | awk '
        /^[ \t]*\[/ { exit }
        match($0, /^[ \t]*(approval_policy|sandbox_mode)[ \t]*=[ \t]*["\047]/) {
            k = $0; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k)
            v = substr($0, RLENGTH + 1); sub(/["\047].*/, "", v)
            print k "=" v
        }')
    [ -z "$v" ] && { echo codex-default; return; }
    ap=$(sed -n 's/^approval_policy=//p' <<<"$v" | tail -n 1)
    sm=$(sed -n 's/^sandbox_mode=//p' <<<"$v" | tail -n 1)
    local m
    for m in $modeKeys; do [ "$(ModeValues "$m")" = "$ap $sm" ] && { echo "$m"; return; }; done
    echo "custom: approval_policy=$ap sandbox_mode=$sm"
}

SetPerm() {
    local mode vals nl tmp
    mode=$(Mode "$2") || exit 1
    vals=($(ModeValues "$mode"))
    nl='\n'
    [ -f "$1" ] && grep -q $'\r$' "$1" && nl='\r\n'   # keep the file's own line endings
    tmp=$(mktemp "$1.XXXXXX") || exit 1
    { [ -f "$1" ] && cat "$1"; } | awk -v a="${vals[0]}" -v s="${vals[1]}" -v nl="$nl" '
        BEGIN { nl = (nl == "\\r\\n") ? "\r\n" : "\n"; printf "approval_policy = \"%s\"%ssandbox_mode = \"%s\"%s", a, nl, s, nl }
        { sub(/\r$/, "") }
        !t && /^[ \t]*\[/ { t = 1 }
        !t && /^[ \t]*(approval_policy|sandbox_mode)[ \t]*=/ { next }
        { printf "%s%s", $0, nl }' > "$tmp" && mv "$tmp" "$1"   # UTF-8 without BOM, same as codex writes
}

# A backup is the account, not the data: login + settings per profile.
# ponytail: sessions/history are not backed up (100MB+, sqlite locked while codex runs); zip the profile folder if that's ever needed.
acctFiles='auth.json config.toml cxp-note.txt cxp-pool-off'
# What `backup --creds` / `restore --creds` move: the login alone.
credFiles='auth.json'

GetNote() {
    local f; f="$(ProfilePath "$1")/cxp-note.txt" || exit 1
    [ -f "$f" ] && cat "$f"
    return 0
}

# Pool = the profiles `cxp pick` may hand to automation. In by default; a marker file takes one out.
PoolPath() {
    local d; d=$(ProfileDir "$1") || exit 1
    if [ -n "$d" ]; then echo "$d/cxp-pool-off"; else echo "$root/.home-pool-off"; fi
}

InPool() { [ ! -e "$(PoolPath "$1")" ]; }

Bool() { if "$@"; then echo true; else echo false; fi; }

Has() { local x f=$1; shift; for x in "$@"; do [ "$x" = "$f" ] && return 0; done; return 1; }

Opts() { opts=(); [ -n "$name" ] && opts=("$name"); opts+=("${rest[@]}"); }   # everything after the command, for commands whose flags go anywhere

SaveAccounts() {   # names (one per line), stamp, files, [backup root] -> names actually saved
    local n f got dst
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        got=
        dst=${4:-$bakRoot}/$2/$n
        for f in $3; do
            local src; src="$(ProfilePath "$n")/$f"
            [ -f "$src" ] || continue
            mkdir -p "$dst" && cp -p "$src" "$dst/" || exit 1
            got=1
        done
        [ -n "$got" ] && echo "$n"
    done <<<"$1"
}

# Encrypted backup = one <stamp>.enc file: "CXP1" | salt(16) | iv(16) | AES-256-CBC(zip) | HMAC-SHA256.
# Keys come from the password via PBKDF2-SHA256; encrypt-then-MAC, so a wrong password
# or a damaged file is rejected before anything is decrypted or written. Same bytes as cxp.ps1.
# ponytail: openssl takes the password and derived keys as arguments, so another local user could
# glimpse them in `ps` for the moment it runs. Fine on a personal machine.
encMagic=CXP1

Openssl() {   # an OpenSSL 3 (macOS's own /usr/bin/openssl is LibreSSL, which has no `kdf`)
    local o
    for o in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if "$o" kdf -keylen 1 -kdfopt digest:SHA256 -kdfopt pass:x -kdfopt salt:x -kdfopt iter:1 PBKDF2 >/dev/null 2>&1; then
            echo "$o"; return
        fi
    done
    die 'Encrypted backups need OpenSSL 3 (macOS: brew install openssl@3)'
}

ReadSecret() {   # $1 prompt; hidden input
    local v
    printf '%s: ' "$1" >&2
    IFS= read -rs v; printf '\n' >&2
    printf '%s' "$v"
}

GetPassword() {   # $1 = confirm; $CXP_PASSWORD for scripts, otherwise prompt, masked
    if [ -n "$CXP_PASSWORD" ]; then printf '%s' "$CXP_PASSWORD"; return; fi
    local p q
    p=$(ReadSecret 'Backup password')
    [ -n "$p" ] || die 'Empty password'
    if [ -n "$1" ]; then
        q=$(ReadSecret 'Repeat password')
        [ "$p" = "$q" ] || die "Passwords don't match"
    fi
    printf '%s' "$p"
}

Hex() { od -An -tx1 | tr -d ' \n'; }
Unhex() { printf "$(sed 's/../\\x&/g')"; }
Size() { wc -c < "$1" | tr -d ' '; }

DeriveKeys() {   # password, salt hex -> 128 hex digits: AES key, then HMAC key
    "$ossl" kdf -binary -keylen 64 -kdfopt digest:SHA256 -kdfopt "pass:$1" -kdfopt "hexsalt:$2" \
        -kdfopt iter:200000 PBKDF2 | Hex
}

Hmac() { "$ossl" dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary | Hex; }   # stdin -> hex

Pack() {   # folder, password, out file: folder -> encrypted file
    local zip=$tmp/pack.zip salt iv k
    rm -f "$zip"
    (cd "$1" && zip -q -r -X -D "$zip" .) || die 'zip failed'
    salt=$("$ossl" rand -hex 16); iv=$("$ossl" rand -hex 16)
    k=$(DeriveKeys "$2" "$salt")
    { printf '%s' "$encMagic"; Unhex <<<"$salt"; Unhex <<<"$iv"
      "$ossl" enc -aes-256-cbc -K "${k:0:64}" -iv "$iv" -in "$zip"; } > "$tmp/pack.body" || exit 1
    { cat "$tmp/pack.body"; Hmac "${k:64:64}" < "$tmp/pack.body" | Unhex; } > "$3" || exit 1
    rm -f "$zip" "$tmp/pack.body"
}

Unpack() {   # encrypted file, password -> path of a new folder under $tmp
    local f=$1 size n k dir
    size=$(Size "$f")
    if [ "$size" -lt 68 ] || [ "$(head -c 4 "$f")" != "$encMagic" ]; then die "Not a cxp backup: $f"; fi
    n=$((size - 32))
    k=$(DeriveKeys "$2" "$(tail -c +5 "$f" | head -c 16 | Hex)")
    [ "$(head -c "$n" "$f" | Hmac "${k:64:64}")" = "$(tail -c 32 "$f" | Hex)" ] || die 'Wrong password, or the backup is damaged'
    dir=$(mktemp -d "$tmp/unpack.XXXXXX") || exit 1
    head -c "$n" "$f" | tail -c +37 |
        "$ossl" enc -d -aes-256-cbc -K "${k:0:64}" -iv "$(tail -c +21 "$f" | head -c 16 | Hex)" > "$dir.zip" ||
        die 'Could not decrypt the backup'
    unzip -q "$dir.zip" -d "$dir" || die 'Could not unpack the backup'
    rm -f "$dir.zip"
    echo "$dir"
}

Stamp() { date +%Y%m%d-%H%M%S; }

Login() {   # dir, use key: browser login, or an API key fed to codex on stdin
    if [ -z "$2" ]; then CODEX_HOME=$1 codex login; return; fi
    local key
    if [ ! -t 0 ]; then IFS= read -r key   # echo $KEY | cxp add x --api-key
    else key=$(ReadSecret 'OpenAI API key'); fi   # masked, never in history or argv
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    [ -n "$key" ] || die 'No API key given'
    printf '%s\n' "$key" | CODEX_HOME=$1 codex login --with-api-key || die 'API key login failed'
}

# --- Usage -----------------------------------------------------------------------------------
# Token totals come from local session logs. Account limits are fetched through
# Codex's app server using the profile's own login, without starting a model turn.
# Lookups for several profiles run side by side: every server is started first (StartLimits),
# then each is read in turn (ReadLimits), so the slow part, server start-up, overlaps.
StartLimits() {   # codex home, slot: starts a background lookup writing $tmp/limits.<slot>.*; never fails
    local out=$tmp/limits.$2
    if ! command -v codex >/dev/null 2>&1; then echo 'codex was not found on PATH' > "$out.err"; return; fi
    mkfifo "$out.in" || { echo 'could not start Codex app server' > "$out.err"; return; }
    (
        CODEX_HOME=$1 codex app-server --listen stdio:// < "$out.in" > "$out.out" 2>/dev/null &
        spid=$!
        exec 3> "$out.in"
        # the follow-ups are queued right away, so every server is already fetching while the others are read
        printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cxp","version":"1.0.0"}}}' \
            '{"method":"initialized"}' '{"id":2,"method":"account/rateLimits/read"}' >&3
        end=$((SECONDS + 20))
        while :; do
            grep -q '"id":2' "$out.out" 2>/dev/null && break
            if ! kill -0 "$spid" 2>/dev/null; then echo 'Codex app server closed before replying' > "$out.err"; break; fi
            if [ $SECONDS -ge $end ]; then echo 'lookup timed out' > "$out.err"; break; fi
            sleep 0.1
        done
        exec 3>&-
        # stop the server and anything it started (npm's launcher runs node, then native codex)
        pkill -TERM -P "$spid" 2>/dev/null; kill -TERM "$spid" 2>/dev/null
        wait "$spid" 2>/dev/null
    ) &
    echo $! > "$out.pid"
}

ReadLimits() {   # slot -> the rate-limit bucket JSON, or fails with the reason on stdout
    local out=$tmp/limits.$1 reply
    reply=$(jq -R -c 'fromjson? | select(.id == 2)' "$out.out" 2>/dev/null | head -n 1)
    if [ -z "$reply" ]; then
        if [ -s "$out.err" ]; then cat "$out.err"; else echo 'Codex app server closed before replying'; fi
        return 1
    fi
    # Do not print server errors: upstream diagnostics may contain private details.
    if [ "$(jq 'has("error")' <<<"$reply")" = true ]; then
        echo "Codex rejected the lookup (RPC $(jq -r '.error.code' <<<"$reply")); check this profile's login"
        return 1
    fi
    jq -e -c '.result | (.rateLimitsByLimitId.codex // .rateLimits) // empty' <<<"$reply" 2>/dev/null ||
        { echo 'Codex returned no account limits'; return 1; }
}

LoginOf() {   # auth_mode from the profile's auth.json: chatgpt, apikey, or nothing
    local auth; auth="$(ProfilePath "$1")/auth.json"
    [ -f "$auth" ] && jq -r '.auth_mode // empty' "$auth" 2>/dev/null
    return 0
}

UsageAll() {   # names (one per line) -> one usage JSON object per line
    local n i=0 l
    while IFS= read -r n; do
        i=$((i + 1))
        [ -n "$offline" ] && continue
        l=$(LoginOf "$n")
        [ -n "$l" ] && [ "$l" != apikey ] && StartLimits "$(ProfilePath "$n")" "$i"
    done <<<"$1"
    i=0
    while IFS= read -r n; do
        i=$((i + 1))
        UsageOf "$n" "$i"
    done <<<"$1"
}

Index() {   # same number `cxp list` shows (names compare case-insensitively, as on Windows)
    Names | awk -v n="$1" 'tolower($0) == tolower(n) { print NR; exit }'
}

MidnightEpoch() {
    if [ -n "$isMac" ]; then date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 00:00:00" +%s
    else date -d 'today 00:00' +%s; fi
}

LocalTime() {   # epoch seconds, date format -> local time
    if [ -n "$isMac" ]; then date -r "$1" "+$2"; else date -d "@$1" "+$2"; fi
}

UsageOf() {   # name, slot of a started live lookup (see UsageAll) -> one usage JSON object
    local n=$1 home_ login auth local_ live='null' lookupError=
    home_=$(ProfilePath "$n") || exit 1
    auth=$home_/auth.json
    login='"-"'
    [ -f "$auth" ] && login=$(jq -c '.auth_mode' "$auth" 2>/dev/null || echo '"-"')
    # the last token_count event of each session log (codex may be writing one right now; reading is fine)
    local_=$( { [ -d "$home_/sessions" ] && find "$home_/sessions" -type f -name 'rollout-*.jsonl' -exec awk '
        FNR == 1 && last != "" { print last; last = "" }
        /"type":"token_count"/ { last = $0 }
        END { if (last != "") print last }' {} + ; } 2>/dev/null)
    if [ -f "$tmp/limits.$2.pid" ] || [ -f "$tmp/limits.$2.err" ]; then
        # waited for here, not in ReadLimits: a $(...) subshell cannot wait for this shell's jobs
        [ -f "$tmp/limits.$2.pid" ] && wait "$(cat "$tmp/limits.$2.pid")" 2>/dev/null
        if live=$(ReadLimits "$2"); then :
        else
            lookupError=$live; live='null'
            printf "cxp: '%s': live limits unavailable (%s); using local logs if available\n" "$n" "$lookupError" >&2
        fi
    fi
    jq -n -c --arg n "$n" --argjson number "$(Index "$n")" --arg note "$(GetNote "$n")" --argjson login "$login" \
        --arg local_ "$local_" --argjson live "$live" --arg err "$lookupError" --arg path "$home_" \
        --argjson pool "$(Bool InPool "$n")" --argjson now "$(date +%s)" \
        --argjson day "$(MidnightEpoch)" --argjson week "$(( $(date +%s) - 7 * 86400 ))" '
        def ts: sub("\\.[0-9]+"; "") |
            if test("Z$") then fromdateiso8601
            else capture("^(?<d>.*)(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$") as $c |
                ($c.d + "Z" | fromdateiso8601) - (($c.s + "1" | tonumber) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60))
            end;
        [$local_ | split("\n")[] | fromjson? | select(.timestamp != null)
            | {t: (.timestamp | ts), tot: .payload.info.total_token_usage.total_tokens, rl: .payload.rate_limits}
            | select(.tot != null)] as $ev   # events without totals (e.g. limits only) do not count
        | ($ev | map(select(.rl)) | max_by(.t)) as $newest
        | (if $live then {plan_type: $live.planType, at: $now,
                windows: [$live.primary, $live.secondary | select(.) | {window_minutes: .windowDurationMins, used_percent: .usedPercent, resets_at: .resetsAt}]}
           elif $newest then {plan_type: $newest.rl.plan_type, at: $newest.t,
                windows: [$newest.rl.primary, $newest.rl.secondary | select(.) | {window_minutes, used_percent, resets_at}]}
           else null end) as $src
        | (if $live then "live" elif $newest then "local" else "unavailable" end) as $source
        | ([($src.windows // [])[] | {window_minutes: (.window_minutes | floor), used_percent: (.used_percent + 0),
              resets_at: (.resets_at | floor | todate), reset_passed: (.resets_at < $now), epoch: (.resets_at | floor)}]) as $limits
        | ($login == "apikey") as $api
        | (if $api then [] else $limits end) as $limits   # no ChatGPT rate-limit window
        # headroom_percent / available (with path, pool) are shared with `ccp usage --json`,
        # so one script can rank both tools profiles. The fullest open window decides the room left.
        | (if $api or $login == null or $login == "-" or $source == "unavailable" then null
           else ([0, (100 - ([0, ($limits[] | select(.reset_passed | not) | .used_percent)] | max)) | floor] | max) end) as $headroom
        | {number: $number, profile: $n, note: $note, login: $login,
           plan: ($src.plan_type // "-"), limits: $limits,
           limits_as_of: (if $src then ($src.at | floor | todate) else null end),
           limits_source: (if $api then "not_applicable" else $source end),
           limits_error: (if $err == "" then null else $err end),
           tokens: {today: ($ev | map(select(.t >= $day) | .tot) | add // 0),
                    last_7d: ($ev | map(select(.t >= $week) | .tot) | add // 0),
                    all: ($ev | map(.tot) | add // 0)},
           sessions: ($ev | length), path: $path, pool: $pool,
           headroom_percent: $headroom, available: (if $api then true else ($headroom != null and $headroom > 0) end)}'
}

WindowName() {
    local m=$1
    if [ "$m" -ge 1440 ] && [ $((m % 1440)) -eq 0 ]; then echo "$((m / 1440))d"
    elif [ "$m" -ge 60 ] && [ $((m % 60)) -eq 0 ]; then echo "$((m / 60))h"
    else echo "${m}m"; fi
}

LimitText() {   # one limits entry -> "2% of 7d, resets Nov 17 15:25"
    local w=$1 win
    win=$(WindowName "$(jq -r .window_minutes <<<"$w")")
    if [ "$(jq -r .reset_passed <<<"$w")" = true ]; then echo "window $win has reset since"; return; fi   # stale percent would mislead
    echo "$(jq -r '.used_percent | round' <<<"$w")% of $win, resets $(LocalTime "$(jq -r .epoch <<<"$w")" '%b %-d %H:%M')"
}

Tok() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1e9) printf "%.1fB\n", n / 1e9; else if (n >= 1e6) printf "%.1fM\n", n / 1e6
        else if (n >= 1e3) printf "%.1fk\n", n / 1e3; else print n }'
}

UsageRow() {   # usage JSON -> one tab-separated table row
    local u=$1 login limit source free pool texts w
    login=$(jq -r '.login // ""' <<<"$u")
    source=$(jq -r .limits_source <<<"$u")
    limit=-
    if [ "$login" = apikey ]; then limit='n/a (API key)'
    elif [ "$(jq '.limits | length' <<<"$u")" -gt 0 ]; then
        texts=()
        while IFS= read -r w; do texts+=("$(LimitText "$w")"); done < <(jq -c '.limits[]' <<<"$u")
        limit=$(printf '%s; ' "${texts[@]}"); limit=${limit%; }
    fi
    if [ "$source" = local ]; then limit="[local, $(jq -r .limits_as_of <<<"$u")] $limit"
    elif [ "$(jq -r '.limits_error // ""' <<<"$u")" != '' ]; then limit='unavailable (live lookup failed)'; fi
    free=$(jq -r 'if .headroom_percent == null then "-" else "\(.headroom_percent)%" end' <<<"$u")
    pool=; [ "$(jq -r .pool <<<"$u")" = false ] && pool=off
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(jq -r .number <<<"$u")" "$(jq -r .profile <<<"$u")" \
        "$login" "$(jq -r .plan <<<"$u")" "$limit" "$free" "$pool" "$(Tok "$(jq -r .tokens.today <<<"$u")")" \
        "$(Tok "$(jq -r .tokens.last_7d <<<"$u")")" "$(Tok "$(jq -r .tokens.all <<<"$u")")" "$(jq -r .sessions <<<"$u")" \
        "$(jq -r .note <<<"$u")"
}

Table() {   # tab-separated rows -> aligned columns
    awk -F '\t' '
        { rows[NR] = $0; for (i = 1; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i); if (NF > nf) nf = NF }
        END { for (r = 1; r <= NR; r++) { n = split(rows[r], f, "\t"); line = ""
            for (i = 1; i <= n; i++) line = line (i < n ? sprintf("%-" w[i] "s ", f[i]) : f[i])
            sub(/ +$/, "", line); print line } }'
}

DataOnly() { jq -c 'del(.limits[].text, .limits[].epoch)'; }   # limits[].text/epoch are display-only

# --- Repair ----------------------------------------------------------------------------------
# Codex's SQLite databases record a checksum of every schema migration they ran, and the Windows
# build checksums the same migrations differently from the macOS / Linux one. So a profile folder
# copied between them won't open ("failed to initialize sqlite state runtime"). Repair takes the
# checksums from databases this codex has just made, and writes them only where the applied
# migrations and the resulting schema already match. cxp.ps1 does the same with the same rules.
Sql() { sqlite3 -cmd '.timeout 5000' "$@"; }
Schema() {   # db -> its schema with line endings and spacing evened out
    Sql "$1" "select type, name, sql from sqlite_master where name not like 'sqlite_%' order by type, name" |
        tr -d '\r' | tr -s ' \t\n' '   '
}
Migrations() { Sql "$1" 'select group_concat(version) from (select version from _sqlx_migrations order by version)' 2>/dev/null; }
Checksums() { Sql "$1" "select version || ':' || hex(checksum) from _sqlx_migrations order by version" 2>/dev/null; }

RefDbs() {   # -> sets $ref to a folder of databases made by this codex (an empty CODEX_HOME), or dies
    ref=$tmp/ref
    mkdir "$ref" || exit 1
    StartLimits "$ref" ref   # the app server creates its databases on start; the lookup itself just fails
    wait "$(cat "$tmp/limits.ref.pid")" 2>/dev/null
    ls "$ref"/*.sqlite >/dev/null 2>&1 && return
    [ -s "$tmp/limits.ref.err" ] && die "Codex did not create its databases: $(cat "$tmp/limits.ref.err")"
    die 'Codex did not create its databases'
}

Repair() {   # profile folder, name -> fixes its databases; adds to $fixed
    local r db f
    for r in "$ref"/*.sqlite; do
        f=${r##*/}; db=$1/$f
        [ -f "$db" ] || continue
        [ "$(Checksums "$db")" = "$(Checksums "$r")" ] && continue
        if [ "$(Migrations "$db")" != "$(Migrations "$r")" ]; then
            echo "Left '$2' $f alone: made by a different Codex version (update Codex on both machines, then repair again)"
            continue
        fi
        if [ "$(Schema "$db")" != "$(Schema "$r")" ]; then echo "Left '$2' $f alone: its tables differ from this Codex's"; continue; fi
        Sql "$db" "begin; $(Sql "$r" "select 'update _sqlx_migrations set checksum = x''' || hex(checksum) || ''' where version = ' || version || ';' from _sqlx_migrations") commit;" ||
            die "Could not update '$2' $f (close Codex and try again)"
        fixed=$((fixed + 1))
    done
}

CodexIn() {   # run codex under a profile dir (empty = home)
    if [ -n "$1" ]; then CODEX_HOME=$1 codex "${@:2}"
    else (unset CODEX_HOME; codex "${@:2}"); fi
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

case $cmd in
    list)
        def=$(DefaultName); i=0; rows=()
        while IFS= read -r n; do
            i=$((i + 1))
            d=$(ProfileDir "$n") || exit 1
            mark=' '; [ "$d" = "${CODEX_HOME-}" ] && mark='*'
            tag=''; [ "$n" = "$def" ] && tag=' (default)'
            perm=$(GetPerm "$(ConfigPath "$n")"); note=$(GetNote "$n")
            if [ -n "$json" ]; then
                rows+=("$(jq -n -c --argjson i $i --arg n "$n" --argjson a "$(Bool [ "$mark" = '*' ])" \
                    --argjson def "$(Bool [ "$n" = "$def" ])" --arg p "$(ProfilePath "$n")" --arg perm "$perm" \
                    --arg note "$note" --argjson pool "$(Bool InPool "$n")" \
                    '{number: $i, name: $n, active: $a, default: $def, path: $p, permissions: $perm, note: $note, pool: $pool}')")
            else
                suffix=''; [ -n "$note" ] && suffix=" - $note"
                InPool "$n" || suffix=" [pool off]$suffix"
                echo "$mark $i $n$tag [$perm]$suffix"
            fi
        done < <(Names)
        if [ -n "$json" ]; then printf '%s\n' "${rows[@]}" | jq -s .; fi
        ;;
    add)
        dir=$(NewProfileDir "$name") || exit 1
        mkdir -p "$dir" || exit 1
        [ -f "$HOME/.codex/config.toml" ] && cp "$HOME/.codex/config.toml" "$dir/"   # start from your current settings
        SetPerm "$dir/config.toml" auto   # safe default; `cxp perm <name> bypass` opts out of prompts and sandbox
        k=; if Has --api-key "${rest[@]}" || Has --key "${rest[@]}"; then k=1; fi   # --key as in ccp
        Login "$dir" "$k" || exit 1
        echo "Created '$name'. Switch to it: cxp use $name"
        ;;
    use)   # cxp use [name] [--local]. A child process can't change the shell: cxp.sh applies it
        Opts
        target=; for o in "${opts[@]}"; do [ "$o" != --local ] && { target=$o; break; }; done
        name=$(Resolve "$target") || exit 1
        dir=$(ProfileDir "$name") || exit 1
        if Has --local "${opts[@]}"; then echo "Now using '$name' (this terminal only)"
        else
            mkdir -p "$root" && printf '%s' "$dir" > "$useFile"   # new terminals
            echo "Now using '$name'"
        fi
        ;;
    path)   # the profile's CODEX_HOME folder. --env: the value CODEX_HOME needs (nothing for home);
            # --saved: the value `cxp use` saved for new terminals (exit 2 if none); cxp.sh uses both
        Opts
        if Has --saved "${opts[@]}"; then [ -f "$useFile" ] || exit 2; cat "$useFile"; echo; exit 0; fi
        target=; for o in "${opts[@]}"; do [ "$o" != --env ] && [ "$o" != --local ] && { target=$o; break; }; done
        name=$(Resolve "$target") || exit 1
        if Has --env "${opts[@]}"; then ProfileDir "$name"; else ProfileDir "$name" >/dev/null || exit 1; ProfilePath "$name"; fi
        ;;
    run)   # cxp run <name> [--perm <mode>] [codex args]
        name=$(Resolve "$name") || exit 1
        dir=$(ProfileDir "$name") || exit 1
        if [ "${rest[0]}" = --perm ]; then   # only as the first argument, so codex's own flags stay untouched
            m=$(Mode "${rest[1]}") || exit 1
            vals=($(ModeValues "$m"))
            rest=(-c "approval_policy=${vals[0]}" -c "sandbox_mode=${vals[1]}" "${rest[@]:2}")
        fi
        CodexIn "$dir" "${rest[@]}"
        exit $?   # scripts need codex's own exit code
        ;;
    pool)   # cxp pool <name> [on|off]
        name=$(Resolve "$name") || exit 1
        f=$(PoolPath "$name") || exit 1
        case ${rest[0]} in
            '') ;;
            on) rm -f "$f" ;;
            off) mkdir -p "$root" && : > "$f" ;;
            *) die 'Use: cxp pool <name> [on|off]' ;;
        esac
        if InPool "$name"; then echo "'$name' is in the pool"; else echo "'$name' is out of the pool (cxp pick skips it)"; fi
        ;;
    pick)   # cxp pick [-n <count>] [--json] [--offline]: pool profiles with room left, most headroom first
        Opts
        count=1
        for ((i = 0; i < ${#opts[@]}; i++)); do
            if [ "${opts[$i]}" = -n ]; then
                [[ ${opts[$((i + 1))]} =~ ^[1-9][0-9]*$ ]] || die '-n needs a number, e.g. cxp pick -n 3'
                count=${opts[$((i + 1))]}
            fi
        done
        # out-of-pool profiles are skipped before any lookup
        pool=$(while IFS= read -r n; do InPool "$n" && echo "$n"; done < <(Names))
        rows='[]'
        [ -n "$pool" ] && rows=$(UsageAll "$pool" | jq -c -s --argjson c "$count" \
            'map(select(.available)) | sort_by([-(.headroom_percent // -1), .number]) | .[:$c]')   # API-key profiles (no known headroom) go last
        [ "$(jq length <<<"$rows")" -gt 0 ] ||
            die 'No profile available: all are out of the pool, at their limit, or not logged in (see: cxp usage)'
        if [ -n "$json" ]; then jq 'map(del(.limits[].epoch))' <<<"$rows"; else jq -r '.[].profile' <<<"$rows"; fi
        ;;
    default)
        if [ -n "$name" ]; then
            name=$(Resolve "$name") || exit 1
            ProfileDir "$name" >/dev/null || exit 1   # must exist
            mkdir -p "$root" && echo "$name" > "$defFile"
            echo "Default is now '$name'"
        else echo "Default is '$(DefaultName)'"; fi
        ;;
    rename)
        name=$(Resolve "$name") || exit 1
        old=$(ProfileDir "$name") || exit 1
        [ -n "$old" ] || die "'home' is ~/.codex and can't be renamed"
        new=$(NewProfileDir "${rest[0]}") || exit 1
        mv "$old" "$new" || exit 1
        [ "$(DefaultName)" = "$name" ] && echo "${rest[0]}" > "$defFile"
        Retarget "$old" "$new"
        echo "Renamed '$name' to '${rest[0]}'"
        ;;
    remove)
        name=$(Resolve "$name") || exit 1
        dir=$(ProfileDir "$name") || exit 1
        [ -n "$dir" ] || die "'home' is ~/.codex and can't be removed"
        if ! Has -y "${rest[@]}"; then
            printf "Delete '%s' and ALL its data (login, sessions, history)? Type the name to confirm: " "$name"
            read -r ans
            [ "$ans" = "$name" ] || die 'Cancelled, nothing deleted'
        fi
        rm -rf "$dir" || exit 1
        [ "$(DefaultName)" = "$name" ] && rm -f "$defFile"   # default falls back to home
        Retarget "$dir" ''                                      # if it was active, back to home
        echo "Removed '$name'"
        ;;
    perm)
        name=$(Resolve "$name") || exit 1
        cfg=$(ConfigPath "$name") || exit 1
        if [ ${#rest[@]} -gt 0 ]; then SetPerm "$cfg" "${rest[0]}" || exit 1; fi
        echo "'$name' permissions: $(GetPerm "$cfg")"
        ;;
    note)
        [ -n "$name" ] || die 'Use: cxp note <name> [text | --clear]'
        name=$(Resolve "$name") || exit 1
        ProfileDir "$name" >/dev/null || exit 1
        file="$(ProfilePath "$name")/cxp-note.txt"
        if [ ${#rest[@]} -eq 1 ] && [ "${rest[0]}" = --clear ]; then
            rm -f "$file"; echo "Cleared note for '$name'"
        elif [ ${#rest[@]} -gt 0 ]; then
            note="${rest[*]}"
            [[ $note == *$'\n'* || $note == *$'\r'* ]] && die 'Use a single line for a quick note'
            mkdir -p "$(dirname "$file")" && printf '%s' "$note" > "$file"
            echo "Note for '$name': $note"
        else GetNote "$name"; echo; fi
        ;;
    usage)
        names=$(Names)
        if [ -n "$name" ]; then
            name=$(Resolve "$name") || exit 1
            # match the listed name's case (the folder is found case-insensitively on macOS, as on Windows)
            i=$(Index "$name"); [ -n "$i" ] && name=$(Names | sed -n "${i}p")
            ProfileDir "$name" >/dev/null || exit 1
            names=$name
        fi
        all=$(UsageAll "$names")
        if [ -n "$json" ]; then
            printf '%s\n' "$all" | DataOnly | jq -s .
            exit 0
        fi
        { printf '#\tProfile\tLogin\tPlan\tLimit\tFree\tPool\tToday\tLast7d\tAll\tSessions\tNote\n'
          printf '%s\t' - ------- ----- ---- ----- ---- ---- ----- ------ --- -------- ; printf -- '----\n'
          while IFS= read -r u; do UsageRow "$u"; done <<<"$all"; } | Table
        echo
        echo "Tokens are local session totals (cached input included), counted at each session's last activity. Limits are live unless marked local. Use --offline to skip live lookups."
        ;;
    install)   # make `cxp` a command in every new terminal; safe to re-run
        chmod +x "$self_dir/cxp.bash"
        # a shell function, not just a command on PATH: `use` must set CODEX_HOME in the shell itself
        line="source \"$self_dir/cxp.sh\""
        shell=$(basename "${SHELL:-}")
        rcs=()
        [ "$shell" = zsh ] || [ -f "$HOME/.zshrc" ] && rcs+=(.zshrc)
        if [ "$shell" = bash ] || [ -f "$HOME/.bashrc" ]; then
            rcs+=(.bashrc)
            # macOS terminals start bash as a login shell, which reads .bash_profile and not .bashrc
            [ -n "$isMac" ] && [ "$shell" = bash ] && rcs+=(.bash_profile)
        fi
        [ ${#rcs[@]} -gt 0 ] || rcs=(.profile)
        for rc in "${rcs[@]}"; do
            if [ -f "$HOME/$rc" ] && grep -qF '/cxp.sh' "$HOME/$rc"; then echo "Already in ~/$rc"
            else printf '\n%s\n' "$line" >> "$HOME/$rc"; echo "Added to ~/$rc"; fi
        done
        echo 'Open a new terminal (or source your shell rc file), then run: cxp list'
        ;;
    backup)   # cxp backup [name] [--password] [--creds]
        names=$(Names)
        if [ -n "$name" ]; then name=$(Resolve "$name") || exit 1; ProfileDir "$name" >/dev/null || exit 1; names=$name; fi
        stamp=$(Stamp)
        files=$acctFiles; what='login + config'
        if [ -n "$credsOnly" ]; then files=$credFiles; stamp+=-creds; what='login only'; fi
        umask 077   # login tokens: keep backups private
        if [ -z "$usePw" ]; then
            saved=$(SaveAccounts "$names" "$stamp" "$files")
            [ -n "$saved" ] || die 'Nothing to back up (no login or config found)'
            echo "Backed up $(paste -sd, - <<<"$saved" | sed 's/,/, /g') ($what) to $bakRoot/$stamp"
        else
            ossl=$(Openssl)
            pass=$(GetPassword confirm) || exit 1
            saved=$(SaveAccounts "$names" "$stamp" "$files" "$tmp/plain")
            [ -n "$saved" ] || die 'Nothing to back up (no login or config found)'
            mkdir -p "$bakRoot" || exit 1
            out=$bakRoot/$stamp.enc
            Pack "$tmp/plain/$stamp" "$pass" "$out"
            echo "Backed up $(paste -sd, - <<<"$saved" | sed 's/,/, /g') ($what) to $out (encrypted)"
        fi
        ;;
    backups)
        if [ -d "$bakRoot" ]; then
            for i in "$bakRoot"/*; do
                [ -e "$i" ] || continue
                b=$(basename "$i")
                if [ -d "$i" ]; then echo "$b  $(for d in "$i"/*/; do [ -d "$d" ] && basename "$d"; done | paste -sd, - | sed 's/,/, /g')"
                elif [[ $b == *.enc ]]; then echo "${b%.enc}  (encrypted)"; fi
            done | LC_ALL=C sort
        fi
        ;;
    repair)   # cxp repair [name]: databases from a profile folder copied from Windows (or to it) open again
        command -v sqlite3 >/dev/null 2>&1 || die 'sqlite3 is required (Linux: your package manager)'
        if [ -n "$name" ]; then name=$(Resolve "$name") || exit 1; ProfileDir "$name" >/dev/null || exit 1; names=$name
        else names=$(Names); fi
        RefDbs
        while IFS= read -r n; do
            dir=$(ProfilePath "$n")
            [ -d "$dir" ] || continue
            fixed=0
            Repair "$dir" "$n"
            if [ $fixed -gt 0 ]; then echo "Repaired $fixed database(s) in '$n'"; else echo "'$n': nothing to repair"; fi
        done <<<"$names"
        ;;
    restore)   # cxp restore [name] [id] [--password] [--creds]
        stamp=${rest[0]}
        # a lone backup id works too: `cxp restore 20261110-165355`
        if [ -n "$name" ] && [ -z "$stamp" ] && [[ $name =~ ^[0-9]{8}-[0-9]{6} ]] && [ ! -d "$root/$name" ] &&
            { [ -d "$bakRoot/$name" ] || [ -f "$bakRoot/$name.enc" ]; }; then stamp=$name; name=; fi
        if [ -n "$name" ]; then name=$(Resolve "$name") || exit 1; fi   # no name = every profile in the backup
        if [ -n "$stamp" ]; then
            [[ $stamp =~ ^[A-Za-z0-9_-]+$ ]] || die "No backup '$stamp' (see: cxp backups)"
            if [ -f "$bakRoot/$stamp.enc" ]; then   # an encrypted id is recognised by itself
                ossl=$(Openssl); src=$(Unpack "$bakRoot/$stamp.enc" "$(GetPassword)") || exit 1
            elif [ -d "$bakRoot/$stamp" ]; then src=$bakRoot/$stamp
            else die "No backup '$stamp' (see: cxp backups)"; fi
        elif [ -n "$usePw" ]; then
            encs=$( [ -d "$bakRoot" ] && ls "$bakRoot" | grep '\.enc$' | LC_ALL=C sort -r)
            [ -n "$encs" ] || die 'No encrypted backup to restore from. Make one: cxp backup --password'
            ossl=$(Openssl)
            pass=$(GetPassword) || exit 1
            src=
            while IFS= read -r f; do   # newest that has what we need
                d=$(Unpack "$bakRoot/$f" "$pass") || exit 1
                if [ -z "$name" ] || [ -d "$d/$name" ]; then src=$d; stamp=${f%.enc}; break; fi
                rm -rf "$d"
            done <<<"$encs"
            [ -n "$src" ] || die "No encrypted backup has '$name' (see: cxp backups)"
        else
            # newest plain backup that has what we need; automatic pre-restore snapshots only by explicit id
            stamp=
            if [ -d "$bakRoot" ]; then
                stamp=$(for d in "$bakRoot"/*/; do [ -d "$d" ] && basename "$d"; done | LC_ALL=C sort -r |
                    while IFS= read -r s; do
                        [[ $s == *-before-restore ]] && continue
                        if [ -z "$name" ] || [ -d "$bakRoot/$s/$name" ]; then echo "$s"; break; fi
                    done)
            fi
            [ -n "$stamp" ] || die 'No backup to restore from. Make one: cxp backup'
            src=$bakRoot/$stamp
        fi
        names=$(for d in "$src"/*/; do [ -d "$d" ] && basename "$d"; done)
        if [ -n "$name" ]; then
            grep -qxF -- "$name" <<<"$names" || die "Backup $stamp has no '$name' (see: cxp backups)"
            names=$name
        fi
        while IFS= read -r n; do ProfilePath "$n" >/dev/null || exit 1; done <<<"$names"   # names from the backup must be valid
        files=$acctFiles; [ -n "$credsOnly" ] && files=$credFiles
        umask 077
        pre="$(Stamp)-before-restore"
        kept=$(SaveAccounts "$names" "$pre" "$files")   # what is about to be overwritten (plain, like the live files)
        restored=()
        while IFS= read -r n; do
            dst=$(ProfilePath "$n")
            got=
            for f in $files; do [ -f "$src/$n/$f" ] && got=1; done
            if [ -z "$got" ]; then echo "Skipped '$n': nothing to restore in this backup"; continue; fi
            mkdir -p "$dst" || exit 1   # brings back a removed profile
            for f in $files; do [ -f "$src/$n/$f" ] && { cp -p "$src/$n/$f" "$dst/$f" || exit 1; }; done
            restored+=("$n")
        done <<<"$names"
        [ ${#restored[@]} -gt 0 ] || die 'Nothing restored'
        what=; [ -n "$credsOnly" ] && what='login for '
        echo "Restored $what$(printf '%s, ' "${restored[@]}" | sed 's/, $//') from backup $stamp"
        [ -n "$kept" ] && echo "Previous login/config kept as backup $pre"
        ;;
    *)
        cat <<'EOF'
cxp install            one-time setup: `cxp` in every new bash and zsh terminal
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
EOF
        ;;
esac
