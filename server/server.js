// Tesstats push microservice
// ----------------------------------------------------------------------------
// OPTIONAL. Bridges TeslaMate MQTT events to instant notifications (e.g. a
// possible Sentry event) even when the Tesstats app is closed, via any of:
//
//   • APNs      — native pushes to the app. Requires an Apple Developer key AND
//                 an app signed with the push entitlement (Xcode/TestFlight).
//                 Sideloaded (AltStore) builds are signed with a free profile
//                 that STRIPS the entitlement — APNs can never reach them.
//   • ntfy      — pushes to the ntfy app (ntfy.sh or self-hosted). Works for
//                 sideloaded installs, no Apple account needed. Recommended.
//   • webhook   — POSTs JSON to any URL (Home Assistant, Node-RED, …) so you
//                 can chain automations: sirens, lights, Telegram, anything.
//
// The app itself works fine without this service — it just relies on local
// notifications while running. See README.md for setup.
//
// Zero third-party deps except `mqtt`. APNs auth (ES256 JWT) and the HTTP/2 push
// use Node's built-in `crypto`, `http2`, `http` and `fs`; ntfy/webhook use fetch.

import mqtt from 'mqtt'
import http from 'node:http'
import http2 from 'node:http2'
import crypto from 'node:crypto'
import fs from 'node:fs'
import { inspectCharges, needsLocationPrice } from './charge-reminders.js'

// ---- Config (env) ----------------------------------------------------------
const cfg = {
  mqttUrl: process.env.MQTT_URL || 'mqtt://mosquitto:1883',   // mqtt(s)/ws(s)
  mqttUser: process.env.MQTT_USERNAME || '',
  mqttPass: process.env.MQTT_PASSWORD || '',
  basicAuth: process.env.MQTT_BASIC_AUTH || '',               // "user:pass" for wss reverse proxy
  // Cloudflare Access service token, for a wss broker / history API published through Access
  cfAccessClientId: process.env.CF_ACCESS_CLIENT_ID || '',
  cfAccessClientSecret: process.env.CF_ACCESS_CLIENT_SECRET || '',
  topicRoot: process.env.TOPIC_ROOT || 'teslamate/cars',
  httpPort: parseInt(process.env.PORT || '8090', 10),
  registerToken: process.env.REGISTER_TOKEN || '',            // shared secret the app must send
  tokensFile: process.env.TOKENS_FILE || './tokens.json',
  liveActivityTokensFile: process.env.LIVE_ACTIVITY_TOKENS_FILE || './live-activity-tokens.json',
  devicePreferencesFile: process.env.DEVICE_PREFERENCES_FILE || './device-preferences.json',
  historyURL: (process.env.HISTORY_API_URL || '').replace(/\/+$/, ''),
  historyAuthorization: process.env.HISTORY_API_AUTHORIZATION || '',
  chargeRemindersFile: process.env.CHARGE_REMINDERS_FILE || './charge-reminders.json',
  // APNs
  apnsKeyPath: process.env.APNS_KEY_PATH || '',               // AuthKey_XXXX.p8
  apnsKeyId: process.env.APNS_KEY_ID || '',
  apnsTeamId: process.env.APNS_TEAM_ID || '',
  bundleId: process.env.APNS_BUNDLE_ID || 'com.tesstats.app',
  // TestFlight and App Store device tokens always belong to production APNs.
  production: (process.env.APNS_PRODUCTION || 'true') === 'true',
  // ntfy (https://ntfy.sh or self-hosted) — works for sideloaded apps, no Apple account
  ntfyUrl: process.env.NTFY_URL || '',                        // e.g. https://ntfy.sh
  ntfyTopic: process.env.NTFY_TOPIC || '',
  ntfyToken: process.env.NTFY_TOKEN || '',                    // optional Bearer token
  // Generic webhook (Home Assistant, Node-RED, …): POSTs JSON per event
  webhookUrl: process.env.WEBHOOK_URL || '',
  // Which events to push
  notifySentry: (process.env.NOTIFY_SENTRY || 'true') === 'true',
  notifyUnlocked: (process.env.NOTIFY_UNLOCKED || 'true') === 'true',
  notifyOpenings: (process.env.NOTIFY_OPENINGS || 'true') === 'true',
  // One Sentry alert per burst: a single incident re-triggers the banner repeatedly
  sentryCooldownSec: parseInt(process.env.SENTRY_COOLDOWN_SEC || '600', 10),
}
const apnsConfigured = Boolean(
  cfg.apnsKeyPath && cfg.apnsKeyId && cfg.apnsTeamId && fs.existsSync(cfg.apnsKeyPath)
)

// ---- Device token store ----------------------------------------------------
let tokens = new Set()
try { tokens = new Set(JSON.parse(fs.readFileSync(cfg.tokensFile, 'utf8'))) } catch {}
const saveTokens = () => { try { fs.writeFileSync(cfg.tokensFile, JSON.stringify([...tokens])) } catch (e) { console.error('save tokens', e) } }
let devicePreferences = new Map()
try {
  const saved = JSON.parse(fs.readFileSync(cfg.devicePreferencesFile, 'utf8'))
  if (saved && typeof saved === 'object') devicePreferences = new Map(Object.entries(saved))
} catch {}
const saveDevicePreferences = () => {
  try { fs.writeFileSync(cfg.devicePreferencesFile, JSON.stringify(Object.fromEntries(devicePreferences))) }
  catch (e) { console.error('save device preferences', e) }
}

// Live Activity tokens are short-lived and scoped to one activity. Metadata is stored with
// each token because ActivityKit's content-state must be rendered in the user's units,
// language and chosen accent even while the app process is suspended.
let liveActivityTokens = new Map()
try {
  const saved = JSON.parse(fs.readFileSync(cfg.liveActivityTokensFile, 'utf8'))
  if (Array.isArray(saved)) {
    liveActivityTokens = new Map(saved.filter((item) => item && typeof item.token === 'string').map((item) => [item.token, item]))
  }
} catch {}
const saveLiveActivityTokens = () => {
  try { fs.writeFileSync(cfg.liveActivityTokensFile, JSON.stringify([...liveActivityTokens.values()])) }
  catch (e) { console.error('save live activity tokens', e) }
}

// ---- APNs (HTTP/2 + ES256 JWT) --------------------------------------------
let apnsJwt = { token: null, iat: 0 }
function apnsAuthToken() {
  const now = Math.floor(Date.now() / 1000)
  if (apnsJwt.token && now - apnsJwt.iat < 2400) return apnsJwt.token // reuse < 40 min
  const key = fs.readFileSync(cfg.apnsKeyPath, 'utf8')
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: cfg.apnsKeyId }))
  const claims = b64url(JSON.stringify({ iss: cfg.apnsTeamId, iat: now }))
  const signer = crypto.createSign('SHA256')
  signer.update(`${header}.${claims}`)
  const sig = signer.sign({ key, dsaEncoding: 'ieee-p1363' })
  apnsJwt = { token: `${header}.${claims}.${b64urlBuf(sig)}`, iat: now }
  return apnsJwt.token
}
const b64url = (s) => Buffer.from(s).toString('base64url')
const b64urlBuf = (b) => b.toString('base64url')

// Fan an event out to every configured channel. `extra.event` tags the kind
// ('sentry' | 'unlocked' | 'open') so receivers can filter/automate.
function notify(title, body, extra = {}) {
  if (!apnsConfigured && !cfg.ntfyUrl && !cfg.webhookUrl) {
    console.log('[no notification channel configured]', title, body)
    return
  }
  pushAll(title, body, extra)
  ntfyPush(title, body, extra)
  webhookPost(title, body, extra)
}

// ---- ntfy ------------------------------------------------------------------
async function ntfyPush(title, body, extra = {}) {
  if (!cfg.ntfyUrl || !cfg.ntfyTopic) return
  try {
    const sentry = extra.event === 'sentry'
    const headers = {
      Title: title,
      Priority: sentry ? 'urgent' : 'high',           // urgent = ntfy's max, bypasses DND if allowed
      Tags: sentry ? 'rotating_light' : 'bell',
    }
    if (cfg.ntfyToken) headers.Authorization = `Bearer ${cfg.ntfyToken}`
    const url = `${cfg.ntfyUrl.replace(/\/+$/, '')}/${cfg.ntfyTopic}`
    const res = await fetch(url, { method: 'POST', body, headers })
    if (!res.ok) console.warn('ntfy', res.status, await res.text().catch(() => ''))
  } catch (e) { console.error('ntfy error', e.message) }
}

// ---- Generic webhook (Home Assistant etc.) ---------------------------------
async function webhookPost(title, body, extra = {}) {
  if (!cfg.webhookUrl) return
  try {
    const res = await fetch(cfg.webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title, body, ...extra, ts: new Date().toISOString() }),
    })
    if (!res.ok) console.warn('webhook', res.status)
  } catch (e) { console.error('webhook error', e.message) }
}

// ---- APNs push --------------------------------------------------------------
function pushAll(title, body, extra = {}, selectedTokens = tokens) {
  if (!apnsConfigured) return
  const host = cfg.production ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com'
  const payload = JSON.stringify({
    aps: {
      alert: { title, body },
      // The app bundles a distinct alarm for Sentry alerts.
      sound: extra.event === 'sentry' ? 'sentry-alert.wav' : 'default',
      'interruption-level': extra.event === 'sentry' ? 'time-sensitive' : 'active',
    },
    ...extra,
  })
  let jwt
  try { jwt = apnsAuthToken() } catch (e) { console.error('APNs JWT error', e); return }
  const client = http2.connect(host)
  client.on('error', (e) => console.error('APNs conn', e.message))
  for (const token of selectedTokens) {
    if (!deviceAllows(token, extra.event)) continue
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${token}`,
      'authorization': `bearer ${jwt}`,
      'apns-topic': cfg.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
    })
    let status = 0
    req.on('error', (error) => console.warn('APNs request', error.message))
    req.setTimeout(15000, () => req.close())
    req.on('response', (h) => { status = h[':status'] })
    let data = ''
    req.on('data', (d) => data += d)
    req.on('end', () => {
      if (status !== 200) {
        console.warn('APNs', status, data)
        if (status === 410 || /BadDeviceToken/.test(data)) { tokens.delete(token); saveTokens() } // prune dead tokens
      }
    })
    req.end(payload)
  }
  setTimeout(() => client.close(), 4000)
}

function deviceAllows(token, event) {
  if (!event || event === 'test') return true
  const prefs = devicePreferences.get(token)
  if (!prefs || prefs.enabled === undefined) return true // registrations from older releases
  if (!prefs.enabled) return false
  const key = {
    'charge-started': 'chargeStarted',
    'charge-complete': 'chargeComplete',
    'charge-cost': 'chargeCostMissing',
    'charge-target': 'chargeTargetReached',
    'unplugged': 'leftUnplugged',
    'plugged-idle': 'pluggedNotCharging',
    'unlocked': 'openingsOrUnlocked',
    'open': 'openingsOrUnlocked',
    'software-update': 'softwareUpdate',
    'geofence': 'geofence',
    'sentry': 'sentryInferred',
  }[event]
  return key ? prefs[key] !== false : true
}

// ---- ActivityKit remote updates -------------------------------------------
const liveUpdateTimers = new Map()

function scheduleLiveActivityUpdate(carId) {
  // Throttle, do not debounce: continuous MQTT updates used to postpone delivery forever.
  if (liveUpdateTimers.has(carId)) return
  liveUpdateTimers.set(carId, setTimeout(() => {
    liveUpdateTimers.delete(carId)
    pushLiveActivities(carId)
  }, 5000))
}

function numberOr(value, fallback = 0) {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

function liveRange(c, kind) {
  if (kind === 'estimated') return numberOr(c.estBatteryRangeKm, numberOr(c.ratedBatteryRangeKm))
  if (kind === 'ideal') return numberOr(c.idealBatteryRangeKm, numberOr(c.ratedBatteryRangeKm))
  return numberOr(c.ratedBatteryRangeKm, numberOr(c.estBatteryRangeKm))
}

function pushLiveActivities(carId) {
  if (!apnsConfigured) return
  const c = cars[carId]
  // TeslaMate delivers retained topics independently. Do not infer "not charging"
  // until the charging_state topic has actually arrived, otherwise a freshly
  // registered ActivityKit token can receive an erroneous end event.
  if (!c || c.chargingState == null) return
  const matching = [...liveActivityTokens.values()].filter((item) => String(item.carId) === String(carId))
  if (!matching.length) return

  const host = cfg.production ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com'
  let jwt
  try { jwt = apnsAuthToken() } catch (e) { console.error('ActivityKit APNs JWT error', e); return }
  const client = http2.connect(host)
  client.on('error', (e) => console.error('ActivityKit APNs conn', e.message))

  for (const item of matching) {
    const charging = String(c.chargingState || '').toLowerCase() === 'charging'
    const contentState = {
      batteryLevel: Math.round(numberOr(c.batteryLevel)),
      chargeLimitSoc: Math.round(numberOr(c.chargeLimitSoc, 100)),
      chargerPowerKw: numberOr(c.chargerPowerKw),
      timeToFullHours: numberOr(c.timeToFullHours),
      rangeKm: liveRange(c, item.rangeKind),
      isImperial: Boolean(item.isImperial),
      isComplete: !charging,
      languageCode: item.languageCode === 'es' ? 'es' : 'en',
      accentColorHex: /^[0-9a-f]{6}$/i.test(item.accentColorHex || '') ? item.accentColorHex : '3E6AE1',
    }
    const aps = {
      timestamp: Math.floor(Date.now() / 1000),
      event: charging ? 'update' : 'end',
      'content-state': contentState,
    }
    if (!charging) aps['dismissal-date'] = Math.floor(Date.now() / 1000) + 8
    const payload = JSON.stringify({ aps })
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${item.token}`,
      authorization: `bearer ${jwt}`,
      'apns-topic': `${cfg.bundleId}.push-type.liveactivity`,
      'apns-push-type': 'liveactivity',
      // Routine progress must not exhaust the high-priority ActivityKit push budget.
      'apns-priority': charging ? '5' : '10',
    })
    req.on('error', (error) => console.warn('ActivityKit request', error.message))
    req.setTimeout(15000, () => req.close())
    let status = 0
    let data = ''
    req.on('response', (headers) => { status = headers[':status'] })
    req.on('data', (chunk) => { data += chunk })
    req.on('end', () => {
      if (status !== 200) {
        console.warn('ActivityKit APNs', status, data)
        if (status === 410 || /BadDeviceToken|Unregistered/.test(data)) {
          liveActivityTokens.delete(item.token)
          saveLiveActivityTokens()
        }
      }
    })
    req.end(payload)
  }
  setTimeout(() => client.close(), 4000)
}

// ---- Event detection from MQTT --------------------------------------------
const cars = {} // carId -> { name, lastCenterDisplay, locked, anyOpen, parked }

function handle(carId, metric, value) {
  const c = (cars[carId] ||= { name: `Car ${carId}` })
  let affectsLiveActivity = false
  switch (metric) {
    case 'display_name': c.name = value; break
    case 'shift_state': {
      const wasDriving = c.parked === false
      c.parked = (value !== 'D' && value !== 'R')
      if (wasDriving && c.parked && c.pluggedIn === false) {
        notify('Not plugged in', `${c.name} was parked without being plugged in.`, { carId, event: 'unplugged' })
      }
      break
    }
    case 'center_display_state': {
      const v = parseInt(value, 10)
      if (cfg.notifySentry && c.lastCenterDisplay !== 7 && v === 7) {
        const now = Date.now()
        // One alert per burst — a single incident re-triggers the banner repeatedly.
        if (!c.lastSentryAt || now - c.lastSentryAt >= cfg.sentryCooldownSec * 1000) {
          c.lastSentryAt = now
          notify('Possible Sentry event',
            `${c.name} showed the Sentry banner. Inferred from the screen — any clip is on the car's USB.`,
            { carId, event: 'sentry' })
        }
      }
      c.lastCenterDisplay = v
      break
    }
    case 'locked': {
      const locked = value === 'true'
      if (cfg.notifyUnlocked && c.locked === true && !locked && c.parked) {
        notify('Vehicle unlocked', `${c.name} was unlocked while parked.`, { carId, event: 'unlocked' })
      }
      c.locked = locked
      break
    }
    case 'doors_open': case 'frunk_open': case 'trunk_open': case 'windows_open': {
      const open = value === 'true'
      if (cfg.notifyOpenings && open && c[metric] === false && c.parked) {
        notify('Something is open', `${metric.replace('_', ' ')} on ${c.name} is open.`, { carId, event: 'open' })
      }
      c[metric] = open
      break
    }
    case 'battery_level': {
      const previous = numberOr(c.batteryLevel, -1)
      c.batteryLevel = value
      const current = numberOr(value, -1)
      const target = numberOr(c.chargeLimitSoc, 101)
      if (previous >= 0 && previous < target && current >= target && (c.pluggedIn || String(c.chargingState).toLowerCase() === 'charging')) {
        notify('Charge limit reached', `${c.name} reached its ${target}% charge limit.`, { carId, event: 'charge-target' })
      }
      affectsLiveActivity = true
      break
    }
    case 'charge_limit_soc': c.chargeLimitSoc = value; affectsLiveActivity = true; break
    case 'charger_power': c.chargerPowerKw = value; affectsLiveActivity = true; break
    case 'time_to_full_charge': c.timeToFullHours = value; affectsLiveActivity = true; break
    case 'rated_battery_range_km': c.ratedBatteryRangeKm = value; affectsLiveActivity = true; break
    case 'est_battery_range_km': c.estBatteryRangeKm = value; affectsLiveActivity = true; break
    case 'ideal_battery_range_km': c.idealBatteryRangeKm = value; affectsLiveActivity = true; break
    case 'charging_state': {
      const previous = String(c.chargingState || '').toLowerCase()
      const current = String(value).toLowerCase()
      c.chargingState = value
      if (previous && previous !== 'charging' && current === 'charging') {
        notify('Charging started', `${c.name} started charging at ${Math.round(numberOr(c.batteryLevel))}%.`, { carId, event: 'charge-started' })
      }
      if (previous && previous !== 'complete' && current === 'complete') {
        notify('Charging complete', `${c.name} finished charging at ${Math.round(numberOr(c.batteryLevel, 100))}%.`, { carId, event: 'charge-complete' })
      }
      if (previous && previous !== 'stopped' && current === 'stopped' && c.pluggedIn) {
        notify('Plugged in, not charging', `${c.name} is connected but charging is stopped.`, { carId, event: 'plugged-idle' })
      }
      affectsLiveActivity = true
      break
    }
    case 'plugged_in': c.pluggedIn = value === 'true'; break
    case 'update_available': {
      const available = value === 'true'
      if (c.updateAvailable === false && available) {
        notify('Software update available', `${c.name} has a software update ready.`, { carId, event: 'software-update' })
      }
      c.updateAvailable = available
      break
    }
    case 'geofence': {
      if (c.geofence !== undefined && c.geofence !== value) {
        const detail = value ? `entered ${value}` : `left ${c.geofence}`
        notify(value ? 'Arrived' : 'Departed', `${c.name} ${detail}.`, { carId, event: 'geofence' })
      }
      c.geofence = value
      break
    }
  }
  if (affectsLiveActivity) scheduleLiveActivityUpdate(carId)
}

// ---- MQTT ------------------------------------------------------------------
const cfAccessHeaders = cfg.cfAccessClientId && cfg.cfAccessClientSecret
  ? { 'CF-Access-Client-Id': cfg.cfAccessClientId, 'CF-Access-Client-Secret': cfg.cfAccessClientSecret }
  : {}
const mqttOptions = { reconnectPeriod: 5000 }
if (cfg.mqttUser) { mqttOptions.username = cfg.mqttUser; mqttOptions.password = cfg.mqttPass }
const wsHeaders = { ...cfAccessHeaders }
if (cfg.basicAuth) wsHeaders.Authorization = 'Basic ' + Buffer.from(cfg.basicAuth).toString('base64')
if (Object.keys(wsHeaders).length) mqttOptions.wsOptions = { headers: wsHeaders }
const client = mqtt.connect(cfg.mqttUrl, mqttOptions)
client.on('connect', () => {
  console.log('MQTT connected:', cfg.mqttUrl)
  client.subscribe(`${cfg.topicRoot}/+/#`)
})
client.on('error', (e) => console.error('MQTT error', e.message))
client.on('message', (topic, payload) => {
  const rest = topic.startsWith(cfg.topicRoot + '/') ? topic.slice(cfg.topicRoot.length + 1) : null
  if (!rest) return
  const i = rest.indexOf('/')
  if (i < 0) return
  const carId = rest.slice(0, i)
  const metric = rest.slice(i + 1)
  handle(carId, metric, payload.toString())
})

// An always-on bridge can inspect charge IDs while iOS is suspended. Only a server-side,
// operator-configured API URL is used: never fetch a URL supplied by a device registration.
let chargeReminderStates = {}
try { chargeReminderStates = JSON.parse(fs.readFileSync(cfg.chargeRemindersFile, 'utf8')) } catch {}
let pollingCharges = false
async function pollChargeCosts() {
  if (!cfg.historyURL || pollingCharges) return
  pollingCharges = true
  try {
    for (const carId of Object.keys(cars)) {
      if (!/^\d+$/.test(carId)) continue
      const headers = { ...cfAccessHeaders }
      if (cfg.historyAuthorization) headers.Authorization = cfg.historyAuthorization
      const charges = []
      const ids = new Set()
      // Seed known locations from history, not just the latest page, so an old charging
      // point does not become "new" merely because the bridge was recently installed.
      const pages = chargeReminderStates[carId]?.initialized ? 1 : 50
      for (let page = 1; page <= pages; page++) {
        const response = await fetch(`${cfg.historyURL}/v1/cars/${carId}/charges?page=${page}`,
          { headers, signal: AbortSignal.timeout(15000) })
        if (!response.ok) throw new Error(`History API ${response.status}`)
        const payload = await response.json()
        if (!Array.isArray(payload.data?.charges)) throw new Error('Invalid charges response')
        const fresh = payload.data.charges.filter(charge => !ids.has(charge.charge_id))
        if (!fresh.length) break
        for (const charge of fresh) ids.add(charge.charge_id)
        charges.push(...fresh)
      }
      const result = inspectCharges(chargeReminderStates[carId], charges)
      chargeReminderStates[carId] = result.state
      fs.writeFileSync(cfg.chargeRemindersFile, JSON.stringify(chargeReminderStates))
      for (const reminder of result.reminders) {
        const recipients = [...tokens].filter(token => needsLocationPrice(devicePreferences.get(token), reminder.location))
        pushAll('Add charging cost', `${reminder.location}: tap to enter the charging price.`,
          { event: 'charge-cost', carId: Number(carId), chargeId: reminder.chargeId }, recipients)
      }
    }
  } catch (error) { console.warn('Charging cost sync:', error.message) }
  finally { pollingCharges = false }
}
setInterval(pollChargeCosts, 30000).unref()

// ---- HTTP: token registration ---------------------------------------------
const httpServer = http.createServer((req, res) => {
  if (req.method === 'POST' && (req.url === '/register' || req.url === '/register-live-activity' || req.url === '/test')) {
    let body = ''
    req.on('data', (d) => { body += d; if (body.length > 1e4) req.destroy() })
    req.on('end', () => {
      try {
        const parsed = JSON.parse(body || '{}')
        const { token, secret, title, message } = parsed
        if (cfg.registerToken && secret !== cfg.registerToken) { res.writeHead(401).end('unauthorized'); return }
        if (!apnsConfigured) { res.writeHead(503).end('APNs is not configured'); return }
        if (req.url === '/test') {
          if (!client.connected) { res.writeHead(503).end('MQTT disconnected'); return }
          pushAll(
            typeof title === 'string' && title ? title.slice(0, 120) : 'Tesstats test',
            typeof message === 'string' && message ? message.slice(0, 500) : 'Remote notifications are working.',
            { event: 'test' }
          )
          res.writeHead(202).end('accepted')
        // Apple documents device tokens as variable-length binary values. Accept a sensible
        // even-length hexadecimal token instead of hard-coding today's 32-byte representation.
        } else if (req.url === '/register-live-activity' &&
                   typeof token === 'string' && /^(?:[0-9a-fA-F]{2}){8,256}$/.test(token) &&
                   Number.isInteger(parsed.carId)) {
          liveActivityTokens.set(token, {
            token,
            carId: parsed.carId,
            isImperial: Boolean(parsed.isImperial),
            languageCode: parsed.languageCode === 'es' ? 'es' : 'en',
            accentColorHex: /^[0-9a-f]{6}$/i.test(parsed.accentColorHex || '') ? parsed.accentColorHex : '3E6AE1',
            rangeKind: ['rated', 'estimated', 'ideal'].includes(parsed.rangeKind) ? parsed.rangeKind : 'rated',
          })
          saveLiveActivityTokens()
          scheduleLiveActivityUpdate(String(parsed.carId))
          res.writeHead(200).end('ok')
        } else if (typeof token === 'string' && /^(?:[0-9a-fA-F]{2}){8,256}$/.test(token)) {
          tokens.add(token); saveTokens()
          if (parsed.preferences && typeof parsed.preferences === 'object') {
            devicePreferences.set(token, parsed.preferences)
            saveDevicePreferences()
          }
          res.writeHead(200).end('ok')
        } else {
          res.writeHead(400).end('bad token')
        }
      } catch { res.writeHead(400).end('bad json') }
    })
  } else if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200).end(JSON.stringify({
      ok: true,
      tokens: tokens.size,
      liveActivityTokens: liveActivityTokens.size,
      preferenceProfiles: devicePreferences.size,
      apnsConfigured,
      mqttConnected: client.connected,
      chargeCostRemindersConfigured: Boolean(cfg.historyURL),
      apnsEnvironment: cfg.production ? 'production' : 'sandbox'
    }))
  } else {
    res.writeHead(404).end()
  }
})
httpServer.listen(cfg.httpPort, () => console.log('HTTP listening on', cfg.httpPort))
