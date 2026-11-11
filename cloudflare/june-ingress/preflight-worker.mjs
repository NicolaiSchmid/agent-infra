// Temporary, isolated credential/access probe. Never returns origin content.
export const ORIGIN = 'https://june-mqsea5c26-wasc.vercel.app/favicon.ico';
export const EXPECTED_SHA256 = '3a6c67ab3abcf4f39dbc1970267c6963279d7f48aa5d24b965b37e76999e0cd8';
const EXPECTED_BYTES = 15086;
function result(status, method) {
  return new Response(method === 'HEAD' ? null : (status === 200 ? 'Protected origin probe passed' : 'Probe unavailable'), {
    status, headers: { 'Cache-Control': 'no-store', 'X-June-Ingress-Probe': status === 200 ? 'pass' : 'deny' },
  });
}
export async function handleProbe(request, env, upstream = fetch) {
  const url = new URL(request.url);
  if (url.protocol !== 'https:' || url.host !== 'ingress-preflight.dearjune.ai' ||
      url.pathname !== '/__june_ingress_probe' || request.url.split('#', 1)[0].includes('?') ||
      !['GET', 'HEAD'].includes(request.method)) return result(404, request.method);
  if (!env.VERCEL_AUTOMATION_BYPASS_SECRET?.trim()) return result(503, request.method);
  try {
    // HEAD callers also trigger the same fixed GET, so status alone cannot pass.
    const response = await upstream(new Request(ORIGIN, {
      method: 'GET', redirect: 'manual',
      headers: { 'x-vercel-protection-bypass': env.VERCEL_AUTOMATION_BYPASS_SECRET },
    }), { cf: { cacheEverything: false, cacheTtl: -1 } });
    if (response.status !== 200 || response.headers.has('set-cookie')) {
      await response.body?.cancel();
      return result(502, request.method);
    }
    // Bound transient memory to the reviewed static resource size; never log/store it.
    const reader = response.body?.getReader();
    if (!reader) return result(502, request.method);
    const bytes = new Uint8Array(EXPECTED_BYTES);
    let length = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (length + value.byteLength > bytes.length) {
        await reader.cancel();
        return result(502, request.method);
      }
      bytes.set(value, length);
      length += value.byteLength;
    }
    if (length !== EXPECTED_BYTES) return result(502, request.method);
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    const hash = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
    return result(hash === EXPECTED_SHA256 ? 200 : 502, request.method);
  } catch {
    return result(502, request.method);
  }
}
export default { fetch: (request, env) => handleProbe(request, env) };
