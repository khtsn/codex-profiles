"""Isolated relocation tests: no real profiles, registry, or CLI network calls."""
import importlib.util
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('repair', Path(__file__).resolve().parents[1] / 'repair.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='profile-repair-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'new folder'
        self.old = self.base / 'missing old folder'
        self.home = self.base / 'shell home'
        self.home.mkdir()
        self.profile = self.root / 'profiles' / 'work@example.com'
        self.profile.mkdir(parents=True)

    def plan(self, tool, **kwargs):
        return repair.plan(tool, self.root, self.root, self.home,
                           kwargs.get('environ', {}), kwargs.get('user', {}),
                           kwargs.get('explicit', [str(self.old)]))

    def write_json(self, relative, data):
        path = self.profile / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        return path

    def test_claude_preview_backup_apply_and_repeat(self):
        old_profile = self.old / 'profiles' / self.profile.name
        cfg = self.write_json('settings.json', {'hooks': {'cmd': f'powershell -File "{old_profile}\\hooks\\state.ps1"'},
                                               'env': {'API_KEY': 'secret-unchanged'}, 'note': 'Tiếng Việt'})
        original = cfg.read_bytes()
        unrelated = self.write_json('.claude.json', {'history': str(old_profile)})
        sibling = str(self.old) + '-other\\profiles\\work'
        market = self.write_json('plugins/known_marketplaces.json', {'a': {'installLocation': str(old_profile / 'plugins')}, 'unrelated': sibling})
        bashrc = self.home / '.bashrc'
        bashrc.write_text(f'# keep\nsource "{self.old.as_posix()}/ccp.sh"\n', encoding='utf-8')
        env = {'CLAUDE_CONFIG_DIR': str(old_profile), 'Path': str(self.old) + ';unchanged;unchanged'}
        result = self.plan('ccp', environ=env, user=env)
        edits, dbs, changes, warnings, _ = result
        self.assertEqual(cfg.read_bytes(), original)
        self.assertFalse((self.root / 'backups').exists())
        self.assertEqual(changes[('User', 'CLAUDE_CONFIG_DIR')], str(self.profile))
        self.assertEqual(changes[('User', 'Path')], str(self.root) + ';unchanged;unchanged')
        backup = self.root / 'backups' / 'test'
        repair.apply_files(edits, dbs, backup)
        updated = json.loads(cfg.read_text(encoding='utf-8'))
        self.assertIn(str(self.profile), updated['hooks']['cmd'])
        self.assertEqual(updated['env']['API_KEY'], 'secret-unchanged')
        self.assertEqual(updated['note'], 'Tiếng Việt')
        self.assertEqual(json.loads(market.read_text())['unrelated'], sibling)
        self.assertEqual(json.loads(unrelated.read_text())['history'], str(old_profile))
        self.assertIn(self.root.as_posix() + '/ccp.sh', bashrc.read_text())
        manifest = json.loads((backup / 'files.json').read_text())
        saved = next(item for item in manifest if item['original'] == str(cfg))
        self.assertEqual((backup / saved['backup']).read_bytes(), original)
        edits, dbs, changes, _, _ = self.plan('ccp', environ={'CLAUDE_CONFIG_DIR': str(self.profile)})
        self.assertEqual((edits, dbs, changes), ([], [], {}))

    def test_codex_sqlite_wal_missing_transcripts_and_trust(self):
        old_profile = self.old / 'profiles' / self.profile.name
        self.write_json('hooks.json', {'hooks': {'command': f'powershell "{old_profile}\\hook.ps1"'}})
        cfg = self.profile / 'config.toml'
        cfg.write_text(f'model = "keep"\n[hooks.state.\'{old_profile}\\hooks.json:session_start:0:0\']\ntrusted_hash = "old"\n'
                       f'[hooks.state.\'{self.profile}\\hooks.json:session_start:0:0\']\ntrusted_hash = "current"\n', encoding='utf-8')
        session = self.profile / 'sessions' / 'existing.jsonl'
        session.parent.mkdir()
        session.write_text('history remains unchanged', encoding='utf-8')
        db_path = self.profile / 'state_5.sqlite'
        db = sqlite3.connect(db_path)
        self.addCleanup(db.close)
        db.execute('pragma journal_mode=wal')
        db.execute('create table threads (id text primary key, rollout_path text, cwd text)')
        old_session = str(old_profile / 'sessions' / session.name)
        missing = str(old_profile / 'sessions' / 'missing.jsonl')
        db.executemany('insert into threads values (?,?,?)', [('a', old_session, str(self.old)), ('b', missing, 'keep')])
        db.commit()
        edits, databases, env, warnings, _ = self.plan('cxp')
        self.assertEqual(len(databases[0][1]), 1)
        self.assertEqual(len(warnings), 1)
        backup = self.root / 'backups' / 'test'
        repair.apply_files(edits, databases, backup)
        rows = db.execute('select rollout_path, cwd from threads order by id').fetchall()
        self.assertEqual(rows, [(str(session), str(self.old)), (missing, 'keep')])
        with closing(sqlite3.connect(backup / 'db-0-state_5.sqlite')) as saved:
            self.assertEqual(saved.execute('select rollout_path from threads where id="a"').fetchone()[0], old_session)
        parsed = repair.tomllib.loads(cfg.read_text())
        self.assertEqual(len(parsed['hooks']['state']), 1)
        self.assertEqual(parsed['model'], 'keep')
        self.assertEqual(session.read_text(), 'history remains unchanged')
        again = self.plan('cxp')
        self.assertEqual((again[0], again[1]), ([], []))

    def test_discovery_existing_source_requires_explicit_selection(self):
        old_profile = self.old / 'profiles' / self.profile.name
        self.write_json('settings.json', {'path': str(old_profile / 'hook.ps1')})
        self.assertEqual(len(self.plan('ccp', explicit=[])[0]), 1)
        self.old.mkdir()
        self.assertEqual(self.plan('ccp', explicit=[])[0], [])
        self.assertEqual(len(self.plan('ccp')[0]), 1)

    def test_invalid_json_prevents_all_edits(self):
        path = self.write_json('settings.json', {'path': str(self.old / 'profiles' / self.profile.name)})
        broken = self.profile / 'plugins' / 'known_marketplaces.json'
        broken.parent.mkdir()
        broken.write_text('{broken')
        original = path.read_bytes()
        with self.assertRaises(json.JSONDecodeError):
            self.plan('ccp')
        self.assertEqual(path.read_bytes(), original)

    def test_changed_file_refuses_apply_before_backup(self):
        path = self.write_json('settings.json', {'path': str(self.old / 'profiles' / self.profile.name)})
        edits, databases, _, _, _ = self.plan('ccp')
        path.write_text('{}')
        backup = self.root / 'backups' / 'test'
        with self.assertRaises(ValueError):
            repair.apply_files(edits, databases, backup)
        self.assertFalse(backup.exists())

    def test_forward_slash_and_case_insensitive_prefix_boundary(self):
        self.assertEqual(repair.relocated('f:/OLD/profiles/a', ['F:\\old'], 'D:\\new'), 'D:/new/profiles/a')
        self.assertEqual(repair.relocated('F:\\older\\profiles\\a', ['F:\\old'], 'D:\\new'), 'F:\\older\\profiles\\a')

    def test_main_apply_saves_environment_and_preserves_registry_type(self):
        old_profile = self.old / 'profiles' / self.profile.name
        self.write_json('settings.json', {'hook': str(old_profile / 'hook.ps1')})
        stored = {'Path': (str(self.old) + ';%KEEP_ME%', 2), 'CLAUDE_CONFIG_DIR': (str(old_profile), 1)}
        writes = []
        class Key:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
        class Registry:
            HKEY_CURRENT_USER = 1
            KEY_SET_VALUE = 2
            REG_SZ = 1
            @staticmethod
            def OpenKey(*args):
                return Key()
            @staticmethod
            def QueryValueEx(key, name):
                if name not in stored:
                    raise FileNotFoundError(name)
                return stored[name]
            @staticmethod
            def SetValueEx(key, name, reserved, kind, value):
                writes.append((name, kind, value))
        output = self.base / 'process-changes.json'
        argv = ['repair.py', '--tool', 'ccp', '--root', str(self.root), '--script-root', str(self.root),
                '--from', str(self.old), '--apply', '--environment-output', str(output)]
        env = {'CLAUDE_CONFIG_DIR': str(old_profile), 'PATH': str(self.old)}
        with patch.dict('sys.modules', {'winreg': Registry}), patch.object(repair.sys, 'argv', argv), \
                patch.dict(repair.os.environ, env, clear=True), patch.object(Path, 'home', return_value=self.home), \
                patch('builtins.print'):
            repair.main()
        self.assertIn(('Path', 2, str(self.root) + ';%KEEP_ME%'), writes)
        self.assertIn(('CLAUDE_CONFIG_DIR', 1, str(self.profile)), writes)
        self.assertEqual(json.loads(output.read_text())['CLAUDE_CONFIG_DIR'], str(self.profile))
        backups = list((self.root / 'backups').glob('repair-*'))
        saved_env = json.loads((backups[0] / 'environment.json').read_text())
        self.assertEqual(saved_env['CLAUDE_CONFIG_DIR'], str(old_profile))


if __name__ == '__main__':
    unittest.main()
