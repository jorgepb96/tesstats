// Pure state transition; persisted by the bridge, independently for every vehicle.
export function inspectCharges(state = {}, charges, now = Date.now()) {
  const seen = new Set(state.seen || [])
  const locations = new Set(state.locations || [])
  const reminders = []
  for (const charge of [...charges].sort((a, b) => Date.parse(a.start_date) - Date.parse(b.start_date))) {
    const end = Date.parse(charge.end_date)
    const location = (charge.geofence || charge.address || '').trim()
    if (!Number.isInteger(charge.charge_id) || !Number.isFinite(end) || !location) continue
    const fresh = !seen.has(charge.charge_id)
    const newLocation = !locations.has(location.toLowerCase())
    seen.add(charge.charge_id)
    locations.add(location.toLowerCase())
    if (state.initialized && fresh && newLocation && end <= now && now - end < 7 * 86400000 &&
        Number(charge.charge_energy_added) > 0 && !(Number(charge.cost) > 0)) {
      reminders.push({ chargeId: charge.charge_id, location })
    }
  }
  return { state: { initialized: true, seen: [...seen], locations: [...locations] }, reminders }
}

export function needsLocationPrice(preferences, location) {
  if (preferences?.enabled === false || preferences?.chargeCostMissing === false) return false
  return !Object.keys(preferences?.locationPrices || {}).some(key =>
    key.trim().toLowerCase() === location.toLowerCase())
}
