import { createWithKey, request, requestEnvelope, withRequestIntent, type Session } from '../../api/client';
export type Profile={id:string;platform:'wechat'|'alipay';label:string};
export type ImportRow={observation_id:string;row_number:number;source_record_id:string|null;source_version:number|null;
  phase:string;disposition:string;reason_codes:string[];evidence:{raw_fields:Record<string,unknown>;canonical_method_keys:string[];source_direction:string};
  candidate:{type:string|null;amount_minor:number|null;occurred_at:string|null;merchant:string;note:string;[key:string]:unknown};
  transaction_id:string|null;candidate_transaction_ids:string[];allowed_actions:string[]};
export type Reconciliation={id:string;transaction_id:string;source_account_profile_id:string;status:string;version:number};
export type ImportBatch={batch_id:string;platform:string;status:string;source_account_profile:Profile|null;profile_version:number;
  profile_candidates:Profile[];summary:Record<string,number>;coverage:{reconciliation_eligible:boolean;blockers:string[];[key:string]:unknown};
  source_metadata:Record<string,unknown>;rows:ImportRow[];reconciliation_items:Reconciliation[]};
export type ImportResponse={data:ImportBatch;page:{rows_next_cursor:string|null;reconciliation_next_cursor:string|null}};
export type Mapping={id:string;source_account_profile_id:string;canonical_method_key:string;account_id:string;version:number};
export const getImport=(s:Session,id:string,query='')=>requestEnvelope<ImportResponse>(s,`/imports/${encodeURIComponent(id)}${query}`);
export const resolveImport=(s:Session,id:string,input:Record<string,unknown>)=>createWithKey<ImportBatch>(s,`/imports/${id}/resolutions`,input);
export const mappings=(s:Session,profile:string)=>request<Mapping[]>(s,`/source-payment-method-mappings?source_account_profile_id=${encodeURIComponent(profile)}`);
export const putMapping=(s:Session,input:Record<string,unknown>)=>request<Mapping>(s,'/source-payment-method-mappings',{method:'PUT',body:JSON.stringify(input)});
export const review=(s:Session,id:string,input:Record<string,unknown>)=>createWithKey(s,`/imports/${id}/reconciliation-reviews`,input);
export async function uploadFile(s:Session,file:File,profile?:string) {
  if(file.size>10*1024*1024)throw new Error('文件不能超过10MiB，请缩小导出范围。');
  const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await file.arrayBuffer())),v=>v.toString(16).padStart(2,'0')).join('');
  return withRequestIntent(s,'/imports',{file_hash:hash,profile:profile??null},key=>{
    const form=new FormData();form.append('file',file);if(profile)form.append('source_account_profile_id',profile);
    return requestEnvelope<ImportResponse>(s,'/imports',{method:'POST',headers:{'Idempotency-Key':key},body:form});
  });
}
