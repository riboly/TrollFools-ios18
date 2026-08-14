# TrollFools.L Maintenance Instructions

Read `docs/TrollFools.L维护手册.md` and `.agents/skills/trollfools-ios18-maintainer/SKILL.md` before maintaining this fork. Treat current source and newly supplied logs as authoritative.

## Baseline

- `4.3-258` is device-verified for successful `GSPlayerInfo.dylib` injection on iPhone XS Max/A12, iOS 18.2.1, Dopamine Rootless 3.0.5, and TrollStore Lite 2.1.1.
- `4.3-259` is the TrollFools.L branding/UI build and was statically verified when produced.
- Do not reintroduce CI rebuilding/replacement of `TrollFools/ct_bypass`; this caused the unusable 4.3-254 TIPA regression.
- Preserve iOS 14-17 behavior while prioritizing the stated iOS 18 rootless environment.

## Guardrails

- Distinguish Dopamine rootless (`/var/jb`) from RootHide and rootful environments. Do not add `.roothide` or randomized `.jbroot-*` paths.
- Treat any connected iPhone as read-only. Do not install, alter files, inject processes, restart services, or change settings without explicit authorization for that exact operation.
- Diagnose from injection reports, application logs, and crash logs before editing.
- Do not modify test dylibs, disable signing/Mach-O validation, swallow failures, or hard-code a target app.
- Preserve entitlements, backup, validation, report sharing, and rollback.
- Prefer capability detection and minimal changes.

## Delivery

- Build application changes through `.github/workflows/compile.yml`.
- Validate TIPA ZIP integrity, plist identity, executable permissions, Mach-O slices, signatures, and `ct_bypass` size/architecture after every build.
- Use the LAN proxy documented in the maintenance manual for network operations.
- Push intended changes to `origin` and copy final artifacts to the output directory requested in the current task. Never assume a fixed local checkout or artifact path.
- Report only `STATICALLY VERIFIED`, `DEVICE VERIFIED`, or `NOT VERIFIED` according to actual evidence.
