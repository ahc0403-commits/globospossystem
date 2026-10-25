#!/usr/bin/env python3
"""Exercise the exact historical guard on a fully replayed local empty DB."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--container', required=True)
args = parser.parse_args()
if not re.fullmatch(r'supabase_db_pos_history_followup_20261025_r\d+', args.container):
    raise SystemExit('Only an owned local history-replay database is allowed')
inspect = json.loads(subprocess.check_output(['docker', 'inspect', args.container]))[0]
for network in inspect['NetworkSettings']['Networks']:
    if not json.loads(subprocess.check_output(['docker', 'network', 'inspect', network]))[0]['Internal']:
        raise SystemExit('The historical guard fixture requires internal-only networking')
base = ['docker', 'exec', '-i', args.container, 'psql', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1']
probe = subprocess.check_output(base + ['-c', "select json_build_object('stores',(select count(*) from public.restaurants),'auth',(select count(*) from auth.users),'cron',current_setting('cron.launch_active_jobs'));"], text=True)
if json.loads(probe) != {'stores': 0, 'auth': 0, 'cron': 'off'}:
    raise SystemExit('An empty local fully replayed database is required')
source = root / 'supabase/migrations/20260723070000_photo_ops_inventory_cleanup_sales_range.sql'
match = re.search(r'\bDO \$\$[\s\S]+?\$\$;', source.read_text())
if not match:
    raise SystemExit('Actual historical guard block not found')
guard = match.group()
print('ACTUAL_GUARD_SHA256=' + hashlib.sha256(guard.encode()).hexdigest(), flush=True)
test = root / 'supabase/tests/fresh_history_photo_cleanup_guard.test.sql'
result = subprocess.run(base + ['-v', 'guard_sql=' + guard], input=test.read_text(), text=True, capture_output=True)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
passed = re.findall(r'^ok \d+', result.stdout, re.M)
if result.returncode or len(passed) != 9 or re.search(r'^not ok |#\s*skip', result.stdout, re.M | re.I):
    raise SystemExit(1)
