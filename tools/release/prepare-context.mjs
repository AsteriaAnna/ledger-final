// Prepare the exact committed Docker source context. No deployment or cloud call.
import assert from 'node:assert/strict';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {resolve,dirname,relative,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url));
const git=(...args)=>execFileSync('git',args,{cwd:root,encoding:'utf8'});
const target=resolve(process.argv[2]||'');
const within=relative(resolve(root,'tmp'),target);assert.ok(within&&!within.startsWith('..')&&!isAbsolute(within),'Choose a new context directory below tmp/');
assert.equal(git('status','--porcelain').trim(),'','Commit reviewed changes before preparing a release');
const env=Object.fromEntries((await readFile(resolve(root,'apps/web/.env.local'),'utf8')).split(/\r?\n/).filter(line=>line&&!line.startsWith('#')&&line.includes('=')).map(line=>{
  const i=line.indexOf('=');return [line.slice(0,i).trim(),line.slice(i+1).trim().replace(/^['"]|['"]$/g,'')];
}));
assert.equal(env.VITE_CLOUDBASE_ENV_ID,'writter-dev-d0g7h1prq4ce60665');assert.ok(!env.VITE_API_BASE_URL,'Same-origin Web must have no separate API origin');
assert.match(env.VITE_PUBLISHABLE_KEY||'',/^[A-Za-z0-9_.-]+$/,'A complete public publishable key is required');
const publicClaims=JSON.parse(Buffer.from(env.VITE_PUBLISHABLE_KEY.split('.')[1],'base64url'));
assert.equal(publicClaims.role,'anon','Never include a server-role key in a Web build');
assert.ok(publicClaims.exp>Date.now()/1000,'Publishable key has expired');
const paths=git('ls-files').trim().split('\n').filter(path=>
  ['package.json','package-lock.json','openapi.yaml','.dockerignore','cloudbase/deploy/Dockerfile',
    'apps/api/package.json','apps/api/tsconfig.json','apps/web/package.json','apps/web/tsconfig.json','apps/web/index.html','apps/web/vite.config.ts'].includes(path)
  ||/^apps\/(api|web)\/src\//.test(path));
const source=git('rev-parse','HEAD').trim(),tree=git('rev-parse','HEAD^{tree}').trim();await mkdir(target);
const manifest=[];
for(const path of paths){
  assert.ok(!/(^|\/)\.env|\.(key|pem)$/.test(path),'Private file cannot enter a deployment context');
  let data=git('show',`HEAD:${path}`);
  if(path==='cloudbase/deploy/Dockerfile')data=data.replace(/^ARG VITE_CLOUDBASE_ENV_ID$/m,`ARG VITE_CLOUDBASE_ENV_ID=${env.VITE_CLOUDBASE_ENV_ID}`)
    .replace(/^ARG VITE_PUBLISHABLE_KEY$/m,`ARG VITE_PUBLISHABLE_KEY=${env.VITE_PUBLISHABLE_KEY}`)+`\nLABEL org.opencontainers.image.revision="${source}"\n`;
  await mkdir(dirname(resolve(target,path)),{recursive:true});await writeFile(resolve(target,path),data);
  manifest.push({path,sha256:createHash('sha256').update(data).digest('hex')});
}
await writeFile(resolve(target,'RELEASE.json'),JSON.stringify({release:'0.1.0-rc.1',source,tree,files:manifest,
  substitutions:['Docker ARG defaults contain only existing public Web env ID and publishable key','OCI source revision label'],
  cloud_deployed:false,backend_secrets_in_context:false},null,2));
console.log(JSON.stringify({prepared:true,source,files:manifest.length,backend_secrets_in_context:false,cloud_requests:0}));
