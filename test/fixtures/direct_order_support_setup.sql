CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
-- Invoice infrastructure is reduced to its scoped intake boundary in this fixture.
CREATE TABLE support_invoice_fixture(order_id uuid PRIMARY KEY,store_id uuid,payload jsonb);
CREATE FUNCTION public.upsert_red_invoice_intake_minimal(uuid,uuid,text,text,text,text,text,text,text,text)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO support_invoice_fixture VALUES($1,$2,jsonb_build_object('tax_code',$5,'name',$6,'status',$4))
 ON CONFLICT(order_id) DO UPDATE SET payload=EXCLUDED.payload;
 RETURN jsonb_build_object('order_id',$1);
END;
$$;
