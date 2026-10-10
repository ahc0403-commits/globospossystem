#!/usr/bin/env python3
"""Bind only the translation dispatcher to the existing Vault scheduler secret.

Secret values stay in subprocess pipes and memory, never files, argv or output.
The official release runner invokes this after its source and test gates.
"""
import hashlib
import json
import re
import subprocess
from pathlib import Path

PROJECT_REF = "ynriuoomotxuwhuxxmhj"
SECRET_NAME = "DIRECT_ORDER_TRANSLATION_CRON_SECRET"


def run(arguments, input_text=None):
    result = subprocess.run(arguments, input=input_text, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit("Translation scheduler secret synchronization failed; no secret output retained.")
    return result.stdout


def main():
    linked = Path("supabase/.temp/project-ref").read_text().strip()
    if linked != PROJECT_REF:
        raise SystemExit("Translation scheduler requires the pinned POS project.")
    query = "SELECT decrypted_secret AS value FROM vault.decrypted_secrets WHERE name IN ('cron_secret','app.settings.cron_secret') ORDER BY (name='cron_secret') DESC LIMIT 1"
    rows = json.loads(run(["supabase", "db", "query", "--linked", "--agent=no", "-o", "json", query]))
    value = rows[0].get("value", "") if len(rows) == 1 else ""
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,512}", value):
        raise SystemExit("Translation scheduler Vault secret is missing or invalid.")
    existing = json.loads(run(["supabase", "secrets", "list", "--project-ref", PROJECT_REF, "-o", "json"]))
    current = next((x for x in existing if x.get("name") == SECRET_NAME), {})
    digest = hashlib.sha256(value.encode()).hexdigest()
    if current.get("value") != value and current.get("digest") != digest:
        run(["supabase", "secrets", "set", "--project-ref", PROJECT_REF, "--env-file", "/dev/stdin"], f"{SECRET_NAME}={value}\n")
    print("Translation scheduler secret synchronized with Vault; values not printed.")


if __name__ == "__main__":
    main()
