"""Verify the exact release ZIP against its clean, committed source checkout."""
import hashlib
import json
import runpy
import subprocess
import sys
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
archive = Path(sys.argv[1]).resolve()
baseline = '81ddcb159dd8de999e7e743aa576b25c8246fddc'
def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args]).decode().strip()

assert not git('status', '--porcelain'), 'Release checkout is not clean'
revision = git('rev-parse', 'HEAD')
packager = runpy.run_path(str(root/'tools/package_release.py'))
paths = packager['release_files']()
expected = {p.relative_to(root).as_posix(): p for p in paths}
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None, 'CRC failure'
    assert len(bundle.namelist()) == len(set(bundle.namelist())), 'Duplicate ZIP entry'
    assert set(bundle.namelist()) == set(expected), 'Unexpected ZIP inventory'
    for name, path in expected.items():
        assert bundle.read(name) == path.read_bytes(), 'Source mismatch: '+name
        assert not name.startswith(('tools/', 'tests/', '.git/')), 'Development file included'
    manifest = json.loads(bundle.read('manifest.json'))
    assert manifest['version'] == '1.1.0'
    assert manifest['games'] == ['gen1', 'gen2']

runtime = git('diff', '--name-only', baseline, 'HEAD', '--', 'lib', 'compat',
              'bootstrap', 'main.lua', 'weather_main.lua').splitlines()
assert set(runtime) == {'lib/QuestStorm.lua', 'lib/QuestStormBolt.lua', 'compat/Controls.lua'}, runtime
assert not git('diff', '--name-only', baseline, 'HEAD', '--', 'assets',
               'SOURCE_PROVENANCE.json', 'THIRD_PARTY_NOTICES.md',
               'release-review/AUDIO-SOURCES.json', 'release-review/AUDIO-PROVENANCE.json'), 'Provenance/assets changed'
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
receipt_path = archive.parent/'RELEASE-RECEIPT.json'
receipt = json.loads(receipt_path.read_text())
assert receipt['sha256'] == digest and receipt['fileCount'] == len(expected)
receipt.update(status='EXACT-ARTIFACT AUDIT PASSED; DEVICE LIMITATIONS DISCLOSED',
               sourceCommit=revision, baselineCommit=baseline,
               runtimeChanges=runtime, sourceInventoryVerified=True,
               provenanceAndAssetsUnchanged=True)
receipt_path.write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
(archive.parent/'SHA256SUMS.txt').write_text(digest+'  '+archive.name+'\n', encoding='utf-8')
print(json.dumps({'audit':'PASS','commit':revision,'files':len(expected),'sha256':digest}))
