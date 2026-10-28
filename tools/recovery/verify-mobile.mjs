// Real mobile Chromium UI -> real local Express -> original migrations in PGlite.
// Auth and PG HTTP gateway are test substitutes. No CloudBase network is allowed.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {mkdir,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createServer} from 'vite';
import react from '@vitejs/plugin-react';
import {startLocalApi} from './lib/local-api.mjs';
import {officialWorkbook,wxRow} from '../../apps/api/test-dist/test/fixtures/official.js';

const require=createRequire(process.env.LEDGER_BROWSER_TOOLS_ROOT?
  resolve(process.env.LEDGER_BROWSER_TOOLS_ROOT,'package.json'):import.meta.url);
const {chromium}=require('playwright');
const local=await startLocalApi(),out=resolve(local.root,'tmp/mobile');
await mkdir(out,{recursive:true});
let vite,browser;const errors=[],blocked=[],checks=[],layouts=[];
try{
  // envFile:false prevents reading private Web configuration even accidentally.
  vite=await createServer({root:resolve(local.root,'apps/web'),configFile:false,envFile:false,plugins:[react()],
    resolve:{alias:{'@cloudbase/js-sdk':resolve(local.root,'tools/recovery/fixtures/browser-auth.mjs')}},
    define:{'import.meta.env.VITE_CLOUDBASE_ENV_ID':JSON.stringify('synthetic-local-only'),
      'import.meta.env.VITE_PUBLISHABLE_KEY':JSON.stringify('synthetic-local-only-public-key'),
      'import.meta.env.VITE_CLOUDBASE_REGION':JSON.stringify('ap-shanghai'),'import.meta.env.VITE_API_BASE_URL':JSON.stringify('')},
    server:{host:'127.0.0.1',port:0,proxy:{'/api':local.origin}}});
  await vite.listen();const origin='http://127.0.0.1:'+vite.httpServer.address().port;
  browser=await chromium.launch({headless:true,...(process.env.LEDGER_CHROMIUM_PATH?{executablePath:process.env.LEDGER_CHROMIUM_PATH}:{})});
  const context=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true,deviceScaleFactor:1});
  await context.route('**/*',route=>{
    if(new URL(route.request().url()).origin===origin)return route.continue();
    blocked.push(route.request().url().split('?')[0]);return route.abort();
  });
  const page=await context.newPage();page.setDefaultTimeout(12000);
  page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
  const section=heading=>page.locator('section').filter({has:page.getByRole('heading',{name:heading,exact:true})});
  async function layout(name){
    for(const width of [320,390]){
      await page.setViewportSize({width,height:844});
      const value=await page.evaluate(()=>({viewport:innerWidth,width:document.documentElement.scrollWidth,
        overflowing:[...document.querySelectorAll('main *')].filter(e=>e.getBoundingClientRect().right>innerWidth+1)
          .slice(0,8).map(e=>({tag:e.tagName,cls:e.className,text:e.textContent.slice(0,65)}))}));
      assert.ok(value.width<=value.viewport,`${name} overflows ${width}px viewport`);
      const navigation=await page.locator('nav a').evaluateAll(links=>links.map(link=>{
        const r=link.getBoundingClientRect();return {left:r.left,right:r.right,height:r.height};}));
      assert.ok(navigation.every(r=>r.left>=0&&r.right<=width&&r.height>=44),'All five mobile navigation targets must be visible');
      layouts.push({name,requested_width:width,...value});await page.screenshot({path:resolve(out,`${name}-${width}.png`),fullPage:true});
    }
    await page.setViewportSize({width:390,height:844});
  }
  await page.goto(origin);await page.getByRole('heading',{name:'登录星账'}).waitFor();await layout('login');
  await page.getByLabel('用户名').fill('local-only-a');await page.getByLabel('密码',{exact:true}).fill('wrong');
  await page.getByRole('button',{name:'登录',exact:true}).click();await page.getByRole('status').filter({hasText:'密码错误'}).waitFor();
  await page.getByLabel('密码',{exact:true}).fill('local-browser-only');await page.getByRole('button',{name:'登录',exact:true}).click();
  await page.getByRole('heading',{name:'我的账户',exact:true}).waitFor();checks.push('login-error-and-success');
  const create=section('创建实际账户');await create.getByLabel('账户名称').fill('手机验证日常现金账户名称很长用于检查换行');
  await create.getByLabel('起始日期').fill('2026-10-01');await create.getByLabel('本人流动资金（元）',{exact:true}).fill('100.00');
  await create.getByLabel('本人存款（元）',{exact:true}).fill('50.00');await create.getByRole('button',{name:'保存账户'}).click();
  await page.getByRole('status').filter({hasText:'账户已保存'}).waitFor();await layout('accounts');
  await page.reload();await page.getByText('¥150.00',{exact:true}).waitFor();checks.push('account-create-reload');
  await page.getByRole('button',{name:'修改资料'}).click();await section('修改账户资料').getByLabel('名称',{exact:true}).fill('手机验证现金');
  await section('修改账户资料').getByRole('button',{name:'保存修改'}).click();await page.getByRole('heading',{name:'手机验证现金',exact:true}).waitFor();
  await page.getByRole('button',{name:'调整份额'}).click();const adjustment=page.locator('section').filter({has:page.getByRole('heading',{name:/调整「/})});
  await adjustment.getByLabel('金额（元）').fill('10.00');await adjustment.getByRole('button',{name:'确认调整'}).click();
  await page.getByRole('status').filter({hasText:'资金份额已调整'}).waitFor();checks.push('account-edit-and-fund-adjustment');
  await page.getByRole('button',{name:'修正初始状态'}).click();const opening=page.locator('section').filter({has:page.getByRole('heading',{name:/修正「/})});
  await opening.getByLabel('初始本人流动资金（元）').fill('120.00');await opening.getByRole('button',{name:'保存初始状态'}).click();
  await page.getByRole('status').filter({hasText:'初始状态已保存'}).waitFor();checks.push('opening-correction');
  await page.getByRole('link',{name:'账单',exact:true}).click();const manual=section('记一笔支出');
  await manual.getByLabel('金额（元）').fill('20.50');await manual.getByLabel('商户',{exact:true}).fill('手机验证商户名称很长用于检查交易卡片换行');
  await manual.getByLabel('备注',{exact:true}).fill('local synthetic only');await manual.getByRole('button',{name:'保存支出'}).click();
  await page.getByRole('status').filter({hasText:'支出已保存'}).waitFor();await layout('transactions');
  await page.getByRole('button',{name:'编辑',exact:true}).click();const edit=section('编辑账单');await layout('transaction-edit');
  await edit.getByLabel('金额（元）').fill('25.75');await edit.getByRole('button',{name:'保存修改'}).click();
  await page.getByRole('status').filter({hasText:'账单已更新'}).waitFor();await page.reload();
  await page.getByText('−¥25.75',{exact:true}).waitFor();checks.push('expense-edit-reload');
  await page.getByRole('button',{name:'删除',exact:true}).click();await page.getByRole('status').filter({hasText:'账单已删除'}).waitFor();
  assert.equal(await page.getByRole('button',{name:'删除',exact:true}).count(),0);checks.push('delete-with-confirmation');
  await page.getByRole('link',{name:'导入',exact:true}).click();await layout('import-empty');
  const xlsx=await officialWorkbook('wechat',[wxRow('mobile-only-expense'),wxRow('mobile-only-unsupported','商户消费','支出','10','亲情卡')]);
  await page.getByLabel('官方XLSX文件').setInputFiles({name:'手机合成官方账单.xlsx',mimeType:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',buffer:Buffer.from(xlsx)});
  await page.getByRole('button',{name:'读取并处理文件'}).click();await page.getByRole('heading',{name:'确认来源账号',exact:true}).waitFor();
  await page.getByLabel('新档案名称').fill('手机合成微信');await page.getByRole('button',{name:'创建并使用档案'}).click();
  const mapping=section('渠道对应哪个实际账户');await mapping.locator('select').selectOption({label:'手机验证现金'});
  await mapping.getByRole('button',{name:'保存映射并继续'}).click();await page.getByText(/已入账 1；/).waitFor();
  await page.getByText(/本期不支持 1；/).waitFor();await page.getByText('查看官方原始字段',{exact:true}).first().click();await layout('import-result');
  await page.reload();await page.getByText(/已入账 1；/).waitFor();checks.push('import-profile-map-retain-unsupported-reload');
  await page.getByRole('link',{name:'首页',exact:true}).click();const budget=section('个人月预算');
  await budget.getByLabel('预算金额（元）').fill('200.00');await budget.getByRole('button',{name:'保存预算'}).click();
  await page.getByRole('status').filter({hasText:'月预算已保存'}).waitFor();await page.reload();
  await page.getByLabel('预算金额（元）').waitFor();await page.waitForFunction(()=>[...document.querySelectorAll('input')].some(e=>e.value==='200.00'));
  await layout('overview-budget');checks.push('budget-save-reload');
  await page.getByRole('link',{name:'我的',exact:true}).click();await layout('profile');
  await page.getByRole('button',{name:'退出登录'}).click();await page.getByRole('heading',{name:'登录星账'}).waitFor();checks.push('logout');
  assert.deepEqual(errors,[]);assert.deepEqual(blocked,[]);assert.equal(local.counters.blocked_external_calls,0);
  await writeFile(resolve(out,'report.json'),JSON.stringify({checks,layouts,errors,blocked,counters:local.counters},null,2));
  console.log(JSON.stringify({checks,layout_samples:layouts.length,overflows:layouts.filter(v=>v.width>v.viewport),errors,blocked,counters:local.counters}));
}catch(error){await writeFile(resolve(out,'failure.json'),JSON.stringify({error:error.stack,checks,layouts,errors,blocked},null,2));throw error;}
finally{await browser?.close();await vite?.close();await local.close();}
