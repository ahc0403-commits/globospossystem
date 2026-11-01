-- Read-only unsupported-shape inventory. Never skip unknown app schemas/types.
SET LOCAL search_path=''; SET LOCAL statement_timeout='15s';
WITH ns AS MATERIALIZED (SELECT oid,nspname FROM pg_namespace WHERE nspname=ANY(ARRAY[/*SCOPE*/]::text[])),
rels AS MATERIALIZED (SELECT c.* FROM pg_class c JOIN ns n ON n.oid=c.relnamespace
 WHERE NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')),
fns AS MATERIALIZED (SELECT p.* FROM pg_proc p JOIN ns n ON n.oid=p.pronamespace
 WHERE NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e'))
SELECT jsonb_build_object(
 'schemaInventory',(SELECT jsonb_agg(nspname ORDER BY nspname) FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname<>'information_schema'),
 'unsupportedRelations',(SELECT count(*) FROM rels WHERE relkind IN('m','f','p') OR relispartition OR reltablespace<>0),
 'unsupportedTypes',(SELECT count(*) FROM pg_type t JOIN ns n ON n.oid=t.typnamespace LEFT JOIN pg_class c ON c.oid=t.typrelid
  WHERE (t.typtype IN('d','r','m') OR c.relkind='c') AND NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_type'::regclass AND d.objid=t.oid AND d.deptype='e')),
 'nonViewRules',(SELECT count(*) FROM pg_rewrite rw JOIN rels r ON r.oid=rw.ev_class WHERE rw.rulename<>'_RETURN'),
 'customAggregates',(SELECT count(*) FROM fns WHERE prokind='a'),
 'customCollations',(SELECT count(*) FROM pg_collation c JOIN ns n ON n.oid=c.collnamespace),
 'schemaPublications',(SELECT count(*) FROM pg_publication_namespace p JOIN ns n ON n.oid=p.pnnspid),
 'otherLanguages',(SELECT count(*) FROM fns f JOIN pg_language l ON l.oid=f.prolang WHERE l.lanname NOT IN('sql','plpgsql')),
 'ordinaryInheritance',(SELECT count(*) FROM pg_inherits i JOIN rels r ON r.oid=i.inhrelid WHERE NOT r.relispartition AND r.relkind='r')) AS guards;
