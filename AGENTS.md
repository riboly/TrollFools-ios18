# TrollFools.L Maintenance Instructions

Read `docs/TrollFools.L维护手册.md` and `.agents/skills/trollfools-ios18-maintainer/SKILL.md` before maintaining this fork. Treat current source and newly supplied logs as authoritative.

## Baseline

- `4.3-258` is device-verified for successful `GSPlayerInfo.dylib` injection on iPhone XS Max/A12, iOS 18.2.1, Dopamine Rootless 3.0.5, and TrollStore Lite 2.1.1.
- `4.3-259` is the TrollFools.L branding/UI build and was statically verified when produced.
- `4.3-262` is device-verified for the reported DYYY pre-main compatibility-loading crash. Its plug-in-owned UIKit setter reentrancy guards are generic for the covered selectors; keep them scoped to the pre-main Loader and do not turn them into process-wide swizzles.
- `4.3-263` is device-verified for successful injection and runtime use of the reported HBWechatHelper and MikotoHelper plug-ins. It recognizes `@rpath/<leaf>.dylib` aliases only when `dlopen_preflight` confirms the canonical `/usr/lib` system library, then adds and validates the plug-in's `/usr/lib` rpath. Do not downgrade genuinely missing third-party dependencies to warnings.
- `4.3-264` proved that a dynamically mapped RootHide `ldid -S` alone is insufficient: Telegram 12.9.2 repeatedly failed at dyld launch after its selected framework was modified.
- `4.3-265` is device-failed for Dopamine RootHide capability selection: Dopamine RootHide 3.0.23 has no runtime `fastPathSign`, so preflight fell back to `CoreTrust/ChOma` and rejected Telegram's non-4K-aligned CodeDirectory without modifying the app.
- `4.3-266` is device-failed for Dopamine RootHide runtime trust. Injection and validation succeeded, but Telegram and another App Store app crashed at launch with multiple plug-ins and both loading modes. The modified framework CDHash was absent from the jailbreak trust cache; `jb.pmap_cs.custom_trust` is consumed only from a process main executable and cannot trust an injected framework.
- `4.3-267` replaces that incorrect entitlement flow with the validated RootHide `libjailbreak` recursive trust API after ad-hoc signing. Treat it as statically verified until installed and tested.
- Do not reintroduce CI rebuilding/replacement of `TrollFools/ct_bypass`; this caused the unusable 4.3-254 TIPA regression.
- Preserve iOS 14-17 behavior while prioritizing the stated iOS 18 RootHide and rootless environments.

## Guardrails

- Distinguish Dopamine rootless (`/var/jb`) from RootHide and rootful environments. Check validated RootHide capabilities before `/var/jb` because a RootHide process view may expose that compatibility path. Never hard-code `.roothide` or randomized `.jbroot-*` paths; resolve RootHide paths through a validated `jbroot` export from the loaded `libroothide.dylib` and then verify whether the environment provides Bootstrap `fastPathSign` or the RootHide `libjailbreak` recursive trust API.
- Do not use `jb.pmap_cs.custom_trust` as a framework or dylib signing mechanism. RootHide reads that entitlement from the process main executable only. App Store bundle paths without a TrollStore Lite marker are intentionally skipped by the systemwide trust-file path, so in-place injection must call the validated `jbclient_trust_executable_recurse` API for each newly signed Mach-O.
- Treat any connected iPhone as read-only. Do not install, alter files, inject processes, restart services, or change settings without explicit authorization for that exact operation.
- Diagnose from injection reports, application logs, and crash logs before editing.
- Treat `0x8BADF00D` plus hundreds of identical plug-in frames as recursion/stack exhaustion before assuming a slow launch.
- Do not use filesystem existence alone for `/usr/lib` dependencies because iOS system dylibs may exist only in the dyld shared cache. Confirm them through dyld capability checks and keep unresolved third-party dependencies fatal.
- Do not modify test dylibs, disable signing/Mach-O validation, swallow failures, or hard-code a target app.
- Preserve entitlements, backup, validation, report sharing, and rollback.
- Prefer capability detection and minimal changes.

## Delivery

- Build application changes through `.github/workflows/compile.yml`.
- Validate TIPA ZIP integrity, plist identity, executable permissions, Mach-O slices, signatures, `ct_bypass` size/architecture, and packaged RootHide recursive-trust diagnostics after every build.
- Use the LAN proxy documented in the maintenance manual for network operations.
- Push intended changes to `origin` and copy final artifacts to the output directory requested in the current task. Never assume a fixed local checkout or artifact path.
- When a code change adds reusable maintenance or diagnostic knowledge, update the maintenance manual and repo-local Skill in the same delivery, push those files to GitHub, and sync the installed Skill from the repo-local source before final verification.
- Report only `STATICALLY VERIFIED`, `DEVICE VERIFIED`, or `NOT VERIFIED` according to actual evidence.
