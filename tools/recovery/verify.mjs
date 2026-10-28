import {PGlite} from '@electric-sql/pglite';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {tables} from './catalog.mjs';
import {restoreSnapshot} from './lib/snapshot.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
const input=process.argv[2];if(!input)throw new Error('Provide a private logical snapshot path. This tool never contacts CloudBase.');
const raw=await readFile(resolve(input),'utf8'),backup=JSON.parse(raw);
const pg=await PGlite.create();
try{
 const restored=await restoreSnapshot(root,backup,pg);
 // Independent business expectations for the documented synthetic fixture.
 const subject='sl-recovery-20261028';
 const overview=(await pg.query('SELECT public.sl_overview_at($1,$2,$3::date) AS value',[subject,'2026-10','2026-10-28'])).rows[0].value;
 assert.equal(overview.personal_spending.month_spent_minor,1245);
 const accounts=(await pg.query('SELECT public.sl_list_accounts_visible($1,\'mine\') AS value',[subject])).rows[0].value;
 assert.deepEqual(accounts.map(a=>a.balance_minor).sort((a,b)=>a-b),[200,13555]);
 const oldSequence=BigInt(backup.sequence.last_value);
 const key='9'.repeat(64),account=accounts.find(a=>a.name==='Synthetic recovery B');
 const body={type:'income',account_id:account.id,amount_minor:10,occurred_at:'2026-10-13T12:00:00+08:00',category_code:'other',merchant:'restored write',note:''};
 const one=(await pg.query('SELECT public.sl_create_transaction($1,$2,$2,$3::jsonb) AS value',[subject,key,JSON.stringify(body)])).rows[0].value;
 const two=(await pg.query('SELECT public.sl_create_transaction($1,$2,$2,$3::jsonb) AS value',[subject,key,JSON.stringify(body)])).rows[0].value;
 assert.deepEqual(one,two,'Restored idempotency failed');assert.ok(BigInt((await pg.query('SELECT last_value::text AS n FROM public.sl_replay_order_seq')).rows[0].n)>oldSequence);
 const report={format:backup.format,snapshot_sha256:createHash('sha256').update(raw).digest('hex'),target:'independent local PGlite PostgreSQL; no CloudBase connection',
  migrations:restored.migrations,tables:Object.fromEntries(tables.map(t=>[t,JSON.parse(backup.tables[t]).length])),schema_and_grants_equal:true,data_equal_before_new_write:true,
  expected_balances_minor:[200,13555],expected_net_spending_minor:1245,post_restore_write_and_idempotency:true,
  excludes:['CloudBase Auth credentials/providers/sessions','pgstore/COS objects','hosting/functions/gateway/secrets','platform snapshot/PITR and replacement environment recovery']};
 await writeFile(resolve(root,'tmp/recovery/verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}catch(error){console.error(error.message);process.exitCode=1;}finally{await pg.close();}
