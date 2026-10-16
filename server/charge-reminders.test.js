import test from 'node:test'
import assert from 'node:assert/strict'
import { inspectCharges, needsLocationPrice } from './charge-reminders.js'
const now = Date.now()
const charge = (id, location = 'New point', cost = null) => ({ charge_id: id,
  address: location, start_date: new Date(now - 3600000).toISOString(),
  end_date: new Date(now - 1000).toISOString(), charge_energy_added: 12, cost })

test('baseline does not notify; new completed unpriced point does, only once', () => {
  const baseline = inspectCharges({}, [charge(1, 'Home')], now)
  assert.equal(baseline.reminders.length, 0)
  const result = inspectCharges(baseline.state, [charge(2), charge(1, 'Home')], now)
  assert.deepEqual(result.reminders, [{ chargeId: 2, location: 'New point' }])
  assert.equal(inspectCharges(result.state, [charge(2), charge(3)], now).reminders.length, 0)
})
test('unfinished, old, paid and unknown locations never notify', () => {
  const charges = [charge(1, 'Paid', 0.01), { ...charge(2), end_date: null },
    { ...charge(3), end_date: new Date(now - 8 * 86400000).toISOString() }, charge(4, '')]
  assert.equal(inspectCharges({ initialized: true }, charges, now).reminders.length, 0)
})
test('free location price and disabled preference suppress delivery', () => {
  assert.equal(needsLocationPrice({ locationPrices: { 'New point': 0 } }, 'New point'), false)
  assert.equal(needsLocationPrice({ chargeCostMissing: false }, 'New point'), false)
  assert.equal(needsLocationPrice({ enabled: false }, 'New point'), false)
  assert.equal(needsLocationPrice({}, 'New point'), true)
})
test('state survives restart and vehicle scopes stay separate', () => {
  const result = inspectCharges({ initialized: true }, [charge(1)], now)
  assert.equal(inspectCharges(JSON.parse(JSON.stringify(result.state)), [charge(1)], now).reminders.length, 0)
  assert.equal(inspectCharges({ initialized: true }, [charge(1)], now).reminders.length, 1)
})
