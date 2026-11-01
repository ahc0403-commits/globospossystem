"""Private, bounded application schema reconstruction; never a production executor.

Input: source-hashed catalog-only captures. Output is PRIVATE, data-free SQL for
an owned, network-isolated disposable Supabase PostgreSQL instance. It must pass
semantic catalog comparison and native pg_dump/restore before use as a baseline.
"""
import argparse
from collections import defaultdict
import hashlib
import importlib.util
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[2]
PROJECTS={'pos':'ynriuoomotxuwhuxxmhj','office':'raghsbaxcwrxlsacaoau'}
SCOPES={
 'pos':{'public','pos_invoice_private','inventory_migration_backup','auth','storage'},
 'office':{'accounting','core','dashboard','documents','finance','hr','inventory','office_release_transport','ops','private','public','system','workflow','auth','storage'},
}
MAX_BYTES=32*1024*1024
PLATFORM_SCHEMAS={'cron','extensions','graphql','graphql_public','net','pgbouncer',
                  'realtime','supabase_migrations','vault'}
spec=importlib.util.spec_from_file_location('runtime_catalog',ROOT/'scripts/resilience/runtime_catalog.py')
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
spec_private=importlib.util.spec_from_file_location('private_files',ROOT/'scripts/resilience/sample_accounts.py')
private=importlib.util.module_from_spec(spec_private);spec_private.loader.exec_module(private)


def q(value): return '"'+value.replace('"','""')+'"'
def lit(value): return "'"+value.replace("'","''")+"'"
def require(value,message):
    if not value: raise ValueError(message)


def ordered(records):
    """Sort true creation dependencies; missing external members belong to platform."""
    pending={r['ident']:r for r in records};result=[]
    while pending:
        ready=sorted(k for k,r in pending.items() if not(set(r['meta'].get('dependencies',[])) & pending.keys()))
        require(ready,'Unresolved application creation dependency cycle')
        for key in ready: result.append(pending.pop(key))
    return result


def acl_split(raw,delimiter):
    quoted=False;i=0
    while i<len(raw):
        if raw[i]=='"':
            if quoted and i+1<len(raw) and raw[i+1]=='"': i+=2;continue
            quoted=not quoted
        elif raw[i]==delimiter and not quoted: return raw[:i],raw[i+1:]
        i+=1
    raise ValueError('Malformed ACL item')


def unquote(role):
    return role[1:-1].replace('""','"') if role.startswith('"') and role.endswith('"') else role


def acl_rows(raw):
    out=[]
    for item in raw or []:
        grantee,rest=acl_split(item,'=');privs,grantor=acl_split(rest,'/')
        i=0
        while i<len(privs):
            code=privs[i];i+=1;option=i<len(privs) and privs[i]=='*'
            if option:i+=1
            out.append((unquote(grantee) or 'PUBLIC',code,option,unquote(grantor)))
    return out


PRIVS={'a':'INSERT','r':'SELECT','w':'UPDATE','d':'DELETE','D':'TRUNCATE',
       'x':'REFERENCES','t':'TRIGGER','m':'MAINTAIN','X':'EXECUTE','U':'USAGE','C':'CREATE'}


def grants(target,raw,roles):
    # Explicit ACLs replace default PUBLIC/image grants; NULL retains PostgreSQL
    # defaults because app schemas/default ACLs are reset before object creation.
    if raw is None:return []
    lines=['REVOKE ALL ON '+target+' FROM '+', '.join(['PUBLIC',*map(q,sorted(roles))])+';']
    for grantee,code,option,grantor in acl_rows(raw):
        require(code in PRIVS,'Unknown privilege code')
        lines.append('SET ROLE '+q(grantor)+';')
        lines.append('GRANT '+PRIVS[code]+' ON '+target+' TO '+('PUBLIC' if grantee=='PUBLIC' else q(grantee))+
                     (' WITH GRANT OPTION' if option else '')+';')
        lines.append('RESET ROLE;')
    return lines


def load(name,area):
    area=Path(area)
    require(area.is_absolute() and not area.is_symlink() and area.stat().st_mode & 0o077 == 0, 'Snapshot directory must be absolute, private and not a symlink')
    manifest=json.loads(private.private_file(area/(name+'-manifest.json'),max_bytes=MAX_BYTES).read_text())
    require(manifest.get('projectRef')==PROJECTS[name] and set(manifest.get('scope',[]))==SCOPES[name], 'Pinned schema project/scope mismatch')
    require(0<len(manifest['objects'])<=20000,'Catalog object bound exceeded')
    expected={(r['kind'],r['ident']):r['sha256'] for r in manifest['objects']}
    require(len(expected)==len(manifest['objects']),'Duplicate source identities')
    actual={}
    total_bytes=0
    for path in area.glob(name+'-*.json'):
        if not re.fullmatch(re.escape(name)+r'-[A-Za-z]+-[0-9]+\.json',path.name):continue
        path=private.private_file(path,max_bytes=MAX_BYTES)
        total_bytes+=path.stat().st_size
        require(total_bytes<=64*1024*1024,'Total schema snapshot exceeds bound')
        for row in json.loads(path.read_text()):
            key=row['kind'],row['ident']
            require(key not in actual,'Duplicate export chunk identity')
            require(hashlib.sha256(runtime.pg_jsonb(row['meta']).encode()).hexdigest()==row['sha256'],
                    'Captured catalog body/hash mismatch')
            actual[key]=row
    require({k:r['sha256'] for k,r in actual.items()}==expected,'Incomplete or inconsistent export')
    return manifest,sorted(actual.values(),key=lambda r:(r['kind'],r['ident']))


def reference_sql(name,area):
    """Only global bucket configuration. No stored objects, users or cron rows."""
    path=Path(area)/(name+'-storage-reference-config.json')
    if not path.exists():return None
    raw=private.private_file(path,max_bytes=1024*1024).read_text()
    config=json.loads(raw)
    require(set(config)=={'kind','businessFilesCollected','buckets'} and
            config['kind']=='storage-bucket-reference-config' and config['businessFilesCollected'] is False,
            'Invalid storage reference envelope')
    buckets=config['buckets'];require(isinstance(buckets,list) and len(buckets)<=100,'Bucket bound exceeded')
    ids=set()
    for b in buckets:
        require(set(b)=={'id','name','public','file_size_limit','allowed_mime_types'},'Unexpected bucket metadata')
        require(all(isinstance(b[k],str) and 0<len(b[k])<=128 for k in ('id','name')) and
                b['id'] not in ids and type(b['public']) is bool,'Invalid bucket identity/privacy')
        ids.add(b['id']);size=b['file_size_limit'];mime=b['allowed_mime_types']
        require(size is None or type(size) is int and 0<=size<=9223372036854775807,'Invalid bucket size')
        require(mime is None or isinstance(mime,list) and len(mime)<=100 and
                all(isinstance(x,str) and 0<len(x)<=128 for x in mime),'Invalid MIME allowlist')
    return ('INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) '
            'SELECT id,name,public,file_size_limit,allowed_mime_types FROM jsonb_to_recordset('
            +lit(json.dumps(buckets,ensure_ascii=False))+'::jsonb) '
            'AS b(id text,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]) '
            'ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,public=EXCLUDED.public,'
            'file_size_limit=EXCLUDED.file_size_limit,allowed_mime_types=EXCLUDED.allowed_mime_types;')


def inventory_guards(name,area):
    guards=json.loads(private.private_file(area/(name+'-inventory-guards.json'),max_bytes=1024*1024).read_text())
    require(set(guards)=={'schemaInventory','unsupportedRelations','unsupportedTypes','nonViewRules',
                         'customAggregates','customCollations','schemaPublications','otherLanguages','ordinaryInheritance'},
            'Missing or unexpected unsupported-shape inventory')
    require(not(set(guards['schemaInventory'])-SCOPES[name]-PLATFORM_SCHEMAS),'Unreviewed application schema')
    require(all(type(value) is int and value==0 for key,value in guards.items() if key!='schemaInventory'),
            'Unsupported schema shape; extend the exporter explicitly before restoring')
    return guards


def assemble(name,area):
    manifest,objects=load(name,area)
    bootstrap=json.loads(private.private_file(area/(name+'-bootstrap.json'),max_bytes=MAX_BYTES).read_text())
    inventory_guards(name,area)
    by=defaultdict(list)
    for row in objects:by[row['kind']].append(row)
    allowed={'schema','enum','relation','sequence','routine','constraint','index','trigger','policy','defaultAcl','eventTrigger'}
    require(set(by)<=allowed,'Unsupported object category')
    require(all(r['meta']['kind'] in ('r','v') and not r['meta']['partition']
                and r['meta']['tableSpace'] in (0,'0') for r in by['relation']),
            'Unsupported relation/materialized/partition/tablespace')
    require(all(not r['meta']['sqlStandardBody'] for r in by['routine']),'SQL-standard bodies require explicit dependency support')
    require(all(r['meta']['valid'] and r['meta']['ready'] for r in by['index']),'Invalid source index')
    roles=set(bootstrap['roles'])
    sql=['\\set ON_ERROR_STOP on','BEGIN;',"SET LOCAL statement_timeout='120s';",
         "SET LOCAL check_function_bodies=off;","SET LOCAL search_path='';"]
    for role in sorted(roles):
        if role.startswith('pg_'):continue
        sql.append('DO $role$ BEGIN IF NOT EXISTS(SELECT FROM pg_catalog.pg_roles WHERE rolname='+lit(role)+
                   ') THEN CREATE ROLE '+q(role)+' NOLOGIN; END IF; END $role$;')
    # All following SQL is executed ONLY in an empty owned disposable container.
    for schema in manifest['scope']: sql.append('DROP SCHEMA IF EXISTS '+q(schema)+' CASCADE;')
    for ext in bootstrap['extensions']:
        if ext['name']!='plpgsql':sql.append('DROP EXTENSION IF EXISTS '+q(ext['name'])+' CASCADE;')
    for r in by['schema']:
        sql.append('CREATE SCHEMA '+q(r['ident'])+' AUTHORIZATION '+q(r['meta']['owner'])+';')
    for ext in bootstrap['extensions']:
        if ext['name']=='plpgsql':continue
        sql.append('CREATE EXTENSION IF NOT EXISTS '+q(ext['name'])+' WITH SCHEMA '+q(ext['schema'])+
                   ' VERSION '+lit(ext['version'])+';')
    sql.extend(["SET LOCAL check_function_bodies=off;","SET LOCAL search_path='';"])
    for auth in bootstrap['managedAuthFunctions']:
        sql.append(auth['definition'].rstrip().rstrip(';')+';')
    for r in by['enum']:
        sql.append('CREATE TYPE '+r['ident']+' AS ENUM ('+', '.join(map(lit,r['meta']['labels']))+');')
        sql.append('ALTER TYPE '+r['ident']+' OWNER TO '+q(r['meta']['owner'])+';')
    def sequence_options(m):
        return (' START WITH '+m['start']+' INCREMENT BY '+m['increment']+' MINVALUE '+m['min']+
                ' MAXVALUE '+m['max']+' CACHE '+m['cache']+(' CYCLE' if m['cycle'] else ' NO CYCLE'))
    identity_sequences={}
    for r in by['sequence']:
        m=r['meta']
        if m['dependency']=='i':identity_sequences[(m['table'],m['column'])]=r;continue
        sql.append('CREATE SEQUENCE '+r['ident']+' AS '+m['type']+sequence_options(m)+';')
    routines={r['ident']:r for r in by['routine']}
    early={k for k,r in routines.items() if not r['meta']['tableType'] and not r['meta']['tableDefault']}
    while True:
        retained={k for k in early if not((set(routines[k]['meta']['dependencies']) & routines.keys())-early)}
        if retained==early:break
        early=retained
    def routine(r):
        sql.append(r['meta']['definition'].rstrip().rstrip(';')+';')
        sql.append('ALTER '+('PROCEDURE' if r['meta']['kind']=='p' else 'FUNCTION')+' '+r['ident']+
                   ' OWNER TO '+q(r['meta']['owner'])+';')
    for r in ordered([r for k,r in routines.items() if k in early]):routine(r)
    for r in by['relation']:
        m=r['meta']
        if m['kind']!='r':continue
        columns=[]
        for c in m['columns']:
            line=q(c['name'])+' '+c['type']
            if c['collation']:line+=' COLLATE '+c['collation']
            if c['identity']:
                seq=identity_sequences[(r['ident'],c['name'])]
                line+=' GENERATED '+('ALWAYS' if c['identity']=='a' else 'BY DEFAULT')+' AS IDENTITY (SEQUENCE NAME '+seq['ident']+sequence_options(seq['meta'])+')'
            elif c['generated']:
                require(c['generated']=='s','Unsupported generated-column mode')
                line+=' GENERATED ALWAYS AS ('+c['default']+') STORED'
            elif c['default'] is not None:line+=' DEFAULT '+c['default']
            if c['notnull']:line+=' NOT NULL'
            columns.append(line)
        sql.append('CREATE '+('UNLOGGED ' if m['persistence']=='u' else '')+'TABLE '+r['ident']+' (\n'+',\n'.join(columns)+'\n);')
        sql.append('ALTER TABLE '+r['ident']+' OWNER TO '+q(m['owner'])+';')
    # Establish view row types before routines returning/accepting those types.
    for r in by['relation']:
        if r['meta']['kind']!='v':continue
        sql.append('CREATE VIEW '+r['ident']+' AS SELECT '+', '.join('NULL::'+c['type']+' AS '+q(c['name']) for c in r['meta']['columns'])+';')
    for r in ordered([r for k,r in routines.items() if k not in early]):routine(r)
    for foreign in [False]:
        for r in by['constraint']:
            m=r['meta']
            if not m['local'] or m['type']=='t' or (m['type']=='f')!=foreign:continue
            sql.append('ALTER TABLE ONLY '+m['table']+' ADD CONSTRAINT '+q(m['name'])+' '+m['definition']+';')
            if m['type'] in ('p','u','x') and m['index']!=m['name']:
                schema=m['table'].rsplit('.',1)[0]
                sql.append('ALTER INDEX '+schema+'.'+q(m['name'])+' RENAME TO '+q(m['index'])+';')
    for r in ordered([r for r in by['relation'] if r['meta']['kind']=='v']):
        sql.append('CREATE OR REPLACE VIEW '+r['ident']+' AS '+r['meta']['definition'].rstrip().rstrip(';')+';')
        sql.append('ALTER VIEW '+r['ident']+' OWNER TO '+q(r['meta']['owner'])+';')
    for r in by['sequence']:
        m=r['meta']
        if m['dependency']=='i':continue
        sql.append('ALTER SEQUENCE '+r['ident']+' OWNER TO '+q(m['owner'])+';')
        if m['table'] and m['column']:sql.append('ALTER SEQUENCE '+r['ident']+' OWNED BY '+m['table']+'.'+q(m['column'])+';')
    for r in by['index']:
        if r['meta']['constraint'] is None:sql.append(r['meta']['definition']+';')
    for foreign in [True]:
        for r in by['constraint']:
            m=r['meta']
            if not m['local'] or m['type']=='t' or (m['type']=='f')!=foreign:continue
            sql.append('ALTER TABLE ONLY '+m['table']+' ADD CONSTRAINT '+q(m['name'])+' '+m['definition']+';')
            if m['type'] in ('p','u','x') and m['index']!=m['name']:
                schema=m['table'].rsplit('.',1)[0]
                sql.append('ALTER INDEX '+schema+'.'+q(m['name'])+' RENAME TO '+q(m['index'])+';')
    for r in by['relation']:
        m=r['meta'];target=('VIEW ' if m['kind']=='v' else 'TABLE ')+r['ident']
        if m['options']:sql.append('ALTER '+target+' SET ('+', '.join(q(s.split('=',1)[0])+'='+lit(s.split('=',1)[1]) for s in m['options'])+');')
        if m['kind']=='r':
            if m['rls']:sql.append('ALTER TABLE '+r['ident']+' ENABLE ROW LEVEL SECURITY;')
            if m['forceRls']:sql.append('ALTER TABLE '+r['ident']+' FORCE ROW LEVEL SECURITY;')
            if m['replicaIdentity']!='d':
                mode={'f':'FULL','n':'NOTHING','i':'USING INDEX '+q(m['replicaIndex'] or '')}[m['replicaIdentity']]
                sql.append('ALTER TABLE '+r['ident']+' REPLICA IDENTITY '+mode+';')
    for r in by['trigger']:
        m=r['meta'];sql.append('DROP TRIGGER IF EXISTS '+q(m['name'])+' ON '+m['table']+';')
        sql.append(m['definition']+';')
        if m['enabled']!='O':sql.append('ALTER TABLE '+m['table']+' '+{'D':'DISABLE','R':'ENABLE REPLICA','A':'ENABLE ALWAYS'}[m['enabled']]+' TRIGGER '+q(m['name'])+';')
    for r in by['policy']:
        m=r['meta'];statement='CREATE POLICY '+q(m['name'])+' ON '+m['table']
        statement+=' AS '+('PERMISSIVE' if m['permissive'] else 'RESTRICTIVE')
        statement+=' FOR '+{'*':'ALL','r':'SELECT','a':'INSERT','w':'UPDATE','d':'DELETE'}[m['command']]
        statement+=' TO '+', '.join('PUBLIC' if x=='PUBLIC' else q(x) for x in m['roles'])
        if m['using'] is not None:statement+=' USING ('+m['using']+')'
        if m['check'] is not None:statement+=' WITH CHECK ('+m['check']+')'
        sql.append(statement+';')
    for kind,keyword in [('schema','SCHEMA'),('enum','TYPE'),('sequence','SEQUENCE'),('relation','TABLE'),('routine','FUNCTION')]:
        for r in by[kind]:
            target=('PROCEDURE' if kind=='routine' and r['meta']['kind']=='p' else keyword)+' '+(q(r['ident']) if kind=='schema' else r['ident'])
            sql.extend(grants(target,r['meta']['acl'],roles))
    for r in by['relation']:
        for column in r['meta']['columns']:
            if column['acl'] is None:continue
            suffix=' ON TABLE '+r['ident']
            codes=('SELECT','INSERT','UPDATE','REFERENCES')
            sql.append('REVOKE '+', '.join(code+' ('+q(column['name'])+')' for code in codes)+
                       suffix+' FROM '+', '.join(['PUBLIC',*map(q,sorted(roles))])+';')
            for grantee,code,option,grantor in acl_rows(column['acl']):
                require(code in ('r','a','w','x'),'Unsupported column privilege')
                sql.append('SET ROLE '+q(grantor)+';')
                sql.append('GRANT '+PRIVS[code]+' ('+q(column['name'])+')'+suffix+' TO '+
                           ('PUBLIC' if grantee=='PUBLIC' else q(grantee))+(' WITH GRANT OPTION' if option else '')+';')
                sql.append('RESET ROLE;')
    for r in by['defaultAcl']:
        m=r['meta'];prefix='ALTER DEFAULT PRIVILEGES FOR ROLE '+q(m['owner'])
        if m['schema']:prefix+=' IN SCHEMA '+q(m['schema'])
        target={'r':'TABLES','S':'SEQUENCES','f':'FUNCTIONS','T':'TYPES','n':'SCHEMAS'}[m['type']]
        sql.append(prefix+' REVOKE ALL ON '+target+' FROM PUBLIC;')
        sql.append(prefix+' REVOKE ALL ON '+target+' FROM '+', '.join(map(q,sorted(roles)))+';')
        for grantee,code,option,_ in acl_rows(m['acl']):
            sql.append(prefix+' GRANT '+PRIVS[code]+' ON '+target+' TO '+('PUBLIC' if grantee=='PUBLIC' else q(grantee))+(' WITH GRANT OPTION' if option else '')+';')
    # Event triggers last: no restored DDL should invoke an application hook.
    for r in by['eventTrigger']:
        m=r['meta'];statement='CREATE EVENT TRIGGER '+q(r['ident'])+' ON '+m['event']
        if m['tags']:statement+=' WHEN TAG IN ('+', '.join(map(lit,m['tags']))+')'
        statement+=' EXECUTE FUNCTION '+m['function']+';';sql.append(statement)
        if m['enabled']!='O':sql.append('ALTER EVENT TRIGGER '+q(r['ident'])+' '+{'D':'DISABLE','R':'ENABLE REPLICA','A':'ENABLE ALWAYS'}[m['enabled']]+';')
    for publication in bootstrap['publications']:
        sql.append('DROP PUBLICATION IF EXISTS '+q(publication['name'])+';')
        statement='CREATE PUBLICATION '+q(publication['name'])
        if publication['allTables']:statement+=' FOR ALL TABLES'
        elif publication['relations']:
            tables=[]
            for relation in publication['relations']:
                entry=relation['table']
                if relation['columns']:entry+=' ('+', '.join(map(q,relation['columns']))+')'
                if relation['filter']:entry+=' WHERE ('+relation['filter']+')'
                tables.append(entry)
            statement+=' FOR TABLE '+', '.join(tables)
        events=','.join(k for k in ('insert','update','delete','truncate') if publication[k])
        statement+=' WITH (publish='+lit(events)+',publish_via_partition_root='+str(publication['viaRoot']).lower()+');'
        sql.append(statement)
    references=reference_sql(name,area)
    if references:sql.append(references)
    sql.append('COMMIT;')
    output=area/(name+'-reconstructed.sql');output.write_text('\n'.join(sql)+'\n');output.chmod(0o600)
    print(name,'catalog objects',len(objects),'private SQL bytes',output.stat().st_size)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('name',choices=['pos','office'])
    parser.add_argument('--snapshot-dir',type=Path,required=True)
    args=parser.parse_args();assemble(args.name,args.snapshot_dir)
