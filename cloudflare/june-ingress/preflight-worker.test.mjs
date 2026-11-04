import assert from 'node:assert/strict';
import test from 'node:test';
import { handleProbe, ORIGIN } from './preflight-worker.mjs';
const env = { VERCEL_AUTOMATION_BYPASS_SECRET: 'synthetic-test-only' };
const target = 'https://ingress-preflight.dearjune.ai/__june_ingress_probe';
for (const [url, method] of [[target,'POST'],[target,'OPTIONS'],[target+'/','GET'],[target+'?x=1','GET'],[target.replace('ingress-preflight','www'),'GET'],[target.replace('https:','http:'),'GET'],[target.replace('/__june_ingress_probe','/june/git'),'GET']]) {
  test(`probe denies ${method} ${url} before fetch/body`, async () => {
    const req = new Request(url, {method, ...(['GET','HEAD'].includes(method)?{}:{body:'synthetic'})});
    const response=await handleProbe(req,env,()=>{throw new Error('must not fetch');});
    assert.equal(response.status,404);
    assert.equal(req.bodyUsed,false);
  });
}
test('probe missing binding fails closed',async()=>{
  assert.equal((await handleProbe(new Request(target),{},()=>{throw new Error('must not fetch');})).status,503);
});
for (const method of ['GET','HEAD']) test(`probe ${method} sends only fixed GET and private header; rejects redirect`,async()=>{
  const response=await handleProbe(new Request(target,{method,headers:{cookie:'synthetic',authorization:'synthetic','x-vercel-set-bypass-cookie':'true'}}),env,async (req,options)=>{
    assert.equal(req.url,ORIGIN); assert.equal(req.method,'GET'); assert.equal(req.redirect,'manual');
    assert.equal(req.body,null); assert.deepEqual([...req.headers],[['x-vercel-protection-bypass',env.VERCEL_AUTOMATION_BYPASS_SECRET]]);
    assert.deepEqual(options,{cf:{cacheEverything:false,cacheTtl:-1}});
    return new Response(null,{status:302,headers:{location:'https://untrusted.invalid'}});
  });
  assert.equal(response.status,502); assert.equal(response.headers.get('cache-control'),'no-store');
  if(method==='HEAD') assert.equal(await response.text(),'');
});
for(const [name,response] of [
 ['wrong size',()=>new Response('synthetic')],
 ['wrong hash',()=>new Response(new Uint8Array(15086))],
 ['oversize',()=>new Response(new Uint8Array(15087))],
 ['cookie',()=>new Response(null,{headers:{'set-cookie':'synthetic'}})],
]) test(`probe rejects ${name} without exposing origin`,async()=>{
 const r=await handleProbe(new Request(target),env,async()=>response());
 assert.equal(r.status,502); assert.equal(await r.text(),'Probe unavailable');
 assert.equal(r.headers.has('set-cookie'),false);
});
test('probe fetch failure returns generic denial',async()=>{
 const r=await handleProbe(new Request(target),env,async()=>{throw new Error('private detail');});
 assert.equal(r.status,502);assert.equal(await r.text(),'Probe unavailable');
});
