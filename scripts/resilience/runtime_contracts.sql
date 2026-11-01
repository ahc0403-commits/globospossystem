-- Catalog-only snapshot. No DDL, business rows, function bodies, defaults,
-- policy expressions, cron commands, credentials or role password hashes leave
-- the database. One statement gives a consistent MVCC catalog/history view.
-- The transport must additionally set a statement/overall deadline.
WITH schemas AS MATERIALIZED (
  SELECT oid, nspname, nspowner, nspacl
  FROM pg_catalog.pg_namespace
  WHERE nspname NOT LIKE 'pg\_%' ESCAPE '\' AND nspname <> 'information_schema'
), relations AS MATERIALIZED (
  SELECT c.*, n.nspname
  FROM pg_catalog.pg_class c JOIN schemas n ON n.oid=c.relnamespace
  WHERE c.relkind IN ('r','p','v','m','f','S')
), columns AS (
  SELECT a.attrelid,
    encode(sha256(convert_to(jsonb_agg(jsonb_build_object(
      'name',a.attname,'position',a.attnum,'type',pg_catalog.format_type(a.atttypid,a.atttypmod),
      'notNull',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
      'collation',CASE WHEN a.attcollation=0 THEN NULL ELSE a.attcollation::regcollation::text END,
      'defaultHash',CASE WHEN d.oid IS NULL THEN NULL ELSE
        encode(sha256(convert_to(pg_catalog.pg_get_expr(d.adbin,d.adrelid),'UTF8')),'hex') END
    ) ORDER BY a.attnum)::text,'UTF8')),'hex') AS definition_hash,
    count(*) AS column_count
  FROM pg_catalog.pg_attribute a JOIN relations r ON r.oid=a.attrelid
  LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
  WHERE a.attnum>0 AND NOT a.attisdropped GROUP BY a.attrelid
), objects AS MATERIALIZED (
  SELECT 'schema' AS kind, n.nspname::text AS identity,
    jsonb_build_object('owner',pg_catalog.pg_get_userbyid(n.nspowner),'acl',n.nspacl::text) AS detail
  FROM schemas n
  UNION ALL
  SELECT 'routine',format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.pg_get_function_identity_arguments(p.oid)),
    jsonb_build_object('kind',p.prokind,'owner',pg_catalog.pg_get_userbyid(p.proowner),
      'securityDefiner',p.prosecdef,'volatility',p.provolatile,'strict',p.proisstrict,
      'parallel',p.proparallel,'leakproof',p.proleakproof,'result',pg_catalog.pg_get_function_result(p.oid),
      'searchPath',(SELECT value FROM unnest(p.proconfig) value WHERE value LIKE 'search_path=%' LIMIT 1),
      'configHash',encode(sha256(convert_to(coalesce(p.proconfig::text,''),'UTF8')),'hex'),
      'definitionHash',encode(sha256(convert_to(pg_catalog.pg_get_functiondef(p.oid),'UTF8')),'hex'),
      'acl',p.proacl::text)
  FROM pg_catalog.pg_proc p JOIN schemas n ON n.oid=p.pronamespace WHERE p.prokind IN ('f','p','w')
  UNION ALL
  SELECT 'relation',format('%I.%I',r.nspname,r.relname),
    jsonb_build_object('kind',r.relkind,'owner',pg_catalog.pg_get_userbyid(r.relowner),
      'rls',r.relrowsecurity,'forceRls',r.relforcerowsecurity,'acl',r.relacl::text,
      'replicaIdentity',r.relreplident,'options',r.reloptions,'columnsHash',c.definition_hash,
      'columnCount',c.column_count,'viewHash',CASE WHEN r.relkind IN ('v','m') THEN
        encode(sha256(convert_to(pg_catalog.pg_get_viewdef(r.oid,true),'UTF8')),'hex') END,
      'partitionHash',CASE WHEN r.relkind='p' THEN
        encode(sha256(convert_to(pg_catalog.pg_get_partkeydef(r.oid),'UTF8')),'hex') END)
  FROM relations r LEFT JOIN columns c ON c.attrelid=r.oid
  UNION ALL
  SELECT 'constraint',format('%I.%I.%I',n.nspname,coalesce(r.relname,t.typname),c.conname),
    jsonb_build_object('type',c.contype,'validated',c.convalidated,'deferrable',c.condeferrable,
      'deferred',c.condeferred,'definitionHash',encode(sha256(convert_to(pg_catalog.pg_get_constraintdef(c.oid,true),'UTF8')),'hex'))
  FROM pg_catalog.pg_constraint c JOIN schemas n ON n.oid=c.connamespace
  LEFT JOIN pg_catalog.pg_class r ON r.oid=c.conrelid LEFT JOIN pg_catalog.pg_type t ON t.oid=c.contypid
  UNION ALL
  SELECT 'index',format('%I.%I',n.nspname,c.relname),
    jsonb_build_object('valid',i.indisvalid,'ready',i.indisready,'unique',i.indisunique,
      'primary',i.indisprimary,'definitionHash',encode(sha256(convert_to(pg_catalog.pg_get_indexdef(i.indexrelid),'UTF8')),'hex'))
  FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid
  JOIN schemas n ON n.oid=c.relnamespace
  UNION ALL
  SELECT 'trigger',format('%I.%I.%I',r.nspname,r.relname,t.tgname),
    jsonb_build_object('enabled',t.tgenabled,'definitionHash',
      encode(sha256(convert_to(pg_catalog.pg_get_triggerdef(t.oid,true),'UTF8')),'hex'))
  FROM pg_catalog.pg_trigger t JOIN relations r ON r.oid=t.tgrelid WHERE NOT t.tgisinternal
  UNION ALL
  SELECT 'policy',format('%I.%I.%I',r.nspname,r.relname,p.polname),
    jsonb_build_object('command',p.polcmd,'permissive',p.polpermissive,
      'roles',(SELECT jsonb_agg(CASE WHEN role_id=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(role_id) END
        ORDER BY role_id) FROM unnest(p.polroles) role_id),
      'usingHash',encode(sha256(convert_to(coalesce(pg_catalog.pg_get_expr(p.polqual,p.polrelid),''),'UTF8')),'hex'),
      'checkHash',encode(sha256(convert_to(coalesce(pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid),''),'UTF8')),'hex'))
  FROM pg_catalog.pg_policy p JOIN relations r ON r.oid=p.polrelid
  UNION ALL
  SELECT 'default_acl',format('%I.%s.%s',coalesce(n.nspname,'*'),pg_catalog.pg_get_userbyid(d.defaclrole),d.defaclobjtype),
    jsonb_build_object('acl',d.defaclacl::text)
  FROM pg_catalog.pg_default_acl d LEFT JOIN schemas n ON n.oid=d.defaclnamespace
  WHERE d.defaclnamespace=0 OR n.oid IS NOT NULL
  UNION ALL
  SELECT 'extension',e.extname,jsonb_build_object('version',e.extversion,'schema',n.nspname)
  FROM pg_catalog.pg_extension e JOIN schemas n ON n.oid=e.extnamespace
  UNION ALL
  SELECT 'enum',format('%I.%I',n.nspname,t.typname),
    jsonb_build_object('labelsHash',encode(sha256(convert_to(jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)::text,'UTF8')),'hex'))
  FROM pg_catalog.pg_enum e JOIN pg_catalog.pg_type t ON t.oid=e.enumtypid
  JOIN schemas n ON n.oid=t.typnamespace GROUP BY n.nspname,t.typname
  UNION ALL
  SELECT 'sequence',format('%I.%I',r.nspname,r.relname),
    jsonb_build_object('type',pg_catalog.format_type(s.seqtypid,NULL),'start',s.seqstart,'increment',s.seqincrement,
      'min',s.seqmin,'max',s.seqmax,'cache',s.seqcache,'cycle',s.seqcycle)
  FROM pg_catalog.pg_sequence s JOIN relations r ON r.oid=s.seqrelid
  UNION ALL
  SELECT 'publication',p.pubname,jsonb_build_object('allTables',p.puballtables,'insert',p.pubinsert,
    'update',p.pubupdate,'delete',p.pubdelete,'truncate',p.pubtruncate,'viaRoot',p.pubviaroot)
  FROM pg_catalog.pg_publication p
  UNION ALL
  SELECT 'publication_relation',format('%I.%I.%I',p.pubname,r.nspname,r.relname),
    jsonb_build_object('columns',pr.prattrs::text,'filterHash',
      encode(sha256(convert_to(coalesce(pg_catalog.pg_get_expr(pr.prqual,pr.prrelid),''),'UTF8')),'hex'))
  FROM pg_catalog.pg_publication_rel pr JOIN pg_catalog.pg_publication p ON p.oid=pr.prpubid
  JOIN relations r ON r.oid=pr.prrelid
  UNION ALL
  SELECT 'migration',m.version,
    jsonb_build_object('name',m.name,'statementsHash',
      encode(sha256(convert_to(coalesce(to_jsonb(m.statements)::text,''),'UTF8')),'hex'))
  FROM supabase_migrations.schema_migrations m
), bounded AS MATERIALIZED (
  SELECT kind,identity,detail FROM objects ORDER BY kind COLLATE "C",identity COLLATE "C" LIMIT 20001
), envelope AS (
  SELECT count(*) AS object_count,jsonb_agg(jsonb_build_object('kind',kind,'identity',identity,
    'detail',detail,'sha256',encode(sha256(convert_to(detail::text,'UTF8')),'hex'))
    ORDER BY kind COLLATE "C",identity COLLATE "C") AS entries FROM bounded
)
SELECT jsonb_build_object('schemaVersion',1,'kind','runtime-catalog',
  'capturedAt',statement_timestamp(),'serverVersion',current_setting('server_version'),
  'searchPath',current_setting('search_path'),'database',current_database(),
  'schemas',(SELECT jsonb_agg(nspname ORDER BY nspname COLLATE "C") FROM schemas),
  'objectCount',object_count,'limitExceeded',object_count>20000 OR octet_length(entries::text)>6291456,
  'objects',CASE WHEN object_count<=20000 AND octet_length(entries::text)<=6291456 THEN entries ELSE NULL END,
  'restorableSchema',false,'businessDataCollected',false) AS snapshot
FROM envelope;
