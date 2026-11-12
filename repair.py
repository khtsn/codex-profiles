"""Relocation repair shared by the ccp/cxp wrappers. Python 3.11+, stdlib only."""
import argparse
from contextlib import closing, contextmanager
import datetime
import json
import ntpath
import os
from pathlib import Path
import re
import sqlite3
import sys
import tomllib


def normalized(value):
    return ntpath.normpath(value.replace('/', '\\')).casefold()


def relocated(value, sources, destination):
    """Replace only a complete root prefix; support command strings and Bash paths."""
    for source in sorted(sources, key=len, reverse=True):
        variants = [(source.replace('/', '\\'), str(destination).replace('/', '\\')),
                    (source.replace('\\', '/'), str(destination).replace('\\', '/'))]
        for old, new in variants:
            value = re.sub(re.escape(old.rstrip('\\/')) + r'(?=[\\/])',
                           lambda m: new.rstrip('\\/'), value, flags=re.I)
    return value


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def map_strings(value, transform):
    if isinstance(value, str):
        return transform(value)
    if isinstance(value, dict):
        return {k: map_strings(v, transform) for k, v in value.items()}
    if isinstance(value, list):
        return [map_strings(v, transform) for v in value]
    return value


def discover(values, names, destination):
    found = set()
    for value in values:
        for m in re.finditer(r'([A-Za-z]:[\\/][^"\r\n<>|]*?)[\\/]profiles[\\/]([^\\/"\s]+)', value):
            if m[2] in names and normalized(m[1]) != normalized(str(destination)):
                # An existing root might belong to another installation. Require --from.
                if not Path(m[1]).exists():
                    found.add(m[1])
    return found


@contextmanager
def connect_readonly(path):
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
        yield db


def database_rows(path):
    with connect_readonly(path) as db:
        cols = [r[1] for r in db.execute('pragma table_info(threads)')]
        if 'rollout_path' not in cols or 'id' not in cols:
            raise ValueError(f'Unsupported session database schema: {path}')
        return db.execute('select id, rollout_path from threads').fetchall()


def plan(tool, root, script_root, home, environ, user, explicit):
    variable = 'CLAUDE_CONFIG_DIR' if tool == 'ccp' else 'CODEX_HOME'
    profile_root = root / 'profiles'
    profiles = sorted(p for p in profile_root.iterdir() if p.is_dir()) if profile_root.exists() else []
    names = {p.name for p in profiles}
    json_files, toml_files, databases, values = [], [], [], []
    relatives = ['settings.json', 'plugins/known_marketplaces.json', 'plugins/installed_plugins.json'] if tool == 'ccp' else ['hooks.json']
    for profile in profiles:
        for relative in relatives:
            path = profile / relative
            if path.exists():
                raw = path.read_bytes()
                data = json.loads(raw.decode('utf-8-sig'))
                json_files.append((path, raw, data))
                values.extend(strings(data))
        if tool == 'cxp':
            cfg = profile / 'config.toml'
            if cfg.exists():
                raw = cfg.read_bytes()
                data = tomllib.loads(raw.decode('utf-8-sig'))
                toml_files.append((cfg, raw))
                values.extend(strings(data))
                values.extend(data.get('hooks', {}).get('state', {}).keys())
            for path in profile.glob('state_*.sqlite'):
                rows = database_rows(path)
                databases.append((path, rows))
                values.extend(v for _, v in rows if v)
    values.extend(v for v in (environ.get(variable), user.get(variable)) if v)
    sources = discover(values, names, root) | set(explicit)
    sources = {s.rstrip('\\/') for s in sources if normalized(s) != normalized(str(root))}
    # Only references beneath profiles/ are configuration data owned by this tool.
    old_profiles = [s + '\\profiles' for s in sources]
    transform = lambda s: relocated(s, old_profiles, profile_root)
    edits, db_edits, warnings = [], [], []
    for path, raw, data in json_files:
        changed = map_strings(data, transform)
        if changed != data:
            edits.append((path, raw, (json.dumps(changed, indent=2, ensure_ascii=False) + '\n').encode('utf-8')))
    for path, raw in toml_files:
        original = raw.decode('utf-8-sig')
        text = original
        # Trust hashes cover commands. Remove affected trust records so changed hooks
        # must be trusted again, rather than carrying approval to a new command.
        sections = re.split(r'(?m)(?=^\[)', text)
        sections = [s for s in sections if not (s.startswith('[hooks.state.') and
                    transform(s.splitlines()[0].replace('\\\\', '\\')) != s.splitlines()[0].replace('\\\\', '\\'))]
        text = ''.join(sections)
        for source in sorted(sources, key=len, reverse=True):
            for old, new in [(source.replace('\\', '/') + '/profiles/', str(profile_root).replace('\\', '/') + '/'),
                             (source.replace('/', '\\') + '\\profiles\\', str(profile_root) + '\\')]:
                for escape in (False, True):
                    a, b = (old.replace('\\', '\\\\'), new.replace('\\', '\\\\')) if escape else (old, new)
                    text = re.sub(re.escape(a), lambda m: b, text, flags=re.I)
        if text != original:
            tomllib.loads(text)
            edits.append((path, raw, text.encode('utf-8')))
    for path, rows in databases:
        changes = []
        for ident, old in rows:
            if not old:
                continue
            new = transform(old)
            if new != old:
                if Path(new).is_file():
                    changes.append((new, ident, old))
                else:
                    warnings.append(f'Missing transcript; left unchanged: {new}')
        if changes:
            db_edits.append((path, changes))
    env_changes = {}
    for scope, values_ in [('Process', environ), ('User', user)]:
        old = values_.get(variable, '')
        new = transform(old)
        if new != old and Path(new).is_dir():
            env_changes[(scope, variable)] = new
    # Shell startup entries are independent of CCP_ROOT/CXP_ROOT (data location).
    script_sources = set(explicit)
    if normalized(str(root)) == normalized(str(script_root)):
        script_sources.update(sources)
    for filename in ('.bashrc', '.bash_profile', '.bash_login', '.profile'):
        path = home / filename
        if not path.exists():
            continue
        raw = path.read_bytes()
        text = raw.decode('utf-8-sig')
        pattern = r'(?m)^(\s*(?:source|\.)\s+)(["\'])([^"\'\r\n]+/' + tool + r'\.sh)\2(\s*(?:#.*)?)$'
        def shell_replace(m):
            old = m[3][:-len('/' + tool + '.sh')]
            windows_old = re.sub(r'^/([a-zA-Z])/', lambda x: x[1] + ':/', old)
            if normalized(windows_old) == normalized(str(script_root)):
                return m[0]
            if Path(windows_old).exists() and not any(normalized(windows_old) == normalized(s) for s in explicit):
                warnings.append(f'Existing shell installation left unchanged: {windows_old}; use --from to select it')
                return m[0]
            script_sources.add(windows_old)
            return m[1] + m[2] + script_root.as_posix() + '/' + tool + '.sh' + m[2] + m[4]
        updated = re.sub(pattern, shell_replace, text)
        if updated != text:
            edits.append((path, raw, updated.encode('utf-8')))
    for scope, values_ in [('Process', environ), ('User', user)]:
        old = values_.get('Path', '')
        parts = old.split(';') if old else []
        new_parts = []
        for part in parts:
            is_old = any(normalized(part) == normalized(s) for s in script_sources)
            # Recognize the standard folder name only when it no longer exists.
            is_old |= ntpath.basename(part).casefold() == ('claude-profiles' if tool == 'ccp' else 'codex-profiles') and not Path(part).exists()
            part = str(script_root) if is_old else part
            if normalized(part) != normalized(str(script_root)) or part not in new_parts:
                new_parts.append(part)
        new = ';'.join(new_parts)
        if new != old:
            env_changes[(scope, 'Path')] = new
    return edits, db_edits, env_changes, warnings, sources


def apply_files(edits, databases, backup):
    # Refuse stale previews before writing anything; all configuration was parsed in plan().
    for path, old, _ in edits:
        if path.read_bytes() != old:
            raise ValueError(f'File changed during repair: {path}')
    backup.mkdir(parents=True, exist_ok=False)
    manifest = []
    for i, (path, old, _) in enumerate(edits):
        saved = backup / f'{i}-{path.name}'
        saved.write_bytes(old)
        manifest.append({'original': str(path), 'backup': saved.name})
    # SQLite backup includes committed WAL contents; never copy a live .sqlite file alone.
    for i, (path, changes) in enumerate(databases):
        saved = backup / f'db-{i}-{path.name}'
        with connect_readonly(path) as src, closing(sqlite3.connect(saved)) as dst:
            src.backup(dst)
        manifest.append({'original': str(path), 'backup': saved.name})
    (backup / 'files.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    for path, _, new in edits:
        path.write_bytes(new)
    for path, changes in databases:
        with closing(sqlite3.connect(path, timeout=2)) as db, db:
            db.execute('begin immediate')
            for new, ident, old in changes:
                cursor = db.execute('update threads set rollout_path=? where id=? and rollout_path=?', (new, ident, old))
                if cursor.rowcount != 1:
                    raise ValueError(f'Session changed during repair: {path}; database transaction rolled back')


def main():
    parser = argparse.ArgumentParser(prog='ccp/cxp repair', description='Preview relocation repairs; --apply writes with backups. Close Claude/Codex before applying.')
    parser.add_argument('--tool', choices=['ccp', 'cxp'], required=True, help=argparse.SUPPRESS)
    parser.add_argument('--root', type=Path, required=True, help=argparse.SUPPRESS)
    parser.add_argument('--script-root', type=Path, required=True, help=argparse.SUPPRESS)
    parser.add_argument('--from', dest='sources', action='append', default=[], help='Old whole-folder location; repeat for multiple moves')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--paths', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--environment-output', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
        user, kinds = {}, {}
        for name in ('Path', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR'):
            try:
                user[name], kinds[name] = winreg.QueryValueEx(key, name)
            except FileNotFoundError:
                pass
    environ = dict(os.environ)
    environ['Path'] = os.environ.get('PATH', '')
    root, script_root = args.root.resolve(), args.script_root.resolve()
    for source in args.sources:
        if not ntpath.isabs(source) or not ntpath.splitdrive(source)[1].strip('\\/'):
            parser.error('--from must be an absolute folder path, not a drive root')
    edits, databases, env, warnings, sources = plan(args.tool, root, script_root, Path.home(), environ, user, args.sources)
    for source in sorted(sources):
        print(f'Root: {source} -> {root}')
    for path, _, _ in edits:
        print(f'File: {path}')
    for path, changes in databases:
        print(f'Sessions: {path} ({len(changes)} paths)')
    for (scope, name), value in env.items():
        print(f'{scope} environment: {name} -> {value}')
    for warning in warnings:
        print('Unresolved: ' + warning)
    if not (edits or databases or env):
        print('No repairable references found. Use --from OLD_FOLDER if automatic detection missed a location.')
        return
    if not args.apply:
        print('Preview only. Close Claude/Codex, then repeat with --apply. Hook trust may need approval again.')
        return
    backup = root / 'backups' / ('repair-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    apply_files(edits, databases, backup)
    (backup / 'environment.json').write_text(json.dumps({name: user.get(name) for scope, name in env if scope == 'User'}, indent=2), encoding='utf-8')
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment', 0, winreg.KEY_SET_VALUE) as key:
        for (scope, name), value in env.items():
            if scope == 'User':
                winreg.SetValueEx(key, name, 0, kinds.get(name, winreg.REG_SZ), value)
    if args.environment_output:
        args.environment_output.write_text(json.dumps({name: value for (scope, name), value in env.items() if scope == 'Process'}), encoding='utf-8')
    print(f'Applied. Backups: {backup}')
    print('Restart terminals and apps. Reapprove relocated hooks when prompted.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'repair: {error}', file=sys.stderr)
        sys.exit(1)
