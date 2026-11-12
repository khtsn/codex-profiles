#!/usr/bin/env bash
# Integration checks for cxp.bash with an isolated profile (CXP_ROOT) and a fake Codex app server.
# Nothing here touches ~/.codex or the saved `cxp use` setting. Run: bash tests/cxp.bash
script=$(cd "$(dirname "$0")/.." && pwd -P)/cxp.bash
fixture=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cxp-usage-XXXXXX")" && pwd -P)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cxp() { "$script" "$@"; }

profile=$fixture/profiles/test
mkdir -p "$profile/sessions" "$fixture/bin"
echo '{"auth_mode":"chatgpt"}' > "$profile/auth.json"
now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
echo '{"timestamp":"'"$now"'","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}},"rate_limits":{"plan_type":"pro","primary":{"used_percent":40,"window_minutes":300,"resets_at":2000000000}}}}' \
    > "$profile/sessions/rollout-test.jsonl"
# a codex database: one table, and the migrations that made it with checksum $1 ($2: CRLF in the schema, as from Windows)
mkdb() {
    printf "create table threads (id text primary key,%s title text);" "${2:+$'\r\n'}"
    echo "create table _sqlx_migrations (version bigint primary key, description text, checksum blob, success boolean);"
    echo "insert into _sqlx_migrations values (1, 'threads', x'$1', 1), (2, 'title', x'$1', 1);"
}
# fake codex: the app server below; `login` succeeds; anything else records its profile and arguments, then fails with 7
cat > "$fixture/bin/codex" <<EOF
#!/bin/bash
if [ "\$1" = app-server ]; then exec bash "$fixture/server.bash"; fi
if [ "\$1" = login ]; then cat >/dev/null; exit 0; fi
echo "[\${CODEX_HOME-}] \$*" > "$fixture/ran"
exit 7
EOF
cat > "$fixture/server.bash" <<EOF
echo "\$CODEX_HOME" >> "$fixture/launches"
# cxp repair starts the server on an empty folder to get this codex's databases
[ "\${CODEX_HOME##*/}" = ref ] && sqlite3 "\$CODEX_HOME/state_5.sqlite" "$(mkdb 1A2B)"
while IFS= read -r line; do
    case \$line in
        *'"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *rateLimits/read*)
            case \$CXP_TEST_MODE in
                timeout) sleep 60; exit ;;
                exit) exit ;;
                failure) echo '{"id":2,"error":{"code":-32000,"message":"SECRET_MUST_NOT_PRINT"}}' ;;
                *) echo '{"method":"account/updated","params":{}}'
                   echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":2000000000}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":2000000000}}}}}' ;;
            esac ;;
    esac
done
EOF
chmod +x "$fixture/bin/codex"
export PATH="$fixture/bin:$PATH" CXP_ROOT=$fixture CXP_TEST_MODE=success
unset CODEX_HOME CXP_PASSWORD

cxp note 2 'Renew next month - team account' >/dev/null
[ "$(cxp note test)" = 'Renew next month - team account' ] || fail 'Note did not round-trip by profile number/name'
[ "$(cxp list --json | jq -r '.[1].note')" = 'Renew next month - team account' ] || fail 'List JSON omitted note'
live=$(cxp usage test --json)
[ "$(jq '.[0].number' <<<"$live")" = 2 ] || fail 'Filtered usage number differs from list'
[ "$(jq -r '.[0].note' <<<"$live")" = 'Renew next month - team account' ] || fail 'Usage JSON omitted note'
[ "$(jq -r 'length, .[0].limits_source' <<<"$live" | paste -sd, -)" = 1,live ] || fail 'Live lookup did not succeed'
[ "$(jq -r '(.[0].limits | length), .[0].limits[0].used_percent' <<<"$live" | paste -sd, -)" = 2,17 ] || fail 'Live windows / canonical bucket were not used'
[ "$(jq '.[0].tokens.all' <<<"$live")" = 123 ] || fail 'Local token totals changed'
[ "$(jq -r '.[0] | "\(.headroom_percent),\(.available)"' <<<"$live")" = 37,true ] || fail 'Headroom should come from the fullest window'
[ "$(jq -r '.[0] | "\(.path),\(.pool)"' <<<"$live")" = "$profile,true" ] || fail 'Usage JSON shared fields wrong'
[ "$(jq -c '.[0].limits[0] | keys' <<<"$live")" = '["reset_passed","resets_at","used_percent","window_minutes"]' ] || fail 'Limit fields changed'
[ "$(cat "$fixture/launches")" = "$profile" ] || fail 'Wrong profile home passed to server'
[ -z "${CODEX_HOME-}" ] || fail 'Parent profile changed'
local_=$(cxp usage --offline test --json)
[ "$(jq -r '.[0] | "\(.limits_source),\(.limits[0].used_percent),\(.headroom_percent)"' <<<"$local_")" = local,40,60 ] || fail 'Offline limits incorrect'
table=$(cxp usage test --offline)
grep -Eq '^# +Profile' <<<"$table" && grep -Eq '^2 +test' <<<"$table" && grep -q 'Renew next month' <<<"$table" || fail 'Usage table omitted index or note'
if [ "$(uname -s)" = Darwin ]; then   # case-insensitive folders, as on Windows
    [ "$(cxp usage TEST --offline --json | jq '.[0].number')" = 2 ] || fail 'Case-insensitive profile lookup changed the usage index'
fi
[ "$(wc -l < "$fixture/launches" | tr -d ' ')" = 1 ] || fail 'Offline mode started a server'
for mode in failure exit timeout; do
    start=$SECONDS
    out=$(CXP_TEST_MODE=$mode cxp usage test --json 2> "$fixture/errors")
    [ "$(jq -r '.[0] | "\(.limits_source),\(.limits_error != null),\(.limits[0].used_percent)"' <<<"$out")" = local,true,40 ] || fail "Missing fallback for $mode"
    grep -q SECRET_MUST_NOT_PRINT "$fixture/errors" && fail 'Server error leaked'
    [ $((SECONDS - start)) -lt 30 ] || fail "Lookup did not stop promptly for $mode"
done
launches=$(wc -l < "$fixture/launches")
echo '{"auth_mode":"apikey"}' > "$profile/auth.json"
api=$(cxp usage test --json)
[ "$(jq -r '.[0] | "\(.limits | length),\(.limits_source),\(.available),\(.headroom_percent)"' <<<"$api")" = 0,not_applicable,true,null ] || fail 'API-key profile usage incorrect'
[ "$(wc -l < "$fixture/launches")" = "$launches" ] || fail 'API-key profile started a server'
echo '{"auth_mode":"chatgpt"}' > "$profile/auth.json"

# backup / restore keep the note
cxp backup test >/dev/null
cxp note test --clear >/dev/null
[ -z "$(cxp note test)" ] || fail 'Note was not cleared'
cxp restore test >/dev/null
[ "$(cxp note test)" = 'Renew next month - team account' ] || fail 'Backup did not preserve note'
mkdir "$fixture/profiles/other"
[ -z "$(cxp note other)" ] || fail 'Note leaked to another account'
numbered=$(cxp usage --offline --json)
[ "$(jq -r '[.[].number] | join(",")' <<<"$numbered"),$(jq -r '.[2].profile' <<<"$numbered")" = 1,2,3,test ] || fail 'All-profile usage ordering differs from list'
[ "$(jq '.[1].available' <<<"$numbered")" = false ] || fail 'A profile without a login should not be available'

# --creds: only the login goes in and comes back
sleep 1   # backups are named by the second
cxp backup test --creds >/dev/null
creds=$(ls "$fixture/backups" | grep -- '-creds$')
[ -n "$creds" ] && [ "$(ls "$fixture/backups/$creds/test")" = auth.json ] || fail 'backup --creds saved more than the login'
echo '{"auth_mode":"chatgpt","marker":"new"}' > "$profile/auth.json"
cxp note test 'changed' >/dev/null
cxp restore test "$creds" --creds >/dev/null
[ "$(jq -r '.marker // "old"' "$profile/auth.json")" = old ] || fail 'restore --creds did not bring back the login'
[ "$(cxp note test)" = changed ] || fail 'restore --creds touched more than the login'
cxp note test 'Renew next month - team account' >/dev/null

# pool + pick. home leaves the pool first, so nothing below depends on the real ~/.codex.
cxp pool home off >/dev/null
[ -f "$fixture/profiles/.home-pool-off" ] || fail 'Home pool marker is not under CXP_ROOT'
listed=$(cxp list --json)
[ "$(jq -r '"\(.[0].pool),\(.[2].pool)"' <<<"$listed")" = false,true ] || fail 'List JSON pool wrong'
[ "$(cxp pick -n 5 --offline | paste -sd, -)" = test ] || fail 'pick should return only available pool profiles'
[ "$(cxp pick --json --offline | jq -r '"\(length),\(.[0].profile),\(.[0].available)"')" = 1,test,true ] || fail 'pick --json wrong'
cxp pool test off >/dev/null
cxp list | grep -Eq 'test \[[^]]+\] \[pool off\]' || fail 'list does not show pool off'
cxp pick --offline >/dev/null 2>&1 && fail 'pick with an empty pool should fail'
export CXP_PASSWORD=test-password
cxp backup test -p >/dev/null
[ "$(ls "$fixture/backups" | grep -c '\.enc$')" = 1 ] || fail 'backup -p did not write an encrypted backup'
cxp pool test on >/dev/null
cxp restore test -p >/dev/null
[ "$(cxp list --json | jq '.[2].pool')" = false ] || fail 'Backup did not preserve pool off'
CXP_PASSWORD=wrong cxp restore test -p >/dev/null 2>&1 && fail 'A wrong password should be rejected'
cxp pool test on >/dev/null

# perm: SetPerm keeps tables and the rest of config.toml
printf 'model = "x"\napproval_policy = "never"\n[mcp_servers.a]\nsandbox_mode = "keep"\n' > "$profile/config.toml"
cxp perm test plan >/dev/null
[ "$(cxp perm test)" = "'test' permissions: readonly" ] || fail 'perm plan should set readonly'
[ "$(cat "$profile/config.toml")" = "$(printf 'approval_policy = "on-request"\nsandbox_mode = "read-only"\nmodel = "x"\n[mcp_servers.a]\nsandbox_mode = "keep"')" ] || fail 'perm rewrote config.toml wrongly'

# run: profile isolation, exit code, --perm
cxp run test exec hi; [ $? = 7 ] || fail 'run did not pass on the exit code'
[ "$(cat "$fixture/ran")" = "[$profile] exec hi" ] || fail 'run changed the arguments or the profile'
cxp run test --perm plan exec hi
[ "$(cat "$fixture/ran")" = "[$profile] -c approval_policy=on-request -c sandbox_mode=read-only exec hi" ] || fail 'run --perm wrong'
rm "$fixture/ran"
cxp run test --perm nonsense exec hi 2>/dev/null; [ $? = 1 ] && [ ! -f "$fixture/ran" ] || fail 'run with a bad --perm should fail before starting codex'

# use: --local saves nothing; plain use saves under CXP_ROOT; path
cxp use test --local >/dev/null
cxp path --saved >/dev/null; [ $? = 2 ] || fail 'use --local changed the saved setting'
cxp use test >/dev/null
[ "$(cxp path --saved)" = "$profile" ] || fail 'use did not save the profile'
[ "$(cxp path test)" = "$profile" ] && [ "$(cxp path 3 --env)" = "$profile" ] || fail 'path wrong'
[ -z "$(cxp path home --env)" ] || fail 'path --env should print nothing for home'
cxp rename test renamed >/dev/null
[ "$(cxp path --saved)" = "$fixture/profiles/renamed" ] || fail 'rename did not repoint the saved setting'
cxp rename renamed test >/dev/null

# the shell wrapper switches this shell (bash; zsh too when installed)
for sh in bash zsh; do
    command -v $sh >/dev/null || continue
    got=$($sh -c "source '$(dirname "$script")/cxp.sh'; cxp use 3 --local >/dev/null; echo \"\$CODEX_HOME\"")
    [ "$got" = "$profile" ] || fail "cxp.sh under $sh: use --local did not set CODEX_HOME ($got)"
    got=$($sh -c "source '$(dirname "$script")/cxp.sh'; echo \"\$CODEX_HOME\"")
    [ "$got" = "$profile" ] || fail "cxp.sh under $sh: new shells did not start on the saved profile"
done

# add: --key spelling, and the safe default mode
echo sk-test | cxp add fresh --key >/dev/null || fail 'add --key failed'
[ "$(cxp list --json | jq -r '.[] | select(.name == "fresh") | .permissions')" = auto ] || fail 'New profiles should start in auto'
# repair: checksums from another OS are replaced; a database from another codex version is left alone
command -v sqlite3 >/dev/null || fail 'sqlite3 is needed for the repair checks'
sqlite3 "$profile/state_5.sqlite" "$(mkdb CCDD crlf)"
cp "$profile/state_5.sqlite" "$fixture/profiles/fresh/state_5.sqlite"
sqlite3 "$fixture/profiles/fresh/state_5.sqlite" 'delete from _sqlx_migrations where version = 2'
out=$(cxp repair)
grep -q "Repaired 1 database(s) in 'test'" <<<"$out" || fail "repair did not fix the copied database: $out"
grep -q "Left 'fresh' state_5.sqlite alone: made by a different Codex version" <<<"$out" || fail "repair should skip another version: $out"
[ "$(sqlite3 "$profile/state_5.sqlite" 'select group_concat(hex(checksum)) from _sqlx_migrations')" = 1A2B,1A2B ] || fail 'repair wrote the wrong checksums'
[ "$(sqlite3 "$fixture/profiles/fresh/state_5.sqlite" 'select hex(checksum) from _sqlx_migrations')" = CCDD ] || fail 'repair changed a skipped database'
[ "$(cxp repair test)" = "'test': nothing to repair" ] || fail 'a second repair should find nothing'
echo 'PASS: live limits, profile isolation, JSON, offline, RPC error, early exit, timeout, API key, notes, backup, --creds,'
echo '      encrypted backup, usage indexes, headroom, pool, pick, perm, run --perm, exit code, use, path, wrapper, add defaults, repair'
