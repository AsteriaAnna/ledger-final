import {writeFile,mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {exportSql} from './lib/snapshot.mjs';
import {officialWorkbook,wxRow} from '../../apps/api/test-dist/test/fixtures/official.js';
import {parseOfficialFile} from '../../apps/api/dist/modules/imports/parser.js';
const root=fileURLToPath(new URL('../../',import.meta.url)),dir=resolve(root,'tmp/recovery');await mkdir(dir,{recursive:true});
const parsed=await parseOfficialFile(await officialWorkbook('wechat',[wxRow('recovery-expense','商户消费','支出','12.34'),
 wxRow('recovery-refund','商户退款','收入','0.44')]),'synthetic-recovery.xlsx');
const literal=value=>"'"+JSON.stringify(value).replaceAll("'","''")+"'::jsonb";
// No Auth accounts are needed: this fixture exercises business restoration only.
await writeFile(resolve(dir,'seed.sql'),`DO $$
DECLARE s text:='sl-recovery-20261028'; ps text:='sl-recovery-partner-20261028'; u uuid;p uuid;b uuid;a uuid;a2 uuid;profile uuid;batch jsonb;r jsonb;
BEGIN
 IF EXISTS(SELECT 1 FROM public.sl_users) THEN RAISE EXCEPTION 'recovery_seed_requires_empty_application';END IF;
 u:=public.sl_provision_user(s,'Synthetic recovery')::uuid;p:=public.sl_provision_user(ps,'Synthetic recovery partner')::uuid;
 PERFORM public.sl_create_invitation(s,repeat('a',64),repeat('a',64),repeat('a',64),repeat('x',43));
 INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO b;INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(u,b),(p,b);
 a:=(public.sl_create_account(s,repeat('b',64),repeat('b',64),' {"name":"Synthetic recovery A","account_type":"wechat_balance","custodian":"self","opening_state":{"opening_date":"2026-10-01","opening_balance_minor":15000,"opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":10000},{"fund_owner":"self","fund_type":"savings","amount_minor":2000},{"fund_owner":"partner","fund_type":"savings","amount_minor":3000}]}}'::jsonb)->>'id')::uuid;
 a2:=(public.sl_create_account(s,repeat('c',64),repeat('c',64),'{"name":"Synthetic recovery B","account_type":"cash","custodian":"self","opening_state":{"opening_date":"2026-10-01","opening_balance_minor":0,"opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":0}]}}'::jsonb)->>'id')::uuid;
 PERFORM public.sl_adjust_funds(s,a::text,repeat('d',64),repeat('d',64),1,'{"from":{"fund_owner":"self","fund_type":"liquid"},"to":{"fund_owner":"self","fund_type":"savings"},"amount_minor":100}'::jsonb);
 INSERT INTO public.sl_source_profiles(owner_id,platform,label) VALUES(u,'wechat','Synthetic recovery wallet') RETURNING id INTO profile;
 PERFORM public.sl_put_mapping(s,jsonb_build_object('source_account_profile_id',profile::text,'canonical_method_key','微信零钱','account_id',a::text,'expected_version',0));
 batch:=public.sl_import_upload(s,repeat('e',64),repeat('e',64),${literal(parsed)},profile::text);
 IF (batch->'data'->'summary'->>'created')::integer<>2 THEN RAISE EXCEPTION 'recovery_import_fixture_not_posted: %',batch->'data'->'summary';END IF;
 PERFORM public.sl_create_transaction(s,repeat('f',64),repeat('f',64),jsonb_build_object('type','transfer','from_account_id',a::text,'to_account_id',a2::text,'amount_minor',200,'occurred_at','2026-10-12T12:00:00+08:00','category_code','other','merchant','','note','restore transfer'));
 r:=public.sl_create_transaction(s,repeat('1',64),repeat('1',64),jsonb_build_object('type','expense','account_id',a::text,'source_account_profile_id',profile::text,'amount_minor',55,'occurred_at','2026-10-11T12:00:00+08:00','category_code','other','merchant','manual coverage item','note',''));
 INSERT INTO public.sl_reconciliation_items(profile_id,transaction_id,first_batch_id,last_batch_id) VALUES(profile,(r->'transaction'->>'id')::uuid,(batch->'data'->>'batch_id')::uuid,(batch->'data'->>'batch_id')::uuid);
 PERFORM public.sl_put_budget(s,'2026-10','{"budget_minor":5000,"expected_version":0}'::jsonb);
END $$;`);
await writeFile(resolve(dir,'export.sql'),await exportSql(root));
console.log('Prepared one scoped synthetic fixture and one consistent application export. No cloud operation executed.');
