// Check the actual staged release without importing app code from the checkout.
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {readFile,readdir,writeFile} from 'node:fs/promises';
import {resolve,relative,isAbsolute,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const root=fileURLToPath(new URL('../../',import.meta.url)),tmp=resolve(root,'tmp');
if(!process.argv[2])throw new Error('Provide a staged --with-web package below tmp/.');
const target=resolve(process.argv[2]),inside=relative(tmp,target);
if(!inside||inside==='..'||inside.startsWith('..\\')||inside.startsWith('../')||isAbsolute(inside))throw new Error('Package must be below repository tmp/.');
assert.match(await readFile(join(target,'RELEASE.txt'),'utf8'),/WEB_DIST_PATH=\.\.\/web\/dist/);
async function checkFiles(dir){
  for(const item of await readdir(dir,{withFileTypes:true})){
    if(item.isSymbolicLink())continue; // npm workspace links contain no new files.
    assert.ok(!item.name.startsWith('.env')||item.name==='.env.example','Private environment file in package');
    const path=join(dir,item.name);if(item.isDirectory())await checkFiles(path);
  }
}
await checkFiles(target);
const reservation=createServer();reservation.listen(0,'127.0.0.1');await new Promise(ok=>reservation.once('listening',ok));
const port=reservation.address().port;await new Promise(ok=>reservation.close(ok));
const env={...process.env,NODE_ENV:'production',PORT:String(port),WEB_DIST_PATH:'../web/dist',
  CLOUDBASE_ENV_ID:'synthetic-package-only',CLOUDBASE_API_KEY:'synthetic-unused-server-key',CURSOR_SECRET:'synthetic-package-only-pagination-secret'};
delete env.LEDGER_CONTRACT_PATH;
const child=spawn(process.execPath,['dist/server.js'],{cwd:join(target,'apps/api'),env,windowsHide:true,stdio:['ignore','pipe','pipe']});
let stderr='';child.stderr.on('data',chunk=>{stderr+=chunk.toString();});
try{
  await new Promise((ok,fail)=>{
    const timer=setTimeout(()=>fail(new Error('Release package startup timed out')),10000);
    child.stdout.once('data',()=>{clearTimeout(timer);ok();});
    child.once('error',e=>{clearTimeout(timer);fail(e);});
    child.once('exit',code=>{clearTimeout(timer);fail(new Error('Release exited '+code+': '+stderr));});
  });
  const base='http://127.0.0.1:'+port;
  const request=path=>fetch(base+path,{redirect:'error'});
  const html=await request('/');assert.equal(html.status,200);assert.equal(html.headers.get('cache-control'),'no-store');
  const asset=(await html.text()).match(/src="([^"]+\.js)"/);assert.ok(asset);
  const bundle=await request(asset[1]);assert.equal(bundle.status,200);assert.match(bundle.headers.get('cache-control'),/immutable/);
  const health=await request('/healthz');assert.deepEqual(await health.json(),{status:'ok'});
  const denied=await request('/api/v1/accounts');assert.equal(denied.status,401);assert.equal((await denied.json()).code,'UNAUTHENTICATED');
  for(const path of ['/.env.local','/assets/.env','/package.json','/assets/not-present.js'])assert.equal((await request(path)).status,404);
  const report={cloud_requests:0,source:'standalone staged release with installed production dependencies',same_origin_html_and_asset:true,
    no_private_env_files:true,health:true,unauthenticated_api_status:401,private_paths_status:404};
  await writeFile(resolve(tmp,'release-package-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{
  if(child.exitCode===null&&child.signalCode===null){
    const exited=new Promise(ok=>child.once('exit',ok));child.kill();await exited;
  }
}
