import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {createServer} from 'vite';
test('unknown write outcome keeps its key through expired login and retries with refreshed identity',async(t)=>{
  const server=await createServer({configFile:false,root:fileURLToPath(new URL('../',import.meta.url)),mode:'test',
    resolve:{alias:{'@cloudbase/js-sdk':fileURLToPath(new URL('./fixtures/cloudbase-sdk.ts',import.meta.url))}},
    server:{middlewareMode:true},optimizeDeps:{noDiscovery:true},define:{
      'import.meta.env.VITE_CLOUDBASE_ENV_ID':JSON.stringify('synthetic-intent-test'),
      'import.meta.env.VITE_PUBLISHABLE_KEY':JSON.stringify('synthetic-publishable-key'),
      'import.meta.env.VITE_API_BASE_URL':JSON.stringify('https://api.synthetic.invalid'),
    }});
  const storageDescriptor=Object.getOwnPropertyDescriptor(globalThis,'sessionStorage');
  const windowDescriptor=Object.getOwnPropertyDescriptor(globalThis,'window');
  try{
    const client=await server.ssrLoadModule('/src/api/client.ts');
    const memory=new Map<string,string>();
    Object.defineProperty(globalThis,'sessionStorage',{configurable:true,value:{getItem:(k:string)=>memory.get(k)??null,
      setItem:(k:string,v:string)=>memory.set(k,v),removeItem:(k:string)=>memory.delete(k)}});
    const events=new EventTarget();let expired=0;events.addEventListener('sl-session-expired',()=>expired++);
    Object.defineProperty(globalThis,'window',{configurable:true,value:events});
    const session={user:{id:'fixture'},access_token:'original'};let latest:any={...session,access_token:'refreshed'};
    t.mock.method(client.auth,'getSession',async()=>({data:{session:latest},error:null}));
    let firstKey='';let attempts=0;
    t.mock.method(globalThis,'fetch',async(_url,init)=>{attempts++;const headers=new Headers(init?.headers);
      assert.equal(headers.get('Authorization'),'Bearer refreshed');
      if(attempts===1){firstKey=headers.get('Idempotency-Key')!;throw new TypeError('synthetic lost response');}
      assert.equal(headers.get('Idempotency-Key'),firstKey);return new Response(JSON.stringify({data:{saved:true}}));
    });
    await assert.rejects(client.createWithKey(session,'/transactions',{amount_minor:123}));assert.equal(memory.size,1);
    latest=null;await assert.rejects(client.createWithKey(session,'/transactions',{amount_minor:123}));
    assert.equal(expired,1);assert.equal(memory.size,1);assert.equal(attempts,1);
    latest={...session,access_token:'refreshed'};
    assert.deepEqual(await client.createWithKey(session,'/transactions',{amount_minor:123}),{saved:true});
    assert.equal(memory.size,0);assert.equal(attempts,2);
  }finally{
    if(storageDescriptor)Object.defineProperty(globalThis,'sessionStorage',storageDescriptor);else Reflect.deleteProperty(globalThis,'sessionStorage');
    if(windowDescriptor)Object.defineProperty(globalThis,'window',windowDescriptor);else Reflect.deleteProperty(globalThis,'window');
    await server.close();
  }
});
