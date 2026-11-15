#!/usr/bin/env python3
"""Capture storefront hashes; replace operations.json only on a complete capture."""
import datetime
import json
from pathlib import Path
import re
import subprocess
import tempfile

scripts = Path(__file__).resolve().parent
root = scripts.parents[3]
target = root / 'packages/galaxus-mcp/operations.json'
current = json.loads(target.read_text())
work = Path(tempfile.mkdtemp(prefix='galaxus-hashes-'))
session = work.name
code = scripts.joinpath('capture.js').read_text().replace(
    '__OPERATIONS__', json.dumps(list(current['operations']))
)
work.joinpath('capture.js').write_text(code)


def cli(*args):
    result = subprocess.run(
        ['playwright-cli', f'-s={session}', *args], cwd=work,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if result.returncode or '### Error' in result.stdout:
        raise RuntimeError(result.stdout)
    return result.stdout


print(f'Capture artifacts: {work}', flush=True)
try:
    cli('open', '--headed')
    output = cli('--raw', 'run-code', f'--filename={work / "capture.js"}')
    work.joinpath('capture.json').write_text(output)
    capture = json.loads(output)
finally:
    try:
        cli('close')
    except RuntimeError as error:
        print(f'Browser cleanup failed: {error}')

for error in capture['errors']:
    print(f'Warning: {error}')
missing = [name for name in current['operations']
           if not re.fullmatch(r'[a-f0-9]{32}', capture['operations'].get(name, ''))]
if missing or not capture.get('clientVersion'):
    if missing:
        print('Missing hashes: ' + ', '.join(missing))
    if not capture.get('clientVersion'):
        print('Missing storefront client version')
    print(f'Left {target} unchanged. Investigate using {work / "capture.json"}.')
    raise SystemExit(1)

changed = sum(current['operations'][name] != capture['operations'][name]
              for name in current['operations'])
current['operations'] = {name: capture['operations'][name] for name in current['operations']}
current['_capturedAt'] = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
current['_clientVersion'] = capture['clientVersion']
target.write_text(json.dumps(current, indent=2) + '\n')
print(f'Captured all {len(current["operations"])} hashes; {changed} changed. Updated {target}.')
