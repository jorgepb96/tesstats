# Charging exports

CSV, JSON and GPX charging exports use the same pricing engine as the charging screen.
They export the currently selected sessions and current pricing settings.

Each export includes all available session summary fields: ID, start/end, location,
address, geofence, coordinates, duration, AC/DC, energy added and drawn, efficiency,
battery percentages, range, average power, temperature and odometer.

`cost` is the effective total displayed by the app. The original TeslaMate amount is
preserved separately as `recorded_cost` (CSV) or `recordedCost` (JSON).
The currency and applied effective price per kWh are included. Cost sources are:

- `recorded`: a usable recorded TeslaMate total, following the app's existing precedence.
- `location_override`: the user's price for the location, including explicit free charging.
- `time_of_use`: the selected plan or legacy tariff, time-weighted over the session.
- `default_price`: the configured default price per kWh.

Estimated prices use grid energy including losses when available, otherwise energy
added. Time-of-use estimates assume energy is distributed evenly over the session;
they are not an exact supplier invoice. Exports identify estimates, preserve the
applied tariff bands and pricing time zone, and do not convert currencies.

JSON preserves the original record fields and adds schema version 2 and pricing
metadata. CSV retains its original first 12 columns, adds further detail columns,
and uses quoted fields for embedded commas, quotes and line breaks.

GPX provides map waypoints with readable cost summaries and complete session JSON
in namespaced extensions. Sessions lacking coordinates are preserved in a document
extension rather than plotted at an invented location. Some mapping apps ignore
extensions; CSV/JSON are best for spreadsheet or accounting work. Charge-curve samples
are not part of the session summary export.
