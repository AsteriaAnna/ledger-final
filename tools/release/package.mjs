// Prepare a reproducible API source/build package. Never copies .env, local
// data, test credentials or the recovery tool into a runtime deployment.
import {cp,mkdir,copyFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
const root=fileURLToPath(new URL('../../',import.meta.url));
const destination=process.argv[2];if(!destination)throw new Error('Provide a new private output directory under tmp/.');
const target=resolve(destination),tmp=resolve(root,'tmp');
if(!target.startsWith(tmp+'\\')&&!target.startsWith(tmp+'/'))throw new Error('Output must stay below repository tmp/.');
await mkdir(target);await mkdir(resolve(target,'apps/api'),{recursive:true});await mkdir(resolve(target,'apps/web'),{recursive:true});
for(const name of ['package.json','package-lock.json','openapi.yaml'])await copyFile(resolve(root,name),resolve(target,name));
for(const app of ['api','web'])await copyFile(resolve(root,'apps',app,'package.json'),resolve(target,'apps',app,'package.json'));
await cp(resolve(root,'apps/api/dist'),resolve(target,'apps/api/dist'),{recursive:true});
await copyFile(resolve(root,'apps/api/.env.example'),resolve(target,'apps/api/.env.example'));
await writeFile(resolve(target,'RELEASE.txt'),`Star Ledger API\nSource: ${execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim()}\nInstall: npm ci --omit=dev --workspace apps/api\nStart from apps/api: node dist/server.js\nSet CLOUDBASE_ENV_ID, CLOUDBASE_API_KEY, NODE_ENV=production, CURSOR_SECRET, WEB_ORIGIN and PORT before starting.\nThis is a prepared package, not a verified cloud deployment. Web must be built after its actual HTTPS API origin is selected.\n`);
console.log('Prepared API package without secrets or personal data. Install runtime dependencies in the output directory before starting.');
