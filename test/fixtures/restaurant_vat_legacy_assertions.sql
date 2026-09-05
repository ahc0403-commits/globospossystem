DO $$
DECLARE ord uuid; store uuid;
BEGIN
 IF EXISTS(SELECT 1 FROM legacy_cases c JOIN order_items i ON i.order_id=c.order_id
   WHERE (c.label IN ('completed','partial') AND (i.vat_rate<>0 OR i.paying_amount_inc_tax<>4000))
      OR (c.label='unpaid' AND (i.vat_rate<>8 OR i.vat_amount<>320 OR i.paying_amount_inc_tax<>4320))) THEN
   RAISE EXCEPTION 'migration changed paid history or failed to update unpaid charges';
 END IF;
 SELECT c.order_id,o.restaurant_id INTO ord,store FROM legacy_cases c JOIN orders o ON o.id=c.order_id WHERE c.label='partial';
 BEGIN
   PERFORM process_payment(ord,store,2000,'CASH');
   RAISE EXCEPTION 'part-paid legacy charge was silently repriced';
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM<>'WET_TISSUE_LEGACY_PAYMENT_REVIEW_REQUIRED' THEN RAISE; END IF;
 END;
 BEGIN
   INSERT INTO order_items(restaurant_id,order_id,item_type,unit_price,quantity,status,vat_rate,vat_amount,total_amount_ex_tax,paying_amount_inc_tax)
   VALUES(store,gen_random_uuid(),'wet_tissue_charge',2000,2,'ready',0,0,4000,4000);
   RAISE EXCEPTION 'new zero-VAT wet tissue was accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 RAISE NOTICE 'PASS: preserve paid history; update unpaid; reject new zero VAT';
END $$;
