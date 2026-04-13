import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BASE = Deno.env.get("WETAX_BASE_URL") ?? "https://apitest.wetax.com.vn";

function decodeBytea(v: unknown): string {
  if (!v) return "";
  if (v instanceof Uint8Array) return new TextDecoder().decode(v);
  const s = String(v);
  const m = s.match(/^[\\]?x([0-9a-fA-F]+)$/);
  if (m) { const b=new Uint8Array(m[1].length/2); for(let i=0;i<m[1].length;i+=2) b[i/2]=parseInt(m[1].substring(i,i+2),16); return new TextDecoder().decode(b); }
  try{return atob(s);}catch{return s;}
}

async function getToken(supabase: any): Promise<string> {
  const {data:cred} = await supabase.from("partner_credentials").select("id,user_id,password_value,current_token,token_expires_at").eq("data_source","VNPT_EPAY").single();
  if(!cred) throw new Error("no cred");
  const now=new Date(); const exp=cred.token_expires_at?new Date(cred.token_expires_at):null;
  if(cred.current_token&&exp&&now<new Date(exp.getTime()-15*60*1000)) return cred.current_token;
  const pw=decodeBytea(cred.password_value);
  const r=await fetch(`${BASE}/api/wtx/pa/v1/auth/login`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({user_id:cred.user_id,password:pw})});
  const b=await r.json(); if(!r.ok||!b?.data?.access_token) throw new Error(`WT00 ${r.status}`);
  await supabase.from("partner_credentials").update({current_token:b.data.access_token,token_expires_at:new Date(now.getTime()+(b.data.expires_in??86400)*1000).toISOString(),last_verified_at:now.toISOString(),updated_at:now.toISOString()}).eq("id",cred.id);
  return b.data.access_token;
}

async function post(url: string, h: any, body: any) {
  const r = await fetch(url,{method:"POST",headers:h,body:JSON.stringify(body)});
  return {http:r.status, body:await r.json().catch(()=>null)};
}

serve(async (_req: Request) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const tok = await getToken(sb);
  const h = {"Content-Type":"application/json","Authorization":`Bearer ${tok}`};
  const url = `${BASE}/api/wtx/pa/v1/pos/invoices`;
  const ts = String(Date.now()).slice(-6);
  const r: any = {};

  // K: PDF 샘플과 최대한 동일하게 — 모든 타입 string, order_date 14자리, products[], bill_no, pos_no
  r.K = await post(url,h,{invoices:[{
    ref_id: `K${ts}-919a-026b-2cd2-cd251ddb9514`,
    cqt_code: "",
    store_code: "0319388179",
    store_name: "GLOBOSVN",
    order_date: "20260413152501",       // 14자리 yyyymmddhhmmss
    bill_no: `20260413DH${ts}`,
    pos_no: "001",
    trans_type: "1",
    currency_code: "VND",
    exchange_rate: "1.0",
    payment_method: "TM/CK",
    buyer_comp_name: "",
    buyer_comp_tax_code: "",
    buyer_comp_address: "",
    buyer_comp_tel: "",
    buyer_comp_email: "",
    buyer_nm: "",
    buyer_cccd: "",
    buyer_passport_no: "",
    buyer_budget_unit_code: "",
    products: [{
      feature: "1",
      seq: "1",
      item_code: "PHO001",
      item_name: "Test Pho Bo",
      uom: "EA",
      quantity: "1",
      unit_price: "80000",
      dc_rate: "",
      dc_amt: "",
      total_amount: "80000",
      vat_rate: "8%",
      vat_amount: "6400",
      paying_amount: "86400"
    }]
  }]});
  r.K.note = "EXACT PDF sample format: 14-char date, products[], all strings, bill_no, pos_no";

  // L: same but numbers (not strings)
  r.L = await post(url,h,{invoices:[{
    ref_id: `L${ts}-919a-026b-2cd2-cd251ddb9515`,
    cqt_code: "",
    store_code: "0319388179",
    store_name: "GLOBOSVN",
    order_date: "20260413152501",
    bill_no: `20260413DH${ts}L`,
    pos_no: "001",
    trans_type: 1,
    currency_code: "VND",
    exchange_rate: 1,
    payment_method: "TM/CK",
    buyer_comp_name: "",
    products: [{
      feature: 1,
      seq: 1,
      item_name: "Test Pho Bo",
      uom: "EA",
      quantity: 1,
      unit_price: 80000,
      dc_rate: 0,
      dc_amt: 0,
      total_amount: 80000,
      vat_rate: "8%",
      vat_amount: 6400,
      paying_amount: 86400
    }]
  }]});
  r.L.note = "same structure but numbers (not strings) for numeric fields";

  return new Response(JSON.stringify(r,null,2),{status:200,headers:{"Content-Type":"application/json"}});
});
