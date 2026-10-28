// Small real-session permission probe. Credentials live outside Git and are never printed.
const fs = require('node:fs');
const cloudbase = require('@cloudbase/js-sdk');

const credentialsPath = process.argv[2];
if (!credentialsPath) throw new Error('Pass a private credentials JSON path');
const credentials = JSON.parse(fs.readFileSync(credentialsPath, 'utf8'));
const env = Object.fromEntries(fs.readFileSync('apps/web/.env.local', 'utf8').split(/\r?\n/)
  .filter((line) => line.includes('=')).map((line) => { const at = line.indexOf('='); return [line.slice(0, at), line.slice(at + 1)]; }));
const envId = env.VITE_CLOUDBASE_ENV_ID;
const gateway = `https://${envId}.api.tcloudbasegateway.com`;
const app = cloudbase.init({ env: envId, region: env.VITE_CLOUDBASE_REGION,
  accessKey: env.VITE_PUBLISHABLE_KEY, auth: { detectSessionInUrl: false } });

async function main() {
  const { data, error } = await app.auth.signInWithPassword(credentials);
  if (error || !data?.session?.access_token) throw new Error(`Login failed: ${error?.message ?? 'no token'}`);
  const token = data.session.access_token;
  const authHeader = { Authorization: `Bearer ${token}` };
  const identity = await fetch(`${gateway}/auth/v1/user/me`, { headers: authHeader });
  const profile = await identity.json().catch(() => ({}));
  const table = await fetch(`${gateway}/v1/rdb/rest/sl_accounts?select=id`, { headers: authHeader });
  const tableBody = await table.json().catch(() => ({}));
  const rpc = await fetch(`${gateway}/v1/rdb/rest/rpc/sl_create_account`, {
    method: 'POST', headers: { ...authHeader, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_actor_subject: profile.sub, p_key_digest: 'a'.repeat(64),
      p_payload_hash: 'b'.repeat(64), p_input: {} }),
  });
  const rpcBody = await rpc.json().catch(() => ({}));
  console.log(JSON.stringify({ authStatus: identity.status, subjectMatches: profile.sub === data.session.user?.id,
    directTableStatus: table.status, directTableCode: tableBody.code,
    directWriteRpcStatus: rpc.status, directWriteRpcCode: rpcBody.code }));
  if (identity.status !== 200 || table.ok || rpc.ok) process.exitCode = 1;
  await app.auth.signOut();
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; })
  .finally(() => setTimeout(() => process.exit(process.exitCode ?? 0), 100));
