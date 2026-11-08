import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
const source = html.slice(html.indexOf('function graph('), html.indexOf('function render('));
const now = 1800000000;
const account = (id, remaining, reset) => ({id,windows:[{name:'seven_day',remaining,reset}]});
const accounts = [account('a',80,now+3600),account('b',20,now+86400)];
const data = {now,history:accounts.flatMap(a=>Array.from({length:13},(_,i)=>({account:a.id,window:'seven_day',ts:now-(12-i)*900,remaining:a.windows[0].remaining+(12-i),reset:a.windows[0].reset})))};
for (const width of [390,1280]) {
 const context = {data,innerWidth:width,document:{querySelector:()=>({clientWidth:width})},$:()=>({value:'72'})};
 const result = vm.runInNewContext(source+`;graph(${JSON.stringify(accounts)},'claude','seven_day','#fff')`,context);
 assert.equal(result.burn,8);
 // Both burn 4 points/hour. At reset: 76+16, then only A becomes 100 => 116.
 assert.equal(result.projection[1][1],92);
 assert.equal(result.projection[2][1],116);
 assert(!result.html.includes('NaN'));
 assert(result.html.includes('stroke-dasharray'));
}
const short={...data,history:data.history.filter(h=>h.ts>now-900)};
const result=vm.runInNewContext(source+`;graph(${JSON.stringify(accounts)},'claude','seven_day','#fff')`,{data:short,innerWidth:390,document:{querySelector:()=>({clientWidth:390})},$:()=>({value:'72'})});
assert.equal(result.burn,null);
assert.equal(result.projection.length,0);
console.log('Quota graph: reset accounting, burn estimation, short history, desktop/mobile dimensions passed');
const makeContext = (measure, factor) => ({data,measure,burnHours:3,innerWidth:390,document:{querySelector:()=>({clientWidth:390}),getElementById:()=>({})},$:id=>({value:id==='future'?String(factor):'72'})});
const run = context => vm.runInNewContext(source+`;graph(${JSON.stringify(accounts)},'claude','seven_day','#fff')`,context);
assert.equal(run(makeContext('remaining',1)).firstEmpty,now+5*3600);
const idle=run(makeContext('remaining',0));
assert.equal(idle.firstEmpty,null);
assert.equal(idle.poolEmpty,null);
assert.equal(idle.projection.at(-1)[1],200);
const drain=run(makeContext('drain',1));
assert(drain.html.includes('%/h'));
assert(!drain.html.includes('stroke-dasharray'));
assert(!drain.html.includes('NaN'));
console.log('Chart modes, future usage scenarios and first depletion passed');
