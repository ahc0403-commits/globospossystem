/* Atomic financial intent storage. Independent of Auth/menu/KDS databases. */
(() => {
  'use strict';
  const name='globos-pos-payment-intents-v1', store='intents';
  const terminal=new Set(['confirmed','cancelled','rejected']);
  const identity=['version','operation','project','actor','store','order','amount','method','expectedCount','full','createdAt','tableNumber'];
  const transitions={prepared:['sending','cancelling','rejected'],sending:['unknown','confirmed','cancelling','rejected'],unknown:['confirmed','cancelling','rejected'],cancelling:['confirmed','cancelled']};
  const size=v=>new TextEncoder().encode(JSON.stringify(v)).length;
  const slot=r=>JSON.stringify([r.project,r.actor,r.store,r.order]);
  function validate(r) {
    if(r?.tableNumber!=null&&(typeof r.tableNumber!=='string'||r.tableNumber.length>128))throw Error('PAYMENT_JOURNAL_INVALID');
    if(!r||r.version!==1||r.full!==true||!Number.isFinite(r.amount)||r.amount<=0||
      !Number.isSafeInteger(r.expectedCount)||r.expectedCount<0||!Number.isSafeInteger(r.createdAt)||r.createdAt<=0||
      !Number.isSafeInteger(r.revision)||r.revision<1||!['prepared','sending','unknown','cancelling',...terminal].includes(r.phase)||size(r)>8192||
      ['operation','project','actor','store','order','method'].some(k=>typeof r[k]!=='string'||!r[k]||r[k].length>256)) throw Error('PAYMENT_JOURNAL_INVALID');
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
      request.onblocked=()=>reject(Error('PAYMENT_JOURNAL_BLOCKED'));
    });
  }
  window.globosPaymentIntentJournal=async(action,inputJson)=>{
    const input=JSON.parse(inputJson), db=await open();
    try {
      return await new Promise((resolve,reject)=>{
        let result, failure;
        const tx=db.transaction(store,action==='list'?'readonly':'readwrite',{durability:'strict'});
        const object=tx.objectStore(store), request=object.getAll();
        request.onsuccess=()=>{
          try {
            const stored=request.result;
            if(stored.length>100) throw Error('PAYMENT_JOURNAL_FULL');
            const rows=stored.map(({slot:storedSlot,...r})=>{validate(r);if(storedSlot!==slot(r))throw Error('PAYMENT_JOURNAL_INVALID');return r;});
            if(action==='list') {
              result=rows.filter(r=>r.project===input.project&&r.actor===input.actor&&r.store===input.store);return;
            }
            const c=input.record;validate(c);
            const key=slot(c), existing=rows.find(r=>slot(r)===key);
            if(action==='claim') {
              if(existing){result=existing;return;}
              if(c.phase!=='prepared'||c.revision!==1||rows.some(r=>r.operation===c.operation))throw Error('PAYMENT_JOURNAL_CONFLICT');
              if(rows.length>=100)throw Error('PAYMENT_JOURNAL_FULL');
              rows.push(c);
            } else {
              if(!existing||existing.operation!==c.operation)throw Error('PAYMENT_JOURNAL_CONFLICT');
              if(identity.some(k=>c[k]!==existing[k]))throw Error('PAYMENT_JOURNAL_IDENTITY_CHANGED');
              if(input.expectedRevision!==existing.revision){result=existing;return;}
              if(action==='retire'){
                if(!terminal.has(existing.phase))throw Error('PAYMENT_JOURNAL_UNRESOLVED');
                object.delete(key);result=null;return;
              }
              if(action!=='update'||c.revision!==existing.revision+1||!transitions[existing.phase]?.includes(c.phase))throw Error('PAYMENT_JOURNAL_TRANSITION');
              rows[rows.indexOf(existing)]=c;
            }
            if(size(rows)>256*1024)throw Error('PAYMENT_JOURNAL_FULL');
            object.put({...c,slot:key});result=c;
          } catch(error){failure=error;tx.abort();}
        };
        tx.oncomplete=()=>resolve(JSON.stringify(result));
        tx.onabort=tx.onerror=()=>reject(failure||tx.error||Error('PAYMENT_JOURNAL_FAILED'));
      });
    } finally { db.close(); }
  };
})();
