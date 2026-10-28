import {useEffect,useState} from 'react';
import {type Session} from '../../api/client';
import {getImport,type Profile} from './api';
export function SourceProfileSelect({session,value,onChange}:{session:Session;value:string;onChange:(value:string)=>void}) {
  const [profiles,setProfiles]=useState<Profile[]>([]);
  useEffect(()=>{const id=localStorage.getItem(`sl-last-import:${session.user?.id??'unknown'}`);
    if(id)getImport(session,id,'?limit=1').then(r=>setProfiles(r.data.profile_candidates)).catch(()=>setProfiles([]));
  },[session]);
  if(!profiles.length&&!value)return null;
  return <label>声明来源账号（可选）<select value={value} onChange={e=>onChange(e.target.value)}>
    <option value="">不声明来源账号</option>
    {!!value&&!profiles.some(p=>p.id===value)&&<option value={value}>保持原来源档案</option>}
    {profiles.map(p=><option key={p.id} value={p.id}>{p.platform==='wechat'?'微信':'支付宝'} · {p.label}</option>)}
  </select></label>;
}
