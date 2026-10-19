do $$begin
 if (select gross_sales from public.restaurant_daily_sales_finalizations where business_date='2026-10-05')<>1000 then raise exception 'repair missed amount';end if;
 if (select status from public.restaurant_daily_sales_finalizations where business_date='2026-10-06')<>'data_integrity_failed' then raise exception 'late receipts applied';end if;
 if (select count(*) from public.restaurant_sales_finalization_repairs)<>2 then raise exception 'repair audit not idempotent';end if;
 if exists(select 1 from public.restaurant_sales_finalization_repairs where previous_record->>'store_count'<>'0') then raise exception 'lost before image';end if;
 begin update public.restaurant_daily_sales_finalizations set gross_sales=1;raise exception 'immutability lost';exception when others then if sqlerrm<>'RESTAURANT_FINALIZATION_IMMUTABLE' then raise;end if;end;
 begin delete from public.restaurant_sales_finalization_repairs;raise exception 'audit mutable';exception when others then if sqlerrm<>'RESTAURANT_FINALIZATION_IMMUTABLE' then raise;end if;end;
end$$;
select 'Audited correction, cutoff failure, second-run idempotence and immutability PASS' as result;
