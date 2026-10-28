import type {Express} from 'express';
import {contractInput,contractQuery} from '../../domain/contracts.js';
import {DomainError} from '../../domain/ledger.js';
import {actor,route,rpc} from '../../http/request.js';
function month(value:unknown):string {
  if(typeof value!=='string'||!/^\d{4}-(0[1-9]|1[0-2])$/.test(value)||value.startsWith('0000'))throw new DomainError(422,'VALIDATION_ERROR','月份不合法。');return value;
}
export function registerOverviewRoutes(app:Express){
  app.get('/api/v1/overview',route(async(req,res)=>{
    const query=contractQuery('getOverview',req.query);
    if(month(query.month)>new Date(Date.now()+8*3600000).toISOString().slice(0,7))throw new DomainError(422,'VALIDATION_ERROR','统计月份不能晚于当前月份，预算可以设置未来月份。');
    res.json({data:await rpc(req,'sl_get_overview',{p_actor_subject:actor(req),p_month:month(query.month)})});
  }));
  app.get('/api/v1/budgets/:month',route(async(req,res)=>{
    if(Object.keys(req.query).length)throw new DomainError(422,'VALIDATION_ERROR','此查询不接受额外参数。');
    res.json({data:await rpc(req,'sl_get_budget',{p_actor_subject:actor(req),p_month:month(req.params.month)})});
  }));
  app.put('/api/v1/budgets/:month',route(async(req,res)=>{
    const input=contractInput('BudgetPut',req.body);
    if(!Number.isSafeInteger(input.budget_minor)||!Number.isSafeInteger(input.expected_version))throw new DomainError(422,'VALIDATION_ERROR','预算金额或版本超出支持范围。');
    res.json({data:await rpc(req,'sl_put_budget',{p_actor_subject:actor(req),p_month:month(req.params.month),p_input:input})});
  }));
}
