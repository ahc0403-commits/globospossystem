"""Load exact effective address/menu RPC bodies into the disposable payment DB."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
migrations = root / 'supabase/migrations'


def function(filename, name):
    source = (migrations / filename).read_text()
    match = re.search(r'CREATE (?:OR REPLACE )?FUNCTION (?:public\.' + name +
                      r'\(|"public"\."' + name + r'"\()', source)
    assert match, name
    tag = re.search(r'\bAS\s+(\$[^$]*\$)', source[match.start():], re.I).group(1)
    start_body = source.index(tag, match.start())
    end = source.index(tag + ';', start_body + len(tag)) + len(tag) + 1
    return source[match.start():end].replace('CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION', 1)


print("""
DO $$ BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
ALTER TABLE public.menu_items ADD COLUMN IF NOT EXISTS choice_definition jsonb NOT NULL DEFAULT '{}',
 ADD COLUMN IF NOT EXISTS menu_option_key text;
ALTER TABLE public.direct_order_requests ADD COLUMN IF NOT EXISTS submission_hash text;
ALTER TABLE public.direct_order_request_items ADD COLUMN IF NOT EXISTS menu_option_snapshot jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.print_jobs ADD COLUMN IF NOT EXISTS attempts integer DEFAULT 0,
 ADD COLUMN IF NOT EXISTS next_retry_at timestamptz DEFAULT now(),
 ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now(),
 ADD COLUMN IF NOT EXISTS fulfillment_mode_snapshot text DEFAULT 'pos_print';
ALTER TABLE public.direct_order_request_addresses
 ALTER COLUMN latitude DROP NOT NULL, ALTER COLUMN longitude DROP NOT NULL,
 DROP CONSTRAINT direct_order_request_addresses_address_source_check,
 DROP CONSTRAINT IF EXISTS direct_order_address_location_mode_valid;
ALTER TABLE public.direct_order_request_addresses
 ADD CONSTRAINT direct_order_request_addresses_address_source_check CHECK(address_source IN('manual','search','map_pin')),
 ADD CONSTRAINT direct_order_address_location_mode_valid CHECK(
  (address_source='manual' AND latitude IS NULL AND longitude IS NULL AND google_place_id IS NULL AND NOT location_verified)
  OR (address_source IN('search','map_pin') AND latitude IS NOT NULL AND longitude IS NOT NULL));
CREATE INDEX IF NOT EXISTS direct_order_messages_request_created ON public.direct_order_messages(request_id,created_at,id);
CREATE UNIQUE INDEX IF NOT EXISTS direct_order_messages_attachment_unique ON public.direct_order_messages(attachment_storage_path)
 WHERE attachment_storage_path IS NOT NULL;
""")
# Apply the actual pickup address DDL, including the still-broken 1..300 check.
pickup = (migrations / '20261002030000_direct_order_delivery_pickup.sql').read_text()
start = pickup.index('ALTER TABLE public.direct_order_request_addresses')
print(pickup[start:pickup.index('ALTER TABLE public.direct_order_quotes', start)])
for filename, names in [
    ('20260821130000_direct_delivery_ordering.sql', ['direct_order_consume_public_rate']),
    ('20260910130000_direct_order_customer_payment_and_status.sql', ['direct_order_staff_request_proof_resubmission']),
    ('20261021170000_direct_order_line_identity.sql', ['snapshot_direct_order_item_vat']),
    ('20261021180000_registered_menu_choices.sql', ['menu_choice_snapshot']),
    ('20261021181000_menu_choice_intake.sql', ['validate_menu_option_batch',
     'direct_order_prepare_combo_items', 'direct_order_public_submit', 'direct_order_public_submit_v2']),
    ('20260901120000_direct_delivery_driver_receipt.sql',
     ['guard_direct_delivery_driver_receipt_job', 'enqueue_direct_delivery_driver_receipt']),
]:
    for name in names:
        print(function(filename, name))
print("""
CREATE TRIGGER optional_driver_receipt_guard BEFORE INSERT OR UPDATE ON public.print_jobs
 FOR EACH ROW EXECUTE FUNCTION public.guard_direct_delivery_driver_receipt_job();
""")
