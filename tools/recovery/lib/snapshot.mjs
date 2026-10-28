// Shared logical snapshot format. These helpers never contact a cloud service.
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {tables,schemaSql,rowsSql} from '../catalog.mjs';
export async function migrationManifest(root){
  const files=(await readdir(resolve(root,'cloudbase/migrations'))).filter(n=>n.endsWith('.sql')).sort();
  return Promise.all(files.map(async name=>({name,sha256:createHash('sha256')
    .update((await readFile(resolve(root,'cloudbase/migrations',name),'utf8')).replaceAll('\r\n','\n')).digest('hex')})));
}
export async function exportSql(root){
  const manifest=JSON.stringify(await migrationManifest(root)).replaceAll("'","''");
  return `SELECT jsonb_build_object('format','star-ledger-logical-v1','environment','writter-dev-d0g7h1prq4ce60665',
 'captured_at',now(),'timezone',current_setting('TimeZone'),'migrations','${manifest}'::jsonb,'schema',(${schemaSql}),
 'tables',jsonb_build_object(${tables.map(t=>`'${t}',(${rowsSql(t)})`).join(',')}),
 'sequence',jsonb_build_object('last_value',(SELECT last_value::text FROM public.sl_replay_order_seq),'is_called',(SELECT is_called FROM public.sl_replay_order_seq)))::text AS snapshot;`;
}
export async function restoreSnapshot(root,backup,pg){
  assert.equal(backup.format,'star-ledger-logical-v1');assert.equal(backup.environment,'writter-dev-d0g7h1prq4ce60665');
  assert.deepEqual(Object.keys(backup.tables).sort(),[...tables].sort());
  const manifest=await migrationManifest(root);assert.deepEqual(manifest.map(m=>m.name),backup.migrations.map(m=>m.name),'Exact migration set required');
  await pg.exec('CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;');
  for(const [i,item] of manifest.entries()){
    const bytes=await readFile(resolve(root,'cloudbase/migrations',item.name)),lf=bytes.toString().replaceAll('\r\n','\n');
    assert.ok([bytes,lf,lf.replaceAll('\n','\r\n')].some(value=>createHash('sha256').update(value).digest('hex')===backup.migrations[i].sha256),'Migration changed: '+item.name);
    await pg.exec(bytes.toString());
  }
  const schema=(await pg.query(schemaSql)).rows[0].schema;
  schema.constraints=schema.constraints.filter(c=>!c[2].startsWith('NOT NULL '));
  assert.deepEqual(schema,backup.schema,'Source structure, functions or permissions differ');
  await pg.query("SELECT set_config('TimeZone',$1,false)",[backup.timezone]);
  await pg.transaction(async tx=>{
    for(const table of tables){
      assert.equal((await tx.query(`SELECT count(*)::text AS n FROM public.${table}`)).rows[0].n,'0','Restore target must be empty');
      const source=table==='sl_source_records'?JSON.stringify(JSON.parse(backup.tables[table]).map(r=>({...r,current_observation_id:null}))):backup.tables[table];
      await tx.query(`INSERT INTO public.${table} SELECT * FROM jsonb_populate_recordset(NULL::public.${table},$1::jsonb)`,[source]);
    }
    await tx.query(`UPDATE public.sl_source_records t SET current_observation_id=s.current_observation_id FROM jsonb_populate_recordset(NULL::public.sl_source_records,$1::jsonb) s WHERE t.id=s.id`,[backup.tables.sl_source_records]);
    await tx.query("SELECT setval('public.sl_replay_order_seq',$1::bigint,$2)",[backup.sequence.last_value,backup.sequence.is_called]);
    for(const table of tables)assert.equal((await tx.query(rowsSql(table))).rows[0].data,backup.tables[table],'Restored rows differ: '+table);
  });
  return {migrations:manifest.length,tables:tables.length,structure_permissions_and_rows_equal:true};
}
