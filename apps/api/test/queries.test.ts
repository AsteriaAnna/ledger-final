import assert from 'node:assert/strict';
import {test} from 'node:test';
import {decodeCursor,encodeCursor,listQuery,pageScope} from '../src/http/pagination.js';
import {contractQuery} from '../src/domain/contracts.js';
process.env.CURSOR_SECRET='synthetic-only-pagination-secret';
test('pagination cursors bind identity, view and filters and reject tampering',()=>{
  const scope=pageScope('a','transactions',{view:'mine',type:'expense'});
  const position={id:'11111111-1111-4111-8111-111111111111',time:'2026-10-10T12:00:00+08:00'};
  const cursor=encodeCursor(scope,position)!;assert.deepEqual(decodeCursor(scope,cursor),position);
  assert.throws(()=>decodeCursor(pageScope('b','transactions',{view:'mine',type:'expense'}),cursor));
  assert.throws(()=>decodeCursor(pageScope('a','transactions',{view:'partner',type:'expense'}),cursor));
  assert.throws(()=>decodeCursor(pageScope('a','transactions',{view:'mine',type:'income'}),cursor));
  assert.throws(()=>decodeCursor(scope,cursor+'x'));
});
test('list query validation uses the declared limits and real calendar dates',()=>{
  assert.deepEqual(listQuery('listAccounts',{}),{cursor:undefined,limit:50,view:'mine',filters:{}});
  assert.equal(listQuery('listTransactions',{limit:'100',from:'2024-02-29',to:'2024-03-01',type:'refund'}).limit,100);
  for(const input of [{limit:'101'},{limit:'0'},{from:'2026-02-30'},{from:'2026-10-10',to:'2026-10-01'},{type:'debt'},{user_id:'forged'}]) {
    assert.throws(()=>listQuery('listTransactions',input));
  }
  assert.throws(()=>contractQuery('getImport',{limit:101}));
});
