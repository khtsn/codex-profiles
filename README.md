# cxp

A profile switcher for [Codex CLI](https://github.com/openai/codex) on Windows, macOS and Linux. Each profile is its own `CODEX_HOME`, with its own login, sessions, history and config, so you can move between several OpenAI accounts without logging out and back in.

Profiles live in `profiles/<name>` next to the script. The special profile `home` is your normal `~/.codex`.

## Install

Needs Windows PowerShell 5.1+ and `codex` on your PATH. Git Bash is optional.

```powershell
.\cxp.ps1 install
```

This adds the folder to your user PATH and, if you use Git Bash, sources `cxp.sh` from `~/.bashrc` (and the login file Git Bash reads). It is safe to run again. Open a new terminal afterwards and run `cxp list`.

On macOS or Linux it needs bash 3.2+ (macOS's own is fine; zsh works as your shell), `jq`, `zip`/`unzip`, and OpenSSL 3 for encrypted backups (`brew install jq openssl@3` on macOS). Run once from bash or zsh:

```sh
~/projects/codex-profiles/cxp.bash install
```

This adds `source ".../cxp.sh"` to `~/.zshrc` and/or `~/.bashrc` (and `~/.bash_profile` for bash on macOS). `cxp use` saves your choice in `profiles/.use`, and new terminals start on that profile. The Windows tool is `cxp.ps1` and the macOS / Linux one is `cxp.bash`; they share the profile layout and the backup format, so a backup made on one restores on the other.

## Repair after moving (Windows)

Move the entire folder, including `profiles`, with Codex closed. From the new
location, preview the repairs, then apply them:

```powershell
.\cxp.ps1 repair --paths
.\cxp.ps1 repair --paths --apply
# If detection missed an old folder, or the old copy still exists:
.\cxp.ps1 repair --paths --from 'F:\codex-profiles'
.\cxp.ps1 repair --paths --from 'F:\codex-profiles' --apply
```

Only relocation repair requires Python 3.11+ (`python` on PATH). Preview does not write
configuration, environment settings, or backups. `--from` can be repeated for
multiple previous locations. Automatic detection selects missing roots referenced
by known profiles; an existing old copy requires an explicit `--from`.

Repair updates `hooks.json`, relocated profile paths in `config.toml`, matching
`CODEX_HOME` values, old PATH entries, and existing `cxp.sh` source lines in Bash
startup files. It honors `CXP_ROOT` for data and uses the script's location for
shell/PATH entries. Affected hook trust records are removed so changed commands
must be approved again. It leaves credentials, transcripts, historical working
directories, and unrelated paths alone. It does not install missing shell entries;
use `install` for a first installation.

For `state_*.sqlite`, repair updates `threads.rollout_path` only when the relocated
transcript exists. Missing transcripts are reported and left unchanged. Databases
are backed up through SQLite (including committed WAL contents), and each database
update uses a transaction. Unsupported schemas stop the repair before changes.

Applying refuses to run while a Claude/Codex process is detected. Close editor
integrations too. Original files and saved user environment values go under
`backups/repair-<timestamp>`; `files.json` maps each backup to its original path.
Backups may contain private configuration. If an apply fails, inspect its error
and backups before retrying; the whole repair is not a single transaction.
Restart terminals and apps afterward, test hooks, and resume an existing session.
Git Bash refreshes its profile variable; start a new shell for PATH and wrapper
changes.

Run isolated repair tests with `python -B .\tests\repair_test.py`.

## Quick start

```powershell
cxp add me@example.com            # create a profile and log in (browser)
cxp add work --api-key            # ...or log in with an OpenAI API key
cxp list                          # show profiles
cxp use work                      # switch this terminal and all new ones
cxp run me@example.com resume     # run codex once under a profile, without switching
```

## Commands

| Command | What it does |
| --- | --- |
| `cxp install` | One-time setup: `cxp` in every new PowerShell and Git Bash terminal (Windows), or bash and zsh terminal (macOS / Linux) |
| `cxp repair --paths [--from <old-folder>] [--apply]` | Preview or repair moved paths on Windows; requires Python 3.11+ |
| `cxp list [--json]` | Show profiles. `*` marks the one active in this terminal, with its permission mode |
| `cxp add <name> [--api-key]` | Create a profile and log in to it. It starts with your `~/.codex` settings and skills |
| `cxp use [name] [--local]` | Switch this terminal and all new ones. No name means the default. `--local` switches this terminal only |
| `cxp run <name> [--perm <mode>] [args]` | Run `codex` once under a profile. Extra args go straight to codex |
| `cxp path <name>` | Print the profile's `CODEX_HOME` folder |
| `cxp default [name]` | Show or pick the default profile (`home` until you pick one) |
| `cxp perm <name> [mode]` | Show or set permissions: `bypass`, `auto`, `readonly` |
| `cxp note <name> [text \| --clear]` | Read, set, or clear a quick account note; shown in list and usage |
| `cxp usage [name] [--json] [--offline]` | Local token totals and live account limits per profile |
| `cxp pool <name> [on\|off]` | Show or set whether `cxp pick` may choose this profile |
| `cxp pick [-n <count>] [--json] [--offline]` | Print the pool profile with the most room left |
| `cxp rename <old> <new>` | Rename a profile |
| `cxp remove <name> [-y]` | Delete a profile and all its data. `-y` skips the confirmation |
| `cxp backup [name] [--password] [--creds]` | Save login and config of one or all profiles (`--creds`: login only) |
| `cxp backups` | List backups |
| `cxp restore [name] [id] [--password] [--creds]` | Restore one or all profiles from a backup (`--creds`: login only) |
| `cxp repair [name]` | Make Codex open the databases of profile folders copied between Windows and macOS / Linux |

Anywhere a name goes you can also give `default`, or the number shown by `cxp list` (for example `cxp use 2`).

### Skills

A new profile starts with your own skills from `~/.codex/skills`, so a skill you
installed for `home` works in every profile you add afterwards. On macOS / Linux each
one is a link to the folder in `~/.codex/skills` and follows its changes; on Windows it
is a copy. Profiles that already exist are not touched; link or copy a skill into
`profiles/<name>/skills/` yourself.

### Profile names

Letters, digits, `-` and `_`, plus single `.`, `@` or `+` between them, so emails work (`me@example.com`). Names can't be only digits, because numbers are list positions. `home` and `default` are reserved.

## Logging in

- **Browser (default):** `cxp add <name>` runs `codex login`.
- **API key:** `cxp add <name> --api-key` asks for the key with masked input, so it never lands in your shell history or on a command line. From Git Bash you can pipe it in instead (piping inside PowerShell itself isn't picked up, it will still prompt):

  ```bash
  printenv OPENAI_API_KEY | cxp add ci --api-key
  ```

  `--key` is accepted as another spelling of `--api-key`.

If the login fails, the empty profile folder stays; remove it with `cxp remove <name>`.

## Permissions

`cxp perm` writes the two top-level keys Codex reads from `config.toml`, so it applies to plain `codex` after `cxp use` as well as `cxp run`.

| Mode | approval_policy | sandbox_mode | Meaning |
| --- | --- | --- | --- |
| `bypass` | `never` | `danger-full-access` | No prompts, no sandbox |
| `auto` | `on-request` | `workspace-write` | Sandboxed to the project, asks to go beyond |
| `readonly` | `on-request` | `read-only` | Asks before any write. `plan` is accepted as another name for it |

New profiles start from your `~/.codex/config.toml` (if present) and get `auto`. Use `cxp perm <name> bypass` if you want no prompts and no sandbox. Profiles created before this change keep the mode they had.

To use a different mode for one run only, put `--perm <mode>` straight after the name:

```powershell
cxp run work --perm readonly exec "review src/auth"
```

This passes the two keys to that run as `-c` overrides and does not change the saved mode.

## Switching

`cxp use` sets `CODEX_HOME` in the current terminal and saves it for new terminals and apps. `cxp use work --local` changes the current terminal only and leaves the saved setting alone.

`cxp run` does not switch anything, and its exit code is `codex`'s.

## Backup and restore

A backup is the account, not the data: each profile's `auth.json`, `config.toml`, and `cxp-note.txt` (if present). Sessions and history are not included. Backups go to `backups\<timestamp>`.

```powershell
cxp backup                          # every profile
cxp backup me@example.com           # one profile
cxp backups                         # list them
cxp restore                         # every profile, from the newest backup
cxp restore me@example.com          # one profile, from the newest backup that has it
cxp restore me@example.com 20261110-165357   # from a specific backup
```

Restoring brings back a removed profile, and first saves what it overwrites as a `<timestamp>-before-restore` backup. Those snapshots are only used when you name them by id.

### Logins only

Add `--creds` to save or restore **only the login** (`auth.json`): no config, note, pool setting or data.

```sh
cxp backup --creds                  # every profile's login -> backups/<timestamp>-creds
cxp backup me@example.com --creds -p   # one login, encrypted -> backups/<timestamp>-creds.enc
cxp restore me@example.com --creds  # put back just the login, from the newest backup that has the profile
cxp restore 20261112-021638-creds   # a lone id works too
```

`restore --creds` takes only `auth.json` from any backup, full or logins-only, and leaves the rest of the profile as it is. Codex keeps its login in `auth.json` unless `cli_auth_credentials_store` is set to `keyring` in `config.toml`; with the keyring there is no file to back up.

### Encrypted backups

Add `--password` to encrypt:

```powershell
cxp backup --password                # asks for a password twice (-p works too)
cxp restore me@example.com --password   # newest encrypted backup that has this profile
cxp restore 20261110-165355          # an encrypted id asks for the password by itself
```

An encrypted backup is a single `backups\<timestamp>.enc` file (AES-256-CBC with an HMAC-SHA256 check, key derived from the password with PBKDF2-SHA256). A wrong password or a damaged file is rejected before anything is restored. `cxp backups` lists these as `(encrypted)` and hides the profile names inside.

Notes:

- Without `--password`, `restore` only looks at plain backups. For an encrypted one, pass `--password` or its id.
- There is no password recovery.
- The `-before-restore` snapshots are not encrypted, same as the live `auth.json` they copy.
- For scripts, set `CXP_PASSWORD` to skip the prompt.

### Moving whole profile folders between Windows and macOS / Linux

Backups hold only the login and config. If you copy a whole profile folder (sessions, history and Codex's databases) from Windows to a Mac or back, Codex there stops with `failed to initialize sqlite state runtime`. Each Codex database records a checksum of every schema change it applied, and the Windows and macOS / Linux builds of Codex calculate those differently. Run this once after copying:

```sh
cxp repair                          # every profile, including home
cxp repair me@example.com           # one profile
```

`repair` has Codex make a fresh set of databases in a temporary folder and copies their checksums into your profiles. It only changes a database whose applied changes and tables already match the fresh one, so your threads and history are untouched. It leaves a database alone, and says so, if it was made by a different Codex version: update Codex on both machines and run it again. It needs `codex` and `sqlite3` on PATH (Windows: `winget install SQLite.SQLite`). Close Codex first.

## Account notes

```powershell
cxp note 2 "Work account - renew Nov 30"  # save or replace a single-line note
cxp note 2                              # read it
cxp note 2 --clear                      # remove it
```

Names and `default` work in place of the number. Notes appear in `list` and `usage`, including JSON output. Each note stays in its profile folder as `cxp-note.txt`, so renaming the profile keeps it and backups include it.

## Usage

`cxp usage` (all profiles) or `cxp usage <name>` fetches current account limits using each profile's existing Codex login. It starts a temporary `codex app-server`, calls `account/rateLimits/read`, then stops the server. It does not send a prompt or use model tokens. This uses the [official Codex app-server interface](https://learn.chatgpt.com/docs/app-server).

Token totals still come from the session logs under each profile's `sessions\` folder. Use `cxp usage --offline` (or `cxp usage <name> --offline`) to read only those logs without contacting the service. Both modes support `--json`.

```
# Profile                  Login   Plan   Limit                          Free Pool Today Last7d All  Sessions Note
1 home                     chatgpt promax 61% of 7d, resets Nov 11 15:57 39%  off  4.6M  15.8M  7.2B      224
2 charmander@irvingdinh.com chatgpt pro   2% of 7d, resets Nov 12 10:45  98%       2.2M  2.2M   2.2M        2 Work account
```

- **Tokens** are Codex's own per-session totals (cached input included), added up per profile. A session counts toward the day it was last active, so one that spans midnight lands entirely on its last day.
- **Limit** is fetched live by default. Each lookup has a 20-second response timeout. If a lookup fails, a warning goes to stderr and the script falls back to local logs, clearly marked `[local, <timestamp>]`. Offline mode also marks local limits this way. Once a recorded window's reset time has passed it shows `window 7d has reset since` instead of a stale percentage.
- API-key profiles show tokens but `n/a (API key)` for the limit; spend for those is on the OpenAI dashboard.
- Deleted or archived sessions are not counted.
- **Free** is the room left: 100 minus the fullest open window. **Pool** shows `off` for profiles `cxp pick` skips.
- Live lookups for all profiles run side by side, so the wait does not grow with each profile.
- **#** matches the profile number in `cxp list`, including when filtering to one profile. Use it directly with commands such as `cxp usage 2` or `cxp note 2`.

## Picking a profile

`cxp pick` prints the name of the profile with the most room left, so a script does not have to rank them itself:

```powershell
cxp pick                 # the best one
cxp pick -n 3            # the best three, one per line
cxp pick --json          # same objects as `cxp usage --json`, best first
cxp run (cxp pick) exec "summarise this repo"
```

It only considers profiles that are in the pool and `available` (see Scripting). API-key profiles come last, since their headroom is unknown. `--offline` ranks from local logs instead of live limits. If nothing qualifies it prints an error and exits with 1.

Every profile starts in the pool. Take one out to keep automation off it:

```powershell
cxp pool home off        # cxp pick never returns it
cxp pool home            # show
cxp pool home on
```

The pool only affects `cxp pick`. `cxp use` and `cxp run` still work on any profile. The setting is kept in the profile folder as `cxp-pool-off` (for `home`, as `profiles\.home-pool-off`), and backups include it.

## Scripting

`cxp list --json` and `cxp usage [name] --json` print JSON only (always an array, even for one profile), so other tools can consume them. Errors still go to stderr with a non-zero exit code.

```bash
cxp usage --json | jq '.[] | {profile, week: .tokens.last_7d, pct: .limits[0].used_percent}'
```

`list`: `number`, `name`, `active`, `default`, `path` (the profile's `CODEX_HOME`), `permissions`, `note` (empty string when unset), `pool`.

`usage` also includes `number` (the same index as `list`) and `note` (empty string when unset).

`usage`: `profile`, `login` (`chatgpt` / `apikey`), `plan`, `limits_as_of`, `limits_source` (`live`, `local`, `unavailable`, or `not_applicable` for API keys), `limits_error` (null on success), `sessions`, `tokens` (`today`, `last_7d`, `all`, raw integers), and `limits`, a list of windows with `window_minutes`, `used_percent`, `resets_at` (UTC ISO 8601) and `reset_passed`. `limits_as_of` is the live fetch time or the local log timestamp, depending on `limits_source`. `limits` is empty for API-key profiles and profiles with no available limit. When `reset_passed` is true the percentage is out of date.

`usage` also has five fields with the same names and meaning as in `ccp usage --json` (the Claude Code sibling of this tool), so one script can rank Claude and Codex profiles together: `number`, `path`, `pool`, `headroom_percent` (integer, 100 minus the fullest open window; `null` when the limits are unknown) and `available` (`true` when limits were read, live or local, and there is room left, or for an API-key profile).

Pick a profile's `path` from `list` to run Codex under it directly with `CODEX_HOME`.

## Environment variables

| Variable | Effect |
| --- | --- |
| `CODEX_HOME` | Set by `cxp use` (per terminal, and saved for new ones unless `--local`). Unset means `home` |
| `CXP_ROOT` | Keep `profiles/` and `backups/` somewhere else instead of next to the script |
| `CXP_PASSWORD` | Backup password, to skip the prompt |

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\usage.ps1
```

```sh
bash tests/cxp.bash        # macOS / Linux
```

The tests use a temporary `CXP_ROOT` and a fake `codex`, so they do not touch your profiles or log in.

## Files

```
cxp.ps1      the implementation on Windows
cxp.bash     the implementation on macOS / Linux
cxp.sh       bash / zsh wrapper (a shell function, so `use` can set CODEX_HOME)
tests/       integration tests (usage.ps1 on Windows, cxp.bash on macOS / Linux)
profiles\    one folder per profile (git-ignored)
backups\     backups (git-ignored)
```

Profiles and backups hold logins. Keep the folder out of version control and cloud sync.
