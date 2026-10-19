insert into public.payments
select gen_random_uuid(),'40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',100,100,true,'2026-10-08 12:00+07'::timestamptz + (n%3600)*interval '1 second' from generate_series(1,10000) n;
analyze public.payments;
do $$declare started timestamptz; body jsonb; elapsed numeric; n int; begin
 started:=clock_timestamp();
 for n in 1..20 loop
 select jsonb_agg(to_jsonb(t)) into body from public.restaurant_sales_totals_range('2026-10-01','2026-10-14') t;
 end loop;
 elapsed:=extract(epoch from (clock_timestamp()-started))*1000/20;
 if jsonb_array_length(body)<>14 then raise exception 'range row budget exceeded';end if;
 raise notice 'POS 10006 source payments: 14 returned days, % bytes, mean % ms, 1 range RPC',octet_length(body::text),round(elapsed,2);
end$$;
