import type { Express } from 'express';
import multer from 'multer';
import { DomainError } from '../../domain/ledger.js';
import { contractInput,contractQuery } from '../../domain/contracts.js';
import { actor, key, payloadHash, route, rpc } from '../../http/request.js';
import { parseOfficialFile } from './parser.js';

const upload=multer({storage:multer.memoryStorage(),limits:{fileSize:10*1024*1024,files:1,fields:1,fieldSize:256,parts:2}});
function page(req: {query:Record<string,unknown>}) {
  const parsed={...req.query};if(typeof parsed.limit==='string'&&/^\d+$/.test(parsed.limit))parsed.limit=Number(parsed.limit);
  const q=contractQuery('getImport',parsed);
  if(Object.keys(q).some(k=>!['limit','rows_cursor','reconciliation_cursor'].includes(k)))throw new DomainError(422,'VALIDATION_ERROR','分页参数不合法。');
  const number=(value:unknown,fallback:number,max:number)=>{if(value===undefined)return fallback;
    if(typeof value!=='string'||!/^\d+$/.test(value)||!Number.isSafeInteger(Number(value))||Number(value)>max)throw new DomainError(422,'VALIDATION_ERROR','分页参数不合法。');return Number(value);};
  const limit=q.limit??50;if(!Number.isInteger(limit)||limit<1||limit>100)throw new DomainError(422,'VALIDATION_ERROR','分页数量须为1到100。');
  return {p_limit:limit,p_rows:number(q.rows_cursor,0,10000),p_reconciliation:number(q.reconciliation_cursor,0,Number.MAX_SAFE_INTEGER)};
}
export function registerImportRoutes(app:Express) {
  app.post('/api/v1/imports',upload.single('file'),route(async(req,res)=>{
    if(!req.file || Object.keys(req.body??{}).some(k=>k!=='source_account_profile_id') ||
      (req.body.source_account_profile_id!==undefined && (typeof req.body.source_account_profile_id!=='string'||!req.body.source_account_profile_id)))throw new DomainError(422,'VALIDATION_ERROR','请选择官方文件，并检查来源档案。');
    const parsed=await parseOfficialFile(req.file.buffer,req.file.originalname);
    const profile=req.body.source_account_profile_id??null;
    const result=await rpc(req,'sl_import_upload',{p_actor_subject:actor(req),p_key_digest:key(req),p_payload_hash:payloadHash({file_hash:parsed.file_hash,profile}),p_input:parsed,p_profile:profile});
    res.status(201).json(result);
  }));
  app.get('/api/v1/imports/:batchId',route(async(req,res)=>{
    res.json(await rpc(req,'sl_import_json',{p_subject:actor(req),p_batch:req.params.batchId,...page(req)}));
  }));
  app.post('/api/v1/imports/:batchId/resolutions',route(async(req,res)=>{
    const input=contractInput('Resolution',req.body);
    res.json(await rpc(req,'sl_import_resolve',{p_actor_subject:actor(req),p_batch:req.params.batchId,p_key_digest:key(req),p_payload_hash:payloadHash(input),p_input:input}));
  }));
  app.get('/api/v1/source-payment-method-mappings',route(async(req,res)=>{
    if(Object.keys(req.query).some(k=>k!=='source_account_profile_id') || typeof req.query.source_account_profile_id!=='string'||!req.query.source_account_profile_id)throw new DomainError(422,'VALIDATION_ERROR','请选择来源档案。');
    res.json({data:await rpc(req,'sl_list_mappings',{p_actor_subject:actor(req),p_profile:req.query.source_account_profile_id})});
  }));
  app.put('/api/v1/source-payment-method-mappings',route(async(req,res)=>{
    res.json({data:await rpc(req,'sl_put_mapping',{p_actor_subject:actor(req),p_input:contractInput('MappingPut',req.body)})});
  }));
  app.post('/api/v1/imports/:batchId/reconciliation-reviews',route(async(req,res)=>{
    const input=contractInput('ReviewRequest',req.body);
    res.json({data:await rpc(req,'sl_review_reconciliation',{p_actor_subject:actor(req),p_batch:req.params.batchId,p_key_digest:key(req),p_payload_hash:payloadHash(input),p_input:input})});
  }));
}
