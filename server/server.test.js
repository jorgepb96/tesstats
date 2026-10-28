import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { generateKeyPairSync } from 'node:crypto'
import http from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { setTimeout as delay } from 'node:timers/promises'

const token = '0123456789abcdef'.repeat(4)

async function fixture(t, channels = {}) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'tesstats-push-test-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const deliveries = []
  const receiver = http.createServer(async (req, res) => {
    let body = ''
    for await (const chunk of req) body += chunk
    deliveries.push({ url: req.url, headers: req.headers, body })
    res.writeHead(200).end('ok')
  })
  receiver.listen(0, '127.0.0.1')
  await once(receiver, 'listening')
  t.after(() => { receiver.closeAllConnections(); receiver.close() })
  const target = `http://127.0.0.1:${receiver.address().port}`

  // Minimal local MQTT peer: acknowledge CONNECT without contacting a real broker.
  const sockets = new Set()
  const broker = net.createServer(socket => {
    sockets.add(socket)
    socket.on('close', () => sockets.delete(socket))
    socket.on('error', () => {})
    socket.once('data', () => socket.write(Buffer.from([0x20, 0x02, 0x00, 0x00])))
  })
  broker.listen(0, '127.0.0.1')
  await once(broker, 'listening')
  const disconnect = () => { for (const socket of sockets) socket.destroy(); broker.close() }
  t.after(disconnect)
  const env = {
    PATH: process.env.PATH,
    PORT: '0',
    MQTT_URL: `mqtt://127.0.0.1:${broker.address().port}`,
    REGISTER_TOKEN: 'test-secret',
    ...(channels.ntfy ? { NTFY_URL: target, NTFY_TOPIC: 'test-topic', NTFY_TOKEN: 'test-bearer' } : {}),
    ...(channels.incompleteNtfy ? { NTFY_URL: target } : {}),
    ...(channels.webhook ? { WEBHOOK_URL: `${target}/hook` } : {}),
  }
  if (channels.apns) {
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
    const keyPath = path.join(dir, 'test.p8')
    await writeFile(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }))
    Object.assign(env, { APNS_KEY_PATH: keyPath, APNS_KEY_ID: 'TEST', APNS_TEAM_ID: 'TEST' })
  }
  const child = spawn(process.execPath, [fileURLToPath(new URL('./server.js', import.meta.url))], { cwd: dir, env })
  t.after(async () => {
    if (child.exitCode === null) { child.kill(); await once(child, 'exit') }
  })
  let output = ''
  child.stdout.on('data', chunk => { output += chunk })
  child.stderr.on('data', chunk => { output += chunk })
  await until(() => /HTTP listening on \d+/.test(output), () => output)
  const base = `http://127.0.0.1:${output.match(/HTTP listening on (\d+)/)[1]}`
  const health = async () => (await fetch(`${base}/healthz`)).json()
  await until(async () => (await health()).mqttConnected, () => output)
  const post = (endpoint, body = {}) => fetch(`${base}${endpoint}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ secret: 'test-secret', ...body }),
  })
  return { dir, deliveries, health, post, disconnect }
}

async function until(predicate, details = () => '') {
  const deadline = Date.now() + 5000
  while (Date.now() < deadline) {
    if (await predicate()) return
    await delay(20)
  }
  assert.fail(`Timed out waiting for bridge: ${details()}`)
}

for (const channels of [{ ntfy: true }, { webhook: true }, { ntfy: true, webhook: true }]) {
  test(`registration and diagnostic delivery without APNs: ${JSON.stringify(channels)}`, async t => {
    const f = await fixture(t, channels)
    const health = await f.health()
    assert.equal(health.apnsConfigured, false)
    assert.equal(health.ntfyConfigured, Boolean(channels.ntfy))
    assert.equal(health.webhookConfigured, Boolean(channels.webhook))
    const response = await f.post('/register', { token, preferences: { enabled: true } })
    assert.equal(response.status, 200)
    assert.equal(await response.text(), 'ok')
    assert.deepEqual(JSON.parse(await readFile(path.join(f.dir, 'tokens.json'))), [token])
    assert.equal((await f.health()).preferenceProfiles, 1)
    const activity = await f.post('/register-live-activity', { token, carId: 1 })
    assert.equal(activity.status, 503)
    assert.match(await activity.text(), /APNs is required/)
    const diagnostic = await f.post('/test', { title: 'Test title', message: 'Test body' })
    assert.equal(diagnostic.status, 202)
    await until(() => f.deliveries.length === Number(Boolean(channels.ntfy)) + Number(Boolean(channels.webhook)))
    if (channels.ntfy) {
      const ntfy = f.deliveries.find(item => item.url === '/test-topic')
      assert.equal(ntfy.body, 'Test body')
      assert.equal(ntfy.headers.title, 'Test title')
      assert.equal(ntfy.headers.authorization, 'Bearer test-bearer')
    }
    if (channels.webhook) {
      const payload = JSON.parse(f.deliveries.find(item => item.url === '/hook').body)
      assert.equal(payload.title, 'Test title')
      assert.equal(payload.body, 'Test body')
      assert.equal(payload.event, 'test')
    }
  })
}

for (const channels of [{}, { incompleteNtfy: true }]) {
  test(`missing or incomplete notification configuration is rejected: ${JSON.stringify(channels)}`, async t => {
    const f = await fixture(t, channels)
    assert.equal((await f.health()).ntfyConfigured, false)
    for (const endpoint of ['/register', '/test']) {
      const response = await f.post(endpoint, { token })
      assert.equal(response.status, 503)
      assert.match(await response.text(), /No notification channel/)
    }
  })
}

test('APNs registration stays compatible and malformed Live Activities cannot become device tokens', async t => {
  const f = await fixture(t, { apns: true })
  const health = await f.health()
  assert.equal(health.apnsConfigured, true)
  assert.equal(health.apnsEnvironment, 'production')
  assert.equal((await f.post('/register', { token })).status, 200)
  assert.equal((await f.post('/register-live-activity', { token: 'ab'.repeat(32) })).status, 400)
  assert.equal((await f.health()).tokens, 1)
  assert.equal((await f.post('/register-live-activity', { token, carId: 1 })).status, 200)
  assert.equal((await f.health()).liveActivityTokens, 1)
})

test('authentication, bad tokens and MQTT readiness are enforced for alternative channels', async t => {
  const f = await fixture(t, { ntfy: true })
  for (const endpoint of ['/register', '/register-live-activity', '/test']) {
    assert.equal((await f.post(endpoint, { token, secret: 'wrong-secret' })).status, 401)
  }
  assert.equal((await f.post('/register', { token: 'invalid' })).status, 400)
  f.disconnect()
  await until(async () => !(await f.health()).mqttConnected)
  assert.equal((await f.post('/test')).status, 503)
  assert.equal(f.deliveries.length, 0)
})
