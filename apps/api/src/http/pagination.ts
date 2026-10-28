import {createHash,createHmac,timingSafeEqual} from 'node:crypto';
import {canonicalJson,DomainError} from '../domain/ledger.js';
import {contractQuery} from '../domain/contracts.js';
type Position={time:string;id:string};
const bad=()=>new DomainError(422,'VALIDATION_ERROR','筛选或分页位置不合法，请重新查询。');
function signature(text:string){
  const secret=process.env.CURSOR_SECRET||process.env.CLOUDBASE_API_KEY;
  if(!secret)throw new Error('Stable CURSOR_SECRET is required for pagination');
  return createHmac('sha256',secret).update(text).digest('base64url');
}
export function pageScope(subject:string,operation:string,filters:Record<string,unknown>){
  return createHash('sha256').update(canonicalJson({subject,operation,filters})).digest('hex');
}
export function encodeCursor(scope:string,position:Position|null):string|null {
  if(!position)return null;const body=Buffer.from(JSON.stringify({scope,...position})).toString('base64url');return body+'.'+signature(body);
}
export function decodeCursor(scope:string,cursor:unknown):Position|null {
  if(cursor===undefined)return null;
  if(typeof cursor!=='string'||cursor.length>2048)throw bad();const [body,sig,...extra]=cursor.split('.');
  if(!body||!sig||extra.length)throw bad();const expected=Buffer.from(signature(body)),received=Buffer.from(sig);
  if(expected.length!==received.length||!timingSafeEqual(expected,received))throw bad();
  try{const p=JSON.parse(Buffer.from(body,'base64url').toString());
    if(p.scope!==scope||typeof p.time!=='string'||Number.isNaN(Date.parse(p.time))||!/^[-0-9a-f]{36}$/.test(p.id))throw bad();
    return {time:p.time,id:p.id};
  }catch{throw bad();}
}
export function listQuery(operation:'listAccounts'|'listTransactions',input:Record<string,unknown>){
  const parsed={...input};if(typeof parsed.limit==='string'&&/^\d+$/.test(parsed.limit))parsed.limit=Number(parsed.limit);
  const q=contractQuery(operation,parsed);q.view??='mine';q.limit??=50;
  for(const key of ['from','to'])if(q[key]!==undefined){const d=new Date(q[key]+'T00:00:00Z');
    if(!/^\d{4}-\d{2}-\d{2}$/.test(q[key])||q[key].startsWith('0000')||Number.isNaN(d.valueOf())||d.toISOString().slice(0,10)!==q[key])throw bad();}
  if(q.from&&q.to&&q.from>q.to)throw bad();
  const {cursor,limit,view,...filters}=q;return {cursor,limit:limit as number,view:view as string,filters};
}
