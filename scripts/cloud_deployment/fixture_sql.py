#!/usr/bin/env python3
"""Print the exact cloud migration statement for a disposable SQL fixture only."""
import subprocess
import sys

from bridge import ROOT
import migration

sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
prepared = migration.prepare(ROOT / sys.argv[1], sha)
print('CREATE SCHEMA IF NOT EXISTS supabase_migrations;')
print('CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations('
      'version text PRIMARY KEY,name text,statements text[]);')
print(prepared['query'])
print("SELECT 'CLOUD_FIXTURE_SOURCE_HISTORY=PASS' WHERE EXISTS(SELECT 1 FROM "
      'supabase_migrations.schema_migrations WHERE version=' + migration.literal(prepared['version']) +
      ' AND encode(sha256(convert_to(statements[1],\'UTF8\')),\'hex\')=' +
      migration.literal(prepared['sourceHash']) + ');')
