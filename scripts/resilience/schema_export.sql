-- Prototype: READ ONLY application catalog, never business data or role secrets.
-- SCOPE and optional page predicate are supplied only by the trusted caller.
SET LOCAL statement_timeout='15s';
SET LOCAL search_path='';
WITH ns AS MATERIALIZED (SELECT n.* FROM pg_catalog.pg_namespace n
 WHERE n.nspname=ANY(ARRAY[/*SCOPE*/]::text[])),
rels AS MATERIALIZED (SELECT c.*,n.nspname,
 format('%I.%I',n.nspname,c.relname) ident FROM pg_catalog.pg_class c JOIN ns n ON n.oid=c.relnamespace
 WHERE NOT EXISTS(SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid='pg_class'::regclass
 AND d.objid=c.oid AND d.deptype='e')),
fns AS MATERIALIZED (SELECT p.*,n.nspname,
 format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.pg_get_function_identity_arguments(p.oid)) ident
 FROM pg_catalog.pg_proc p JOIN ns n ON n.oid=p.pronamespace
 WHERE NOT EXISTS(SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid='pg_proc'::regclass
 AND d.objid=p.oid AND d.deptype='e')),
columns AS (SELECT a.attrelid,jsonb_agg(jsonb_build_object('name',a.attname,
 'position',a.attnum,'type',pg_catalog.format_type(a.atttypid,a.atttypmod),
 'notnull',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
 'default',pg_catalog.pg_get_expr(d.adbin,d.adrelid),
 'collation',CASE WHEN a.attcollation<>t.typcollation THEN a.attcollation::regcollation::text END,
 'acl',a.attacl) ORDER BY a.attnum) value
 FROM pg_catalog.pg_attribute a JOIN rels r ON r.oid=a.attrelid
 JOIN pg_catalog.pg_type t ON t.oid=a.atttypid
 LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
 WHERE a.attnum>0 AND NOT a.attisdropped GROUP BY a.attrelid),
owners AS (SELECT oid,pg_catalog.pg_get_userbyid(oid) name FROM pg_catalog.pg_roles),
enumlabels AS (SELECT enumtypid,jsonb_agg(enumlabel ORDER BY enumsortorder) labels
 FROM pg_catalog.pg_enum GROUP BY enumtypid),
viewdeps AS (SELECT rw.ev_class,jsonb_agg(DISTINCT r2.ident) refs
 FROM pg_catalog.pg_rewrite rw JOIN rels r ON r.oid=rw.ev_class
 JOIN pg_catalog.pg_depend d ON d.classid='pg_rewrite'::regclass AND d.objid=rw.oid
 AND d.refclassid='pg_class'::regclass JOIN rels r2 ON r2.oid=d.refobjid
 WHERE r2.oid<>r.oid AND r2.relkind IN('v','m') GROUP BY rw.ev_class),
fndeps AS (SELECT d.objid,jsonb_agg(DISTINCT f2.ident) FILTER(WHERE f2.oid IS NOT NULL) refs,
 bool_or(d.refclassid='pg_class'::regclass) table_default
 FROM pg_catalog.pg_depend d JOIN fns f ON f.oid=d.objid
 LEFT JOIN fns f2 ON d.refclassid='pg_proc'::regclass AND f2.oid=d.refobjid AND f2.oid<>f.oid
 WHERE d.classid='pg_proc'::regclass GROUP BY d.objid),
fntypes AS (SELECT f.oid,bool_or(t.typrelid<>0 OR coalesce(elem.typrelid,0)<>0) table_type
 FROM fns f CROSS JOIN LATERAL unnest(array_append(coalesce(f.proallargtypes,f.proargtypes::oid[]),f.prorettype)) arg
 JOIN pg_catalog.pg_type t ON t.oid=arg LEFT JOIN pg_catalog.pg_type elem ON elem.oid=t.typelem
 GROUP BY f.oid),
objects AS (
 SELECT 'schema' kind,n.nspname::text ident,jsonb_build_object('owner',o.name,'acl',n.nspacl) meta
 FROM ns n JOIN owners o ON o.oid=n.nspowner
 UNION ALL
 SELECT 'enum',format('%I.%I',n.nspname,t.typname),jsonb_build_object('owner',o.name,
 'labels',e.labels,'acl',t.typacl)
 FROM pg_catalog.pg_type t JOIN ns n ON n.oid=t.typnamespace JOIN owners o ON o.oid=t.typowner
 JOIN enumlabels e ON e.enumtypid=t.oid
 UNION ALL
 SELECT 'relation',r.ident,jsonb_build_object('kind',r.relkind,'owner',o.name,'acl',r.relacl,
 'columns',coalesce(c.value,'[]'::jsonb),'persistence',r.relpersistence,'rls',r.relrowsecurity,
 'forceRls',r.relforcerowsecurity,'replicaIdentity',r.relreplident,'options',r.reloptions,
 'replicaIndex',ri.relname,'definition',CASE WHEN r.relkind IN('v','m') THEN pg_catalog.pg_get_viewdef(r.oid,true) END,
 'partition',r.relispartition,'tableSpace',r.reltablespace,
 'dependencies',coalesce(vd.refs,'[]'::jsonb))
 FROM rels r JOIN owners o ON o.oid=r.relowner LEFT JOIN columns c ON c.attrelid=r.oid
 LEFT JOIN pg_catalog.pg_index idx ON idx.indrelid=r.oid AND idx.indisreplident
 LEFT JOIN pg_catalog.pg_class ri ON ri.oid=idx.indexrelid
 LEFT JOIN viewdeps vd ON vd.ev_class=r.oid
 WHERE r.relkind IN('r','p','v','m','f')
 UNION ALL
 SELECT 'sequence',r.ident,jsonb_build_object('owner',o.name,'acl',r.relacl,
 'type',pg_catalog.format_type(s.seqtypid,null),'start',s.seqstart::text,'increment',s.seqincrement::text,
 'min',s.seqmin::text,'max',s.seqmax::text,'cache',s.seqcache::text,'cycle',s.seqcycle,
 'table',tab.ident,'column',a.attname,'dependency',d.deptype)
 FROM rels r JOIN owners o ON o.oid=r.relowner JOIN pg_catalog.pg_sequence s ON s.seqrelid=r.oid
 LEFT JOIN pg_catalog.pg_depend d ON d.classid='pg_class'::regclass AND d.objid=r.oid
 AND d.refclassid='pg_class'::regclass AND d.deptype IN('a','i')
 LEFT JOIN rels tab ON tab.oid=d.refobjid LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=d.refobjid AND a.attnum=d.refobjsubid
 WHERE r.relkind='S'
 UNION ALL
 SELECT 'routine',f.ident,jsonb_build_object('owner',o.name,'acl',f.proacl,'kind',f.prokind,
 'definition',pg_catalog.pg_get_functiondef(f.oid),'sqlStandardBody',f.prosqlbody IS NOT NULL,
 'tableType', coalesce(ft.table_type,false),
 'tableDefault', coalesce(dep.table_default,false),
 'dependencies',coalesce(dep.refs,'[]'::jsonb))
 FROM fns f JOIN owners o ON o.oid=f.proowner
 LEFT JOIN fndeps dep ON dep.objid=f.oid
 LEFT JOIN fntypes ft ON ft.oid=f.oid
 WHERE f.prokind IN('f','p')
 UNION ALL
 SELECT 'constraint',r.ident||'.'||quote_ident(c.conname),jsonb_build_object('table',r.ident,
 'name',c.conname,'type',c.contype,'definition',pg_catalog.pg_get_constraintdef(c.oid,true),'local',c.conislocal,
 'index',i.relname)
 FROM pg_catalog.pg_constraint c JOIN rels r ON r.oid=c.conrelid
 LEFT JOIN pg_catalog.pg_class i ON i.oid=c.conindid
 UNION ALL
 SELECT 'index',r.ident,jsonb_build_object('table',tab.ident,'definition',pg_catalog.pg_get_indexdef(r.oid),
 'valid',i.indisvalid,'ready',i.indisready,'constraint',con.conname)
 FROM rels r JOIN pg_catalog.pg_index i ON i.indexrelid=r.oid JOIN rels tab ON tab.oid=i.indrelid
 LEFT JOIN pg_catalog.pg_constraint con ON con.conindid=r.oid AND con.contype IN('p','u','x')
 UNION ALL
 SELECT 'trigger',format('%I.%I.%I',n.nspname,c.relname,t.tgname),jsonb_build_object('table',format('%I.%I',n.nspname,c.relname),
 'name',t.tgname,'enabled',t.tgenabled,'definition',pg_catalog.pg_get_triggerdef(t.oid,true))
 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
 JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
 WHERE NOT t.tgisinternal AND (c.oid IN(SELECT oid FROM rels) OR t.tgfoid IN(SELECT oid FROM fns))
 UNION ALL
 SELECT 'policy',r.ident||'.'||quote_ident(p.polname),jsonb_build_object('table',r.ident,'name',p.polname,
 'command',p.polcmd,'permissive',p.polpermissive,'roles',(SELECT jsonb_agg(CASE WHEN role=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(role) END) FROM unnest(p.polroles)role),
 'using',pg_catalog.pg_get_expr(p.polqual,p.polrelid),'check',pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid))
 FROM pg_catalog.pg_policy p JOIN rels r ON r.oid=p.polrelid
 UNION ALL
 SELECT 'defaultAcl',pg_catalog.pg_get_userbyid(d.defaclrole)||'.'||coalesce(n.nspname,'*')||'.'||d.defaclobjtype::text,
 jsonb_build_object('owner',pg_catalog.pg_get_userbyid(d.defaclrole),'schema',n.nspname,'type',d.defaclobjtype,'acl',d.defaclacl)
 FROM pg_catalog.pg_default_acl d LEFT JOIN ns n ON n.oid=d.defaclnamespace
 WHERE n.oid IS NOT NULL OR d.defaclnamespace=0
 UNION ALL
 SELECT 'eventTrigger',e.evtname,jsonb_build_object('owner',pg_catalog.pg_get_userbyid(e.evtowner),
 'event',e.evtevent,'tags',e.evttags,'enabled',e.evtenabled,'function',f.ident)
 FROM pg_catalog.pg_event_trigger e JOIN fns f ON f.oid=e.evtfoid
)
SELECT kind,ident,meta,encode(sha256(convert_to(meta::text,'UTF8')),'hex') sha256
FROM objects WHERE /*PAGE*/ ORDER BY kind,ident;
