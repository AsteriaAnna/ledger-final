import assert from 'node:assert/strict';
import {test} from 'node:test';
import {money,minor,minorInput} from '../src/lib/format.ts';
test('money formatting preserves cents at the safe-integer boundary and negative spending',()=>{
  assert.equal(money(Number.MAX_SAFE_INTEGER),'¥90071992547409.91');
  assert.equal(money(-133),'-¥1.33');assert.equal(money(0),'¥0.00');
  assert.equal(minor(minorInput(Number.MAX_SAFE_INTEGER)),Number.MAX_SAFE_INTEGER);
});
