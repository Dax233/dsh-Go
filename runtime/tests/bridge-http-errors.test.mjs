// Real bridge HTTP dispatch with modeled Cordis/Connection services; no DSH prefix.
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {createServer} from 'node:http';
import {test} from 'node:test';
import {apply} from '../bridge/dsh-go-bridge/lib/index.js';

async function fixture(t, {connection = true, guardRoutes = false} = {}) {
  const dispose = [];
  const webServer = {
    exact: new Map(), prefixes: new Map(), upgrades: new Map(),
    register(route) {
      const table = route.kind === 'exact' ? this.exact : this.prefixes;
      table.set(route.path, route);
      return () => table.delete(route.path);
    },
    registerUpgrade(route) { this.upgrades.set(route.path, route); return () => this.upgrades.delete(route.path); },
    getOrigin: () => `http://127.0.0.1:${server.address().port}`,
  };
  webServer.register({kind: 'exact', path: '/fixture-route', handler(_req, res) { res.end('fixture'); }});
  const ctx = {
    webServer, logger: {warn() {}}, on() {}, provide() {},
    get: name => name === 'connection' && connection ? {requestRejection: () => undefined} : undefined,
    effect(fn) { const stop = fn(); if (typeof stop === 'function') dispose.push(stop); },
    inject(_deps, fn) { fn(ctx); },
  };
  apply(ctx, {persist: false, guardRoutes});
  const server = createServer((req, res) => {
    const path = new URL(req.url, 'http://dsh-go.invalid').pathname;
    const route = webServer.exact.get(path) ?? [...webServer.prefixes.values()].find(r => path.startsWith(r.path));
    if (route) void route.handler(req, res);
    else { res.writeHead(404); res.end(); }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    dispose.reverse().forEach(stop => stop());
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  });
  return async (path, init = {}) => {
    const response = await fetch(`${webServer.getOrigin()}${path}`, init);
    const text = await response.text();
    return {status: response.status, headers: response.headers, text, body: text.startsWith('{') ? JSON.parse(text) : text};
  };
}

test('bridge business errors share a nested shape and retain HTTP status', async t => {
  const request = await fixture(t);
  const occupancy = '/dsh-go/v1/occupancy';
  const post = body => ({method: 'POST', headers: {'content-type': 'application/json'}, body});
  for (const [path, init, status, code] of [
    ['/dsh-go/v1/inventory', {method: 'POST'}, 405, 'method-not-allowed'],
    [occupancy, {}, 405, 'method-not-allowed'],
    [occupancy, {method: 'POST', body: '{}'}, 415, 'unsupported-media-type'],
    [occupancy, post('invalid JSON'), 400, 'bad-request'],
    [occupancy, post('{}'), 400, 'bad-request'],
    [occupancy, post(' '.repeat(512 * 1024 + 1)), 413, 'too-large'],
    [occupancy, post(JSON.stringify({bootRev: 'b1', slots: Object.fromEntries(Array.from({length: 401}, (_, i) => [`slot-${i}`, []]))})), 413, 'too-large'],
    ['/dsh-go/v1/unknown', {}, 404, 'route-not-found'],
    ['/dsh-go/v1/plugin-config', {method: 'DELETE'}, 405, 'invalid-operation'],
    ['/dsh-go/v1/plugin-config/item', {method: 'DELETE'}, 405, 'invalid-operation'],
    ['/dsh-go/v1/plugin-config', {}, 503, 'host-unavailable'],
    ['/dsh-go/v1/sessions/deletion', {method: 'POST'}, 405, 'unavailable'],
  ]) {
    const response = await request(path, init);
    assert.equal(response.status, status, `${init.method ?? 'GET'} ${path}`);
    assert.equal(response.body.error.code, code);
    assert.equal(typeof response.body.error.message, 'string');
    assert.ok(response.body.error.message.length > 0);
    assert.equal('code' in response.body, false);
    assert.match(response.headers.get('content-type'), /^application\/json/);
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  const accepted = await request(occupancy, post(JSON.stringify({bootRev: 'b1', slots: {}})));
  assert.equal(accepted.status, 204);
  assert.equal(accepted.text, '');
});

for (const guardRoutes of [false, true]) test(`missing Connection preserves route-specific failures, fallback=${guardRoutes}`, async t => {
  const request = await fixture(t, {connection: false, guardRoutes});
  for (const path of ['/dsh-go/v1/plugin-config', '/dsh-go/v1/plugin-config/item']) {
    const response = await request(path);
    assert.equal(response.status, 503);
    assert.equal(response.body.v, 1);
    assert.equal(response.body.error.code, 'host-unavailable');
    assert.equal('code' in response.body, false);
    const head = await request(path, {method: 'HEAD'});
    assert.equal(head.status, 503);
    assert.equal(head.text, '');
    assert.match(head.headers.get('content-type'), /^application\/json/);
  }
  const deletion = await request('/dsh-go/v1/sessions/delete', {method: 'POST'});
  assert.equal(deletion.status, 503);
  assert.equal(deletion.body.error.code, 'unavailable');
  const ordinary = await request('/dsh-go/v1/inventory');
  assert.equal(ordinary.status, 503);
  assert.equal(ordinary.text, 'Service Unavailable\n');
  if (guardRoutes) {
    assert.equal(ordinary.headers.get('x-dsh-go-guard'), 'reject');
    const external = await request('/fixture-route');
    assert.equal(external.status, 503);
    assert.equal(external.text, 'Service Unavailable\n');
  }
});
