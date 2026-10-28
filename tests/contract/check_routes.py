"""Check literal application routes against the one public operation registry."""
from pathlib import Path
import re
import yaml

root=Path(__file__).resolve().parents[2]
api=yaml.safe_load((root/'openapi.yaml').read_text(encoding='utf-8'))
expected={(method.upper(),path) for path,verbs in api['paths'].items() for method,op in verbs.items()
          if isinstance(op,dict) and 'operationId' in op}
actual=[]
for source in (root/'apps/api/src/modules').rglob('routes.ts'):
    for method,path in re.findall(r"app\.(get|post|put|patch|delete)\('(/api/v1[^']*)'",source.read_text(encoding='utf-8')):
        actual.append((method.upper(),re.sub(r':(\w+)',r'{\1}',path.removeprefix('/api/v1'))))
assert len(actual)==len(set(actual)), 'Duplicate routes'
assert set(actual)==expected, f'Missing: {expected-set(actual)}; extra: {set(actual)-expected}'
assert len(expected)==24, 'Unexpected public scope change'
print('Application routes match all 24 public operations')
