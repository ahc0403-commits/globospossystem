from pathlib import Path
import re
import sys
root, destination = map(Path, sys.argv[1:])
mdir = root / 'supabase/migrations'
def function(file, name):
    s = (mdir / file).read_text()
    m = re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.' + name + r'\(', s, re.I)
    return s[m.start():s.index('$$;', m.start()) + 3] + '\n'
s = (root / 'test/sql/direct_delivery_cash_payout_setup.sql').read_text()
a = s.index('CREATE TABLE public.daily_closings(')
b = s.index('\n);', a) + 4
out = s[a:b] + '''
ALTER TABLE public.daily_closings ADD COLUMN delivery_cash_payout numeric(15,2) DEFAULT 0 CHECK(delivery_cash_payout>=0), ADD COLUMN payments_bank_transfer numeric(15,2) DEFAULT 0;
ALTER TABLE public.users ADD COLUMN full_name text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
ALTER TABLE public.inventory_items ADD COLUMN is_active boolean DEFAULT true, ADD COLUMN reorder_point numeric;
CREATE FUNCTION public.require_pos_admin_actor_for_store(p_store uuid,p_code text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 PERFORM public.direct_order_require_actor(p_store,ARRAY['admin','store_admin','brand_admin','super_admin']);
END; $$;
'''
out += function('20260907100000_direct_delivery_cash_payout_daily_closing.sql', 'get_daily_closing_cash_preview')
for name in ['create_daily_closing', 'get_daily_closing_days']:
    out += function('20260916170000_daily_closing_live_snapshot_reconciliation.sql', name)
destination.write_text(out)
