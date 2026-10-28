import {useEffect,useState} from 'react';
import {request,type Session} from '../../api/client';
import {minor,minorInput,money,todayShanghai} from '../../lib/format';
type Budget={month:string;budget_minor:number;version:number};
type Overview={month:string;as_of_date:string;relationship_status:string;
  funds:{my_liquid_minor:number;my_savings_minor:number;partner_liquid_minor:number|null;partner_savings_minor:number|null;visible_total_minor:number};
  personal_spending:{expense_minor:number;refund_offset_minor:number;month_spent_minor:number;daily_average_minor:number;
    previous_month_daily_average_minor:number;daily_change_minor:number;daily_change_rate:number|null;projected_month_spending_minor:number};
  budget:{budget_minor:number;spent_minor:number;remaining_minor:number;over_budget_minor:number;status:string}|null};
export function OverviewPage({session,refreshSequence,onMessage}:{session:Session;refreshSequence:number;onMessage:(message:string)=>void}) {
  const currentMonth=todayShanghai().slice(0,7);
  const [month,setMonth]=useState(currentMonth),[value,setValue]=useState<Overview|null>(null),[error,setError]=useState('');
  const [budgetMonth,setBudgetMonth]=useState(currentMonth),[budget,setBudget]=useState<Budget|null>(null),[amount,setAmount]=useState('');
  const [loadingBudget,setLoadingBudget]=useState(true),[saving,setSaving]=useState(false),[budgetReload,setBudgetReload]=useState(0);
  useEffect(()=>{let live=true;setValue(null);setError('');if(month)request<Overview>(session,`/overview?month=${encodeURIComponent(month)}`)
    .then(v=>{if(live)setValue(v);}).catch(e=>{if(live)setError(e.message);});return()=>{live=false;};},[session,month,refreshSequence,budgetReload]);
  useEffect(()=>{let live=true;setBudget(null);setAmount('');setLoadingBudget(true);
    if(!budgetMonth){setLoadingBudget(false);return;}
    request<Budget|null>(session,`/budgets/${encodeURIComponent(budgetMonth)}`).then(v=>{if(live){setBudget(v);setAmount(v?minorInput(v.budget_minor):'');}})
      .catch(e=>{if(live)onMessage(e.message);}).finally(()=>{if(live)setLoadingBudget(false);});return()=>{live=false;};
  },[session,budgetMonth,refreshSequence,budgetReload]);
  async function save(event:React.FormEvent){event.preventDefault();setSaving(true);onMessage('');
    try{const result=await request<Budget>(session,`/budgets/${encodeURIComponent(budgetMonth)}`,{method:'PUT',body:JSON.stringify({budget_minor:minor(amount),expected_version:budget?.version??0})});
      setBudget(result);setBudgetReload(n=>n+1);onMessage('月预算已保存。');
    }catch(e){onMessage(e instanceof Error?e.message:'保存失败。');}finally{setSaving(false);}}
  const stats=value?.personal_spending;
  return <>
    <div className="section-head"><div><p className="eyebrow">资金与消费</p><h1>首页总览</h1></div></div>
    <section className="card"><label>统计月份<input type="month" max={currentMonth} value={month} onChange={e=>{setMonth(e.target.value);setBudgetMonth(e.target.value);}}/></label>
      <p className="muted">统计按北京时间截至{value?.as_of_date??'所选月末或今天'}；资金卡始终显示当前资金。</p>
      {error?<p role="status">{error}</p>:!value?<p>正在读取总览…</p>:<>
        <h2>当前资金归属</h2><div className="summary-grid">
          <div><span>本人流动资金</span><strong>{money(value.funds.my_liquid_minor)}</strong></div>
          <div><span>本人存款</span><strong>{money(value.funds.my_savings_minor)}</strong></div>
          {value.funds.partner_liquid_minor!==null&&<div><span>对象流动资金</span><strong>{money(value.funds.partner_liquid_minor)}</strong></div>}
          {value.funds.partner_savings_minor!==null&&<div><span>对象存款</span><strong>{money(value.funds.partner_savings_minor)}</strong></div>}
        </div><p>当前可见资金合计 {money(value.funds.visible_total_minor)}</p><p className="muted">按资金属于谁汇总，代管存款仍属于其本人。</p>
      </>}
    </section>
    {stats&&value&&<section className="card"><h2>{month} · 本人消费</h2><div className="summary-grid">
      <div><span>支出</span><strong>{money(stats.expense_minor)}</strong></div><div><span>抵减退款</span><strong>{money(stats.refund_offset_minor)}</strong></div>
      <div><span>净花销</span><strong>{money(stats.month_spent_minor)}</strong></div><div><span>日均花销</span><strong>{money(stats.daily_average_minor)}</strong></div>
      <div><span>上月整月日均</span><strong>{money(stats.previous_month_daily_average_minor)}</strong></div><div><span>日均变化</span><strong>{money(stats.daily_change_minor)}</strong></div>
      <div><span>日均变化率</span><strong>{stats.daily_change_rate===null?'暂无可比较基数':`${(stats.daily_change_rate*100).toFixed(2)}%`}</strong></div>
      <div><span>{month===currentMonth?'预计本月花销':'整月实际花销'}</span><strong>{money(stats.projected_month_spending_minor)}</strong></div>
    </div><p className="muted">收入、转账不计花销；退款按记账日期及抵减开关计算。净花销可以为负。</p>
      {value.budget?<p>本月预算 {money(value.budget.budget_minor)} · {value.budget.status==='over_budget'?`已超支 ${money(value.budget.over_budget_minor)}`:`剩余 ${money(value.budget.remaining_minor)}`}</p>:<p>该月尚未设置预算。</p>}
    </section>}
    <section className="card form-card"><h2>个人月预算</h2><p>可设置当前、历史或未来月份，不改变账户资金。</p>
      <form onSubmit={save}><label>预算月份<input type="month" required value={budgetMonth} onChange={e=>setBudgetMonth(e.target.value)}/></label>
        <label>预算金额（元）<input inputMode="decimal" required value={amount} onChange={e=>setAmount(e.target.value)} disabled={loadingBudget}/></label>
        <div className="view-switch"><button disabled={saving||loadingBudget||!budgetMonth}>保存预算</button>
          <button type="button" className="secondary" disabled={saving||loadingBudget} onClick={()=>setBudgetReload(n=>n+1)}>重新读取预算</button></div>
      </form>
    </section>
  </>;
}
