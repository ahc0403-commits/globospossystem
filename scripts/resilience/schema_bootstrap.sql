SET LOCAL search_path=''; SET LOCAL statement_timeout='15s';
WITH pubrels AS (
 SELECT pr.prpubid,jsonb_agg(jsonb_build_object('table',format('%I.%I',n.nspname,c.relname),
 'filter',pg_get_expr(pr.prqual,pr.prrelid),'columns',
 (SELECT jsonb_agg(a.attname ORDER BY a.attnum) FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attnum=ANY(pr.prattrs))) ORDER BY n.nspname,c.relname) rels
 FROM pg_publication_rel pr JOIN pg_class c ON c.oid=pr.prrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN (/*SCOPE*/)
 GROUP BY pr.prpubid)
SELECT jsonb_build_object('capturedAt',clock_timestamp(),'serverVersion',current_setting('server_version'),
 'roles',(SELECT jsonb_agg(rolname ORDER BY rolname) FROM pg_roles),
 'extensions',(SELECT jsonb_agg(jsonb_build_object('name',e.extname,'version',e.extversion,'schema',n.nspname) ORDER BY e.extname)
 FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace),
 'publications',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',p.pubname,'allTables',p.puballtables,
 'insert',p.pubinsert,'update',p.pubupdate,'delete',p.pubdelete,'truncate',p.pubtruncate,'viaRoot',p.pubviaroot,
 'relations',coalesce(r.rels,'[]'::jsonb)) ORDER BY p.pubname),'[]'::jsonb)
 FROM pg_publication p LEFT JOIN pubrels r ON r.prpubid=p.oid),
 'managedAuthFunctions',(SELECT jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,'definition',pg_get_functiondef(p.oid)))
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='auth' AND p.proname IN ('uid','jwt','role','email')),
 'history',(SELECT jsonb_agg(jsonb_build_object('version',version,'name',name,'statementsHash',
 encode(sha256(convert_to(coalesce(to_jsonb(statements),'null'::jsonb)::text,'UTF8')),'hex')) ORDER BY version)
 FROM supabase_migrations.schema_migrations)) AS bootstrap;
