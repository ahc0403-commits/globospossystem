"""Prove rollback refuses beverage history without modifying its schema or data."""
import pathlib
import subprocess
import sys

port, root = sys.argv[1:3]
command = ["psql", "-X", "-h", "127.0.0.1", "-p", port, "-d", "postgres",
           "-v", "ON_ERROR_STOP=1", "-Atq"]
rollback = pathlib.Path(root) / "scripts/rollback_procurement_pr_account.sql"
fixture = """
BEGIN;
INSERT INTO public.inventory_purchase_requests(
 restaurant_id,source,requested_delivery_date,reason,created_actor,purchase_category,status)
VALUES(test_uuid(101),'pos',current_date,'Rollback safety fixture','{}','beverage','cancelled');
"""
result = subprocess.run(command, input=fixture + rollback.read_text(),
                        text=True, capture_output=True)
assert result.returncode != 0
assert "PROCUREMENT_PR_ROLLBACK_REQUIRES_ROLL_FORWARD:beverage_history_exists" in result.stderr
verify = """
SELECT to_regclass('public.procurement_requests_store_created') IS NOT NULL
 AND position('choices=1' IN pg_get_functiondef(
 'public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))>0
 AND NOT EXISTS(SELECT 1 FROM public.inventory_purchase_requests
 WHERE reason='Rollback safety fixture');
"""
result = subprocess.run(command, input=verify, text=True, capture_output=True,
                        check=True)
assert result.stdout.strip() == "t"
print("PASS: cancelled beverage history blocks rollback; failed rollback preserves schema and rolls back only its fixture")
