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
