export interface Metric { id:string; completedAt:string; model:string|null; provider?:string|null; clientVersion?:string|null; reasoningEffort?:string|null; outputTokens:number; durationSeconds:number; codexTTFTSeconds:number|null; turnThroughputTPS:number; }
export interface Stats { median:number|null; min:number|null; max:number|null; count:number }
export const DAY=86400000;
export const cohort=(m:Metric)=>JSON.stringify([m.model??null,m.provider??null,m.clientVersion??null,m.reasoningEffort??null]);
export const label=(m:Metric)=>`${m.model??'Unknown model'} · ${m.reasoningEffort??'unknown'} effort · Codex ${m.clientVersion??'unknown'}`;
export const communityId=(m:Metric)=>JSON.stringify([m.model??'unknown',m.provider??'unknown',m.clientVersion??'unknown','codex-rollout-v1','turn-v1',m.reasoningEffort??'unknown','codex']);
export function stats(values:number[]):Stats { const s=values.filter(Number.isFinite).filter(n=>n>=0).sort((a,b)=>a-b); const n=s.length; return {median:n?(n%2?s[n>>1]:s[n/2-1]/2+s[n/2]/2):null,min:s[0]??null,max:s[n-1]??null,count:n}; }
export function summarize(records:Metric[]) {return {throughput:stats(records.filter(m=>m.outputTokens>=20).map(m=>m.turnThroughputTPS)),ttft:stats(records.flatMap(m=>m.codexTTFTSeconds===null?[]:[m.codexTTFTSeconds]))};}
export function period(records:Metric[],start:number,end:number) {return records.filter(m=>Date.parse(m.completedAt)>=start&&Date.parse(m.completedAt)<end);}
export function change(current:Stats,previous:Stats) {return current.count>=5&&previous.count>=5&&previous.median!==null&&previous.median>0&&current.median!==null?(current.median/previous.median-1)*100:null;}
export function select(records:Metric[],selection:string) {if(selection==='all')return []; const key=selection==='latest'?records[0]&&cohort(records[0]):selection; return records.filter(m=>cohort(m)===key);}
export function signal(records:Metric[],now:number,metric:'throughput'|'ttft'):string {
 const eligible=records.filter(m=>metric==='throughput'?m.outputTokens>=20:m.codexTTFTSeconds!==null);
 const current=period(eligible,now-DAY,now+1), baseline=period(eligible,now-7*DAY,now-DAY);
 const days=new Set(baseline.map(m=>m.completedAt.slice(0,10))).size;
 if(current.length<5||baseline.length<20||days<2)return 'More observations needed for a personal baseline';
 if(!current.some(m=>Date.parse(m.completedAt)>=now-3600000))return 'Recent observations are stale';
 const a=summarize(current)[metric].median,b=summarize(baseline)[metric].median;
 if(a===null||b===null||b<=0)return 'Baseline unavailable';
 const changed=metric==='throughput'?a<=b*.7:a>=b*1.5&&a-b>=1;
 return changed?(metric==='throughput'?'Lower throughput than your baseline':'Longer first-token waits than your baseline'):'No threshold crossing in your observations';
}
export function buckets(records:Metric[],now:number,days:number,metric:'throughput'|'ttft') {const count=days===1?24:28, step=days*DAY/count,start=now-days*DAY; return Array.from({length:count},(_,i)=>({at:start+i*step,value:summarize(period(records,start+i*step,start+(i+1)*step))[metric].median}));}
