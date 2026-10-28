import { app } from './http/app.js';

const port = Number(process.env.PORT ?? 3000);
if (!process.env.CLOUDBASE_ENV_ID || !process.env.CLOUDBASE_API_KEY) {
  throw new Error('Set CLOUDBASE_ENV_ID and a server-only CLOUDBASE_API_KEY before starting the API');
}
if(!Number.isInteger(port)||port<1||port>65535)throw new Error('PORT must be between 1 and 65535');
if(process.env.NODE_ENV==='production'&&(!process.env.CURSOR_SECRET||process.env.CURSOR_SECRET.length<32)){
  throw new Error('Production requires a stable CURSOR_SECRET of at least 32 characters');
}
const server=app.listen(port,'0.0.0.0',()=>console.log(`Star Ledger API listening on ${port}`));
for(const signal of ['SIGTERM','SIGINT'] as const)process.once(signal,()=>{
  server.close(()=>process.exit(0));setTimeout(()=>process.exit(1),10000).unref();
});
