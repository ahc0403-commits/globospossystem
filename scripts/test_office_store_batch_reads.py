#!/usr/bin/env python3
"""Validate the POS-side read contract in a disposable DB, never a live POS DB."""
import argparse
import re
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--container', required=True)
p.add_argument('--original-contract', type=Path, required=True)
p.add_argument('--purchase-contract', type=Path, required=True)
p.add_argument('--purchase-detail-contract', type=Path, required=True)
p.add_argument('--procurement-snapshot-contract', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if not a.container.startswith('office-n1-'):
    p.error('Use an isolated office-n1-* container')
root = Path(__file__).resolve().parents[1]
subprocess.run(['docker','exec',a.container,'dropdb','-U','supabase_admin','--if-exists','office_pos_batch_test'],check=True)
subprocess.run(['docker','exec',a.container,'createdb','-U','supabase_admin','office_pos_batch_test'],check=True)
cmd = ['docker','exec','-i',a.container,'psql','-X','-U','supabase_admin','-d','office_pos_batch_test','-v','ON_ERROR_STOP=1','-At']
source = a.original_contract.read_text()
start = source.index('create or replace function public.office_get_inventory_nxt_snapshot(')
end = source.index('\n$$;',start)+4
purchase = a.purchase_contract.read_text()
purchase_start = purchase.index('CREATE OR REPLACE FUNCTION public.office_get_inventory_purchase_orders(')
purchase_end = purchase.index('SET search_path = public, auth;', purchase_start) + len('SET search_path = public, auth;')
detail_source = a.purchase_detail_contract.read_text()
detail_start = detail_source.index('CREATE OR REPLACE FUNCTION public.office_get_inventory_purchase_order_detail(')
detail_end = detail_source.index('SET search_path = public, auth;', detail_start) + len('SET search_path = public, auth;')
snapshot_source = a.procurement_snapshot_contract.read_text()
snapshot_start = snapshot_source.index('CREATE FUNCTION public.procurement_order_snapshot(')
snapshot_end = snapshot_source.index('END $$;', snapshot_start) + len('END $$;')
fixture = '''
create schema if not exists extensions;
create schema if not exists auth;
create function auth.role() returns text language sql stable as $$select current_setting('request.jwt.claim.role', true)$$;
create function public.can_access_inventory_purchase_store(uuid) returns boolean language sql stable as $$select true$$;
create function public.procurement_actor(uuid,jsonb) returns jsonb language sql stable as $$select $2$$;
create table public.inventory_suppliers(id uuid primary key,supplier_name text);
create table public.inventory_purchase_orders(id uuid primary key,purchase_order_no text,restaurant_id uuid,brand_id uuid,supplier_id uuid,status text,requested_delivery_date date,total_supply_amount numeric(12,2),tax_amount numeric(12,2),total_amount numeric(12,2),office_reviewed_at timestamptz,created_at timestamptz,updated_at timestamptz);
create table public.inventory_purchase_order_lines(id uuid primary key,purchase_order_id uuid,product_id uuid,supplier_item_id uuid,recommended_quantity_base numeric,ordered_quantity_base numeric,ordered_quantity_unit text,order_unit text,unit_price numeric,supply_amount numeric,tax_amount numeric,memo text,recommendation_snapshot jsonb,created_at timestamptz,updated_at timestamptz);
create table public.inventory_receipts(id uuid primary key,purchase_order_id uuid,restaurant_id uuid,status text,submitted_at timestamptz,received_at timestamptz,received_by uuid,statement_number text,statement_date date,total_supply_amount numeric,tax_amount numeric,total_amount numeric,verified_by uuid,verified_at timestamptz,verification_reason text,memo text,created_at timestamptz,updated_at timestamptz);
create table public.inventory_receipt_lines(id uuid primary key,receipt_id uuid,purchase_order_line_id uuid,product_id uuid,received_quantity_base numeric,accepted_quantity_base numeric,rejected_quantity_base numeric,actual_unit_price numeric,final_supply_amount numeric,final_tax_amount numeric,discrepancy_reason text,memo text,created_at timestamptz,updated_at timestamptz);
create table public.inventory_supplier_returns(id uuid primary key,purchase_order_id uuid,receipt_line_id uuid,quantity_base numeric);
create table public.inventory_items(id uuid primary key,restaurant_id uuid,name text,unit text,current_stock numeric,cost_per_unit numeric,is_active boolean,updated_at timestamptz);
create table public.inventory_transactions(ingredient_id uuid,restaurant_id uuid,quantity_g numeric,effective_date date,created_at timestamptz);
create table public.inventory_products(id uuid primary key,inventory_item_id uuid,product_code text,category text,name text,is_active boolean,updated_at timestamptz);
create table public.photo_objet_sales_pull_runs(id uuid primary key,store_id uuid,target_date date,status text,rows_read int,aggregate_rows int,started_at timestamptz,finished_at timestamptz,slot_date_hcm date,slot_time_hcm time,interval_start_at timestamptz,interval_end_at timestamptz);
grant select on all tables in schema public to service_role;
'''
sql = fixture+source[start:end]+purchase[purchase_start:purchase_end]+detail_source[detail_start:detail_end]+snapshot_source[snapshot_start:snapshot_end]+(root/'supabase/migrations/20261005038000_office_store_batch_reads.sql').read_text()+(root/'supabase/tests/office_store_batch_reads.test.sql').read_text()
run = subprocess.run(cmd,input=sql,text=True,capture_output=True)
output = run.stdout+run.stderr
a.output.write_text(output)
errors = [line for line in output.splitlines() if line.startswith('not ok') or 'ERROR:' in line]
print(f'POS contract: {len(re.findall(r"^ok ",output,re.M))} passed; exit={run.returncode}; errors={errors}')
raise SystemExit(1 if run.returncode or errors else 0)
