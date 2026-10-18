do $$declare t record; f public.restaurant_daily_sales_finalizations; begin
 select * into t from public.restaurant_sales_totals_range('2026-10-05','2026-10-05');
 if t.store_count<>1 or t.receipt_count<>2 or t.gross_sales<>1000 then raise exception 'scope/portions sum wrong: %',row_to_json(t);end if;
 select * into t from public.restaurant_sales_totals_range('2026-10-06','2026-10-06');
 if t.post_cutoff_receipt_count<>1 then raise exception 'cutoff boundary ignored';end if;
 f:=public.restaurant_finalize_daily_sales_at('2026-10-07','2026-10-07 22:20+07');
 if f.status<>'finalized' or f.gross_sales<>0 or f.store_count<>1 then raise exception 'real zero lost';end if;
 if public.restaurant_finalize_daily_sales_at('2026-10-07','2026-10-07 22:20+07') is distinct from f then raise exception 'finalization not idempotent';end if;
 begin perform public.restaurant_finalize_daily_sales_at('2026-10-08','2026-10-08 22:19+07');raise exception 'time gate bypassed';exception when others then if sqlerrm<>'RESTAURANT_FINALIZATION_TOO_EARLY' then raise;end if;end;
 begin perform public.restaurant_finalize_daily_sales_at('2026-10-05','2026-10-05 22:20+07');raise exception 'old bad row accepted';exception when others then if sqlerrm<>'RESTAURANT_FINALIZATION_REPAIR_REQUIRED' then raise;end if;end;
end$$;
select 'POS scope, payment portions, cutoff, real zero and idempotence PASS' as result;
do $$ begin
 update public.restaurants set store_type='external' where name='Restaurant';
 begin perform public.restaurant_finalize_daily_sales_at('2026-10-08','2026-10-08 22:20+07');raise exception 'zero scope accepted';exception when others then if sqlerrm<>'RESTAURANT_FINALIZATION_NO_STORES' then raise;end if;end;
 update public.restaurants set store_type='direct' where name='Restaurant';
 begin perform public.restaurant_sales_totals_range('2026-10-01','2026-11-01');raise exception 'unbounded range accepted';exception when invalid_parameter_value then null;end;
 if has_function_privilege('authenticated','public.restaurant_sales_totals_range(date,date)','execute')
 or has_function_privilege('authenticated','public.restaurant_finalize_daily_sales_at(date,timestamptz)','execute') then raise exception 'application write boundary lost';end if;
end$$;
select 'Zero store guard, bounded range and application privileges PASS' as result;
