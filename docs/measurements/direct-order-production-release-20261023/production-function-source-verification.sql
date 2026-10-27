WITH expected(signature,body_hash) AS (VALUES
 ('public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)','154bc13d570d873b60bf62ffb8dd8a10'),
 ('public.direct_order_public_updates(uuid,text,uuid)','8aa18697445cc77990b27bd28c9c817f'),
 ('public.direct_order_bump_chat_revision()','0c97a6c776021c73d476689075801224')
) SELECT signature,md5(p.prosrc)=expected.body_hash AS deployed_source_matches FROM expected JOIN pg_proc p ON p.oid=expected.signature::regprocedure;
