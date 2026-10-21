// Served only by the private loopback fixture, never injected into a user page.
window.ctrlxCORSProbe = async () => {
  const cross = new URL(location.origin);
  cross.hostname = 'localhost';
  const fetchResult = async (path, options = {}, origin = cross.origin) => {
    try {
      const response = await fetch(origin + path, {
        cache: 'no-store', signal: AbortSignal.timeout(3000), ...options
      });
      return {ok: response.ok, body: await response.json(),
        responseHeader: response.headers.get('x-ctrlx-response')};
    } catch (error) {
      return {ok: false, error: String(error)};
    }
  };
  const same = await fetchResult('/cors/echo', {}, location.origin);
  const get = await fetchResult('/cors/echo');
  const post = await fetchResult('/cors/post', {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: '{}'
  });
  const redirect = await fetchResult('/cors/redirect');
  const script = await new Promise(resolve => {
    delete window.ctrlxCORSScript;
    const element = document.createElement('script');
    const finish = result => { clearTimeout(timeout); element.remove(); resolve(result); };
    const timeout = setTimeout(() => finish({ok: false, error: 'timeout'}), 3000);
    element.crossOrigin = 'anonymous';
    element.onload = () => finish({ok: true, header: window.ctrlxCORSScript});
    element.onerror = () => finish({ok: false});
    element.src = cross.origin + '/cors/script.js';
    document.head.append(element);
  });
  const deniedOrigin = await fetchResult('/cors/no-origin');
  const deniedHeader = await fetchResult('/cors/page-header', {headers: {'x-ctrlx-page': 'blocked'}});
  const deniedSameHeader = await fetchResult('/cors/page-env-header', {headers: {'x-maas-env': 'page-added'}});
  return {same, get, post, redirect, script, deniedOrigin, deniedHeader, deniedSameHeader};
};
