import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {tables,schemaSql,rowsSql} from './catalog.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
const input=process.argv[2];if(!input)throw new Error('Provide a private logical snapshot path. This tool never contacts CloudBase.');
const raw=await readFile(resolve(input),'utf8'),backup=JSON.parse(raw);
assert.equal(backup.format,'star-ledger-logical-v1');assert.deepEqual(Object.keys(backup.tables).sort(),[...tables].sort());
const pg=await PGlite.create();
try{
 await pg.exec('CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;');
 const files=(await readdir(resolve(root,'cloudbase/migrations'))).filter(n=>n.endsWith('.sql')).sort();
 assert.deepEqual(files,backup.migrations.map(m=>m.name),'The snapshot requires its exact migration set');
 for(const [i,name] of files.entries()){
  const bytes=await readFile(resolve(root,'cloudbase/migrations',name));
  const lf=bytes.toString().replaceAll('\r\n','\n');
  // Accept historical snapshots hashed before Git line-ending normalization.
  const hashes=[bytes,lf,lf.replaceAll('\n','\r\n')].map(text=>createHash('sha256').update(text).digest('hex'));
  assert.ok(hashes.includes(backup.migrations[i].sha256),'Migration changed: '+name);
  try{await pg.exec(bytes.toString());}catch(e){throw new Error('Migration failed: '+name,{cause:e});}
 }
 const schema=(await pg.query(schemaSql)).rows[0].schema;
 // PostgreSQL 18 additionally catalogs NOT NULL as constraints. Nullability is
 // compared independently in columns, so exclude only this redundant encoding.
 schema.constraints=schema.constraints.filter(c=>!c[2].startsWith('NOT NULL '));
 for(const key of Object.keys(backup.schema)){
  if(JSON.stringify(schema[key])!==JSON.stringify(backup.schema[key])){
   await writeFile(resolve(root,'tmp/recovery/schema-difference.json'),JSON.stringify({key,local:schema[key],source:backup.schema[key]},null,2));
   throw new Error('Source schema differs at '+key+'; inspect the private schema-difference.json');
  }
 }
 await pg.query("SELECT set_config('TimeZone',$1,false)",[backup.timezone]);
 await pg.transaction(async tx=>{
  for(const table of tables){
   assert.equal((await tx.query(`SELECT count(*)::text AS n FROM public.${table}`)).rows[0].n,'0','Restore target must be empty');
   // Break only the source<->observation cycle; the original pointer is restored below.
   const source=table==='sl_source_records'?JSON.stringify(JSON.parse(backup.tables[table]).map(r=>({...r,current_observation_id:null}))):backup.tables[table];
   await tx.query(`INSERT INTO public.${table} SELECT * FROM jsonb_populate_recordset(NULL::public.${table},$1::jsonb)`,[source]);
  }
  await tx.query(`UPDATE public.sl_source_records t SET current_observation_id=s.current_observation_id FROM jsonb_populate_recordset(NULL::public.sl_source_records,$1::jsonb) s WHERE t.id=s.id`,[backup.tables.sl_source_records]);
  await tx.query("SELECT setval('public.sl_replay_order_seq',$1::bigint,$2)",[backup.sequence.last_value,backup.sequence.is_called]);
  for(const table of tables)assert.equal((await tx.query(rowsSql(table))).rows[0].data,backup.tables[table],'Data differs: '+table);
 });
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
  migrations:files.length,tables:Object.fromEntries(tables.map(t=>[t,JSON.parse(backup.tables[t]).length])),schema_and_grants_equal:true,data_equal_before_new_write:true,
  expected_balances_minor:[200,13555],expected_net_spending_minor:1245,post_restore_write_and_idempotency:true,
  excludes:['CloudBase Auth credentials/providers/sessions','pgstore/COS objects','hosting/functions/gateway/secrets','platform snapshot/PITR and replacement environment recovery']};
 await writeFile(resolve(root,'tmp/recovery/verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}catch(error){console.error(error.message);process.exitCode=1;}finally{await pg.close();}
