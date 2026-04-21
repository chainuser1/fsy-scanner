Setup notes and installation failures

- Date: 2026-04-21

What I tried:

1) Install thermal printer package (per plan):
   npm --prefix ./fsy-scanner install react-native-thermal-receipt-printer-image-qr@^1.2.0
   Result: npm returned ETARGET: "No matching version found for react-native-thermal-receipt-printer-image-qr@^1.2.0".

2) Install other npm packages:
   npm --prefix ./fsy-scanner install zustand@^4.5.0 date-fns@^3.6.0 @react-native-async-storage/async-storage@^1.23.0 --save
   Result: npm network error ECONNRESET. See npm log:
   /home/lotus_clan/.npm/_logs/2026-04-21T08_24_48_720Z-debug-0.log

Notes for developers:
- The thermal printer package version specified in the plan may not exist on npm; consider specifying a known-good version or an alternative library.
- The other package install failed due to a network error (ECONNRESET). Retry network install when connectivity is stable.
- Commands to retry locally:

```bash
npm --prefix ./fsy-scanner install zustand@^4.5.0 date-fns@^3.6.0 @react-native-async-storage/async-storage@^1.23.0 --save
npm --prefix ./fsy-scanner install react-native-thermal-receipt-printer-image-qr@^1.2.0
```

If issues persist, run `npm cache verify` and check proxy/network settings.

---

## Retry attempt — 2026-04-21 08:30 UTC

What I retried:

- Verified npm cache with `npm cache verify`.
- Installed npm packages: `zustand@^4.5.0`, `date-fns@^3.6.0`, `@react-native-async-storage/async-storage@^1.23.0`.

Result:

- The three non-Expo packages installed successfully (npm added 11 packages and updated project dependencies). See the local npm install log for details.
- The thermal printer package from the plan (`react-native-thermal-receipt-printer-image-qr@^1.2.0`) still has no matching version on npm. Available versions on npm are in the `0.1.x` range (latest seen: `0.1.12`). The plan specifies `^1.2.0` which does not exist; do not silently substitute — the plan should be updated to reference a valid package/version or an approved alternative.

Commands run:

```bash
npm --prefix ./fsy-scanner cache verify
npm --prefix ./fsy-scanner install zustand@^4.5.0 date-fns@^3.6.0 @react-native-async-storage/async-storage@^1.23.0 --save
npm --prefix ./fsy-scanner view react-native-thermal-receipt-printer-image-qr versions --json
```

Next steps for developers:

- Update `FSY_SCANNER_PLAN.md` with an available thermal-printer package/version, or approve using the `0.1.12` series from npm.
- If further installs fail, check network/proxy and run the above commands locally.

