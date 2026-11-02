/* Atomic order intent storage. Independent of Auth/menu/KDS databases. */
(() => {
  'use strict';
  const name='globos-pos-order-intents-v1', store='intents';
  const terminal=new Set(['confirmed','rejected']);
  const identity=['version','operation','project','actor','store','kind','target','payload','createdAt'];
  const transitions={prepared:['unknown','confirmed','rejected'],unknown:['confirmed','rejected']};
  const size=v=>new TextEncoder().encode(JSON.stringify(v)).length;
  const slot=r=>JSON.stringify([r.project,r.actor,r.store,r.kind,r.target]);
  function validate(r) {
    if(!r||r.version!==1||!['create','add'].includes(r.kind)||
      !Number.isSafeInteger(r.createdAt)||r.createdAt<=0||!Number.isSafeInteger(r.revision)||r.revision<1||
      !['prepared','unknown',...terminal].includes(r.phase)||typeof r.payload!=='string'||size(r)>256*1024||
      ['operation','project','actor','store','target'].some(k=>typeof r[k]!=='string'||!r[k]||r[k].length>256))throw Error('ORDER_JOURNAL_INVALID');
    const p=JSON.parse(r.payload);
    if(!p||typeof p!=='object'||Array.isArray(p)||p.p_store_id!==r.store||!Array.isArray(p.p_items)||
      !p.p_items.length||p.p_items.length>500||p[r.kind==='create'?'p_table_id':'p_order_id']!==r.target||
      Object.hasOwn(p,'p_client_mutation_id'))throw Error('ORDER_JOURNAL_PAYLOAD_INVALID');
  }
  async function open() {
    return new Promise((resolve,reject)=>{
      const request=indexedDB.open(name,1);
      request.onupgradeneeded=()=>{
        const object=request.result.createObjectStore(store,{keyPath:'slot'});
        object.createIndex('operation','operation',{unique:true});
      };
      request.onsuccess=()=>resolve(request.result);
      request.onerror=()=>reject(request.error);
      request.onblocked=()=>reject(Error('ORDER_JOURNAL_BLOCKED'));
    });
  }
  window.globosOrderIntentJournal=async(action,inputJson)=>{
    const input=JSON.parse(inputJson), db=await open();
    try {
      return await new Promise((resolve,reject)=>{
        let result, failure;
        const tx=db.transaction(store,action==='list'?'readonly':'readwrite',{durability:'strict'});
        const object=tx.objectStore(store), request=object.getAll();
        request.onsuccess=()=>{
          try {
            const stored=request.result;
            if(stored.length>100) throw Error('ORDER_JOURNAL_FULL');
            const rows=stored.map(({slot:storedSlot,...r})=>{validate(r);if(storedSlot!==slot(r))throw Error('ORDER_JOURNAL_INVALID');return r;});
            if(size(rows)>4*1024*1024)throw Error('ORDER_JOURNAL_FULL');
            if(action==='list') {
              result=rows.filter(r=>r.project===input.project&&r.actor===input.actor&&r.store===input.store);return;
            }
            if(action==='settle') {
              if(!Array.isArray(input.operations)||input.operations.length>100||input.operations.some(v=>typeof v!=='string'))throw Error('ORDER_JOURNAL_SETTLE_INVALID');
              const rejected=input.rejected||[];
              if(!Array.isArray(rejected)||rejected.length>100||rejected.some(v=>typeof v!=='string'))throw Error('ORDER_JOURNAL_SETTLE_INVALID');
              const ids=new Set(input.operations), failures=new Set(rejected);
              for(const r of rows)if(r.project===input.project&&r.actor===input.actor&&r.store===input.store){
                if(ids.has(r.operation)||r.phase==='confirmed')object.delete(slot(r));
                else if(failures.has(r.operation)&&!terminal.has(r.phase))object.put({...r,slot:slot(r),phase:'rejected',revision:r.revision+1});
              }
              result=null;return;
            }
            const c=input.record;validate(c);
            const key=slot(c), existing=rows.find(r=>slot(r)===key);
            if(action==='claim') {
              if(existing){result=existing;return;}
              if(c.phase!=='prepared'||c.revision!==1||rows.some(r=>r.operation===c.operation))throw Error('ORDER_JOURNAL_CONFLICT');
              if(rows.length>=100)throw Error('ORDER_JOURNAL_FULL');
              rows.push(c);
            } else {
              if(!existing||existing.operation!==c.operation)throw Error('ORDER_JOURNAL_CONFLICT');
              if(identity.some(k=>c[k]!==existing[k]))throw Error('ORDER_JOURNAL_IDENTITY_CHANGED');
              if(input.expectedRevision!==existing.revision){result=existing;return;}
              if(action==='retire'){
                if(!terminal.has(existing.phase))throw Error('ORDER_JOURNAL_UNRESOLVED');
                object.delete(key);result=null;return;
              }
              if(action!=='update'||c.revision!==existing.revision+1||!transitions[existing.phase]?.includes(c.phase))throw Error('ORDER_JOURNAL_TRANSITION');
              rows[rows.indexOf(existing)]=c;
            }
            if(size(rows)>4*1024*1024)throw Error('ORDER_JOURNAL_FULL');
            object.put({...c,slot:key});result=c;
          } catch(error){failure=error;tx.abort();}
        };
        tx.oncomplete=()=>resolve(JSON.stringify(result));
        tx.onabort=tx.onerror=()=>reject(failure||tx.error||Error('ORDER_JOURNAL_FAILED'));
      });
    } finally { db.close(); }
  };
})();
