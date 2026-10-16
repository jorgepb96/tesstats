# Driver Copilot Bluetooth security

Tesstats uses Tesla Bluetooth Low Energy only as an optional, foreground, read-only telemetry
source for Driver Copilot. The existing iPhone GPS and TeslaMate path remains the automatic
fallback.

## Security boundary

- The app is a Core Bluetooth **central** only. It does not advertise a service, accept inbound
  Bluetooth connections, run a local control server, or declare a Bluetooth background mode.
- The outbound protocol exposes exactly two operations: enroll a key with
  `ROLE_VEHICLE_MONITOR`, and request `DriveState`. Vehicle-control protobuf messages and a
  generic command-sending API are not included in the target.
- Pairing requires approval at the vehicle. A key is not persisted or enabled until Tesstats has
  established an authenticated session and successfully decrypted a `DriveState` response.
- Each vehicle has a separate P-256 key created by Secure Enclave. The private key is
  non-exportable; its opaque reference and VIN are stored in the data-protection Keychain as
  `WhenUnlockedThisDeviceOnly`, without iCloud synchronization. UserDefaults contains only
  SHA-256 vehicle identifiers, enabled state, and profile/car aliases.
- Sessions use P-256 ECDH, authenticated session information, AES-GCM encrypted responses,
  unpredictable request identifiers, per-request counters and response replay rejection.
- BLE discovery matches both Tesla's service UUID and the VIN-derived advertisement name. Frames
  and inboxes are bounded, and unrelated notifications are discarded before protocol parsing.
- The connection is stopped when Driver Copilot closes or the app leaves the foreground.

Deleting a pairing removes the local Secure Enclave/Keychain material and preferences. The app
also tells the user to remove the corresponding public key from the vehicle so the Tesla-side
authorization is revoked as well.

## Supported scope

Initial support is limited to Model 3 and Model Y. Values currently consumed are speed, shift
state, power and odometer. No actuator or vehicle-control operation is implemented.

The wire implementation is pinned to the relevant definitions from Tesla's BSD-3-Clause
`vehicle-command` repository at commit `f97fa1e4bf617a364c72b85cb5d859528abeda67`.
Automated tests pin the enrollment role/form factor, read-only request bytes, VIN discovery name,
decoder behavior, notification filtering, per-vehicle isolation, and fallback priority.

## Release verification

Before distributing this feature, repeat the automated tests and validate pairing, approval,
foreground reconnect, fallback and key deletion on a physical supported Tesla and a physical iPhone.
Secure Enclave and a real vehicle BLE stack cannot be fully exercised by the iOS Simulator.
