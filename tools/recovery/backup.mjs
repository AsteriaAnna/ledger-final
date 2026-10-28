// Local backup custody and independent restoration. Never sends network requests.
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {randomBytes,createCipheriv,createDecipheriv} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {PGlite} from '@electric-sql/pglite';
import {exportSql,restoreSnapshot} from './lib/snapshot.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
const [command,input,output,keyFile]=process.argv.slice(2);
const format='star-ledger-encrypted-v1',algorithm='aes-256-gcm',aad=Buffer.from(format+':'+algorithm);
const write=(path,data)=>writeFile(path,data,{flag:'wx',mode:0o600});
async function key(path){const value=await readFile(path);assert.equal(value.length,32,'Expected a separate 32-byte recovery key');return value;}
async function decrypt(path,keyPath){
  const sealed=JSON.parse(await readFile(path,'utf8'));assert.equal(sealed.format,format);assert.equal(sealed.algorithm,algorithm);
  const cipher=createDecipheriv(algorithm,await key(keyPath),Buffer.from(sealed.iv,'base64'));
  cipher.setAAD(aad);cipher.setAuthTag(Buffer.from(sealed.tag,'base64'));
  return Buffer.concat([cipher.update(Buffer.from(sealed.ciphertext,'base64')),cipher.final()]);
}
try{
  if(command==='create-key'&&input){await write(input,randomBytes(32));console.log('Recovery key saved privately. Keep a separate offline copy.');}
  else if(command==='export-sql'&&input){await write(input,await exportSql(root));console.log('Read-only export SQL prepared. No cloud request executed.');}
  else if(command==='seal'&&input&&output&&keyFile){
    const data=await readFile(input);const parsed=JSON.parse(data);assert.equal(parsed.format,'star-ledger-logical-v1');
    const iv=randomBytes(12),cipher=createCipheriv(algorithm,await key(keyFile),iv);cipher.setAAD(aad);
    const ciphertext=Buffer.concat([cipher.update(data),cipher.final()]);
    await write(output,JSON.stringify({format,algorithm,iv:iv.toString('base64'),tag:cipher.getAuthTag().toString('base64'),ciphertext:ciphertext.toString('base64')}));
    assert.deepEqual(await decrypt(output,keyFile),data);console.log('Encrypted backup saved; authenticated decryption matches the original bytes.');
  }else if(command==='open'&&input&&output&&keyFile){await write(output,await decrypt(input,keyFile));console.log('Decrypted snapshot saved privately; source unchanged.');}
  else if(command==='verify'&&input&&output&&!keyFile){
    const data=JSON.parse(await decrypt(input,output)),pg=await PGlite.create();
    try{console.log(JSON.stringify({restored:await restoreSnapshot(root,data,pg),cloud_requests:0,
      excludes:['platform Auth credentials','storage objects','replacement cloud environment','runtime secrets and routing']}));}finally{await pg.close();}
  }else throw new Error('Use create-key <new.key> | export-sql <new.sql> | seal/open <input> <new output> <key> | verify <sealed> <key>');
}catch(error){
  // Assertions can embed whole snapshots. Keep private rows and credentials out of logs.
  console.error('Backup operation failed ('+error.name+'). Existing files are not overwritten; check the private inputs and matching migrations.');process.exitCode=1;
}
