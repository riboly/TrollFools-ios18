# Diagnostic Workflow

## Evidence To Collect

Before proposing a fix, collect as many of these as available:

- exact TrollFools.L version and artifact hash
- iOS, jailbreak, TrollStore Lite, and target app versions
- target bundle ID and executable path
- plug-in file, architecture, install name, minimum OS, dependencies, and signature state
- shared injection report (`.txt` and `.json` if available)
- TrollFools application log
- iOS crash or Jetsam report for an immediate launch failure
- whether Dry Run passed, actual injection passed, rollback ran, and the managed plug-in list changed
- whether the same app/dylib works when injected before IPA installation

Never treat a screenshot containing only `SAFE TO INJECT` as sufficient evidence for a launch failure.

## Interpret Dry Run Correctly

Dry Run performs preflight and signing/load-command simulation on temporary copies. It does not copy the plug-in into the installed app, persist it, or add it to the managed plug-in list. Therefore:

- `SAFE TO INJECT` plus an empty plug-in list is expected.
- A Dry Run report must still contain signing simulation results.
- A passing Dry Run does not prove AMFI/dyld launch success on the physical device.

## Failure Layers

### TIPA Does Not Import

Inspect the ZIP, not only the extension:

- `Payload/<name>.app/Info.plist` exists and parses.
- every ZIP entry is readable.
- executable files retain Unix `0755` mode.
- main executable and `ct_bypass` have the expected thin/fat slices.
- helper size has not jumped from roughly 0.2 MB to several MB.
- bundle identifier and CodeDirectory identifier agree.

### Injection Fails Before Signing

Check architecture intersection, encryption state, available header padding, requested load-command size, `__LINKEDIT` bounds, chained fixups/exports trie metadata, dependencies, and target selection strategy.

For an unresolved `@rpath/<leaf>.dylib`, first check same-batch assets, the target App's Frameworks directory, and loader-relative paths. If those do not resolve it, test the canonical `/usr/lib/<leaf>.dylib` with `dlopen_preflight`; iOS shared-cache libraries may not exist as standalone filesystem files. A confirmed system alias requires safe `/usr/lib` rpath insertion into each affected plug-in slice. A failed dyld preflight remains an unresolved third-party dependency and must block injection.

### `ldid` Exits Nonzero

Require the binary path, operation, target, exit code/signal, stdout, and stderr. Confirm the bundled candidate plus `/var/jb/usr/bin/ldid` were attempted in rootless mode. In RootHide mode, first require a `jbroot` symbol owned by loaded `libroothide.dylib` and an executable dynamically mapped `/usr/bin/ldid`. A `RootHide fast-path` report additionally requires successful dynamically mapped `fastPathSign`. A `RootHide trust-cache` report requires mapped `libjailbreak.dylib`, a validated `jbclient_trust_executable_recurse` symbol origin, mapped `/basebin/jbctl`, preserved original entitlements, successful `ldid`, hidden staging copy-back for removable App Store targets, and final CDHash confirmation in `trustcache info`. Never diagnose RootHide using a copied `.jbroot-*` prefix. A zero recursive-trust result is not proof that any CDHash was collected; a generic `return value 1` is a logging defect rather than a root-cause diagnosis.

If a RootHide report falls back to `CoreTrust/ChOma`, inspect the emitted capability lines before changing signing code. Missing `fastPathSign` is expected on Dopamine RootHide 3.0.23; it is only fatal when the validated recursive trust API is also unavailable.

Do not add `jb.pmap_cs.custom_trust` to an injected framework or dylib. RootHide consumes it from the process main executable only. If injection succeeds but every App Store target crashes, compare the final target CDHash with `jbctl trustcache info`; an absent hash indicates the signature was never trusted. Both RootHide trust collectors intentionally skip removable App Store bundles without a container-level TrollStore Lite marker while still being able to return zero, so successful ad-hoc signing and a successful API status are not sufficient.

### Injection Reports Success But App Crashes

Separate these causes with the crash log:

1. AMFI/code-signature rejection
2. malformed `LC_CODE_SIGNATURE`, CodeDirectory, or `__LINKEDIT`
3. dyld missing dependency or wrong install name/rpath
4. wrong architecture or accidental slice removal
5. library validation/entitlement mismatch
6. invalid load-command layout or overwritten mapped bytes
7. plug-in constructor/Objective-C `+load` crash
8. missing substrate compatibility framework
9. minimum OS/platform mismatch
10. app-specific anti-tamper or runtime assumptions

For a `RootHide trust-cache` result, confirm the report includes hidden staging copy-back when needed and the final CDHash verified in the jailbreak trust cache. Dry Run must explicitly say it skipped trust-cache mutation for temporary files; a Dry Run cannot prove that the final App CDHash is currently in the kernel trust cache.

After a full device restart, injected files may still exist while every dynamically uploaded CDHash is absent. Distinguish this from trust-cache allocation stability and from container-path changes. Build 269 restores only TrollFools-managed targets when TrollFools starts; before that restoration runs, an injected App may still exit during dyld initialization. Confirm restoration by comparing the final preferred-architecture CDHash with `jbctl trustcache info` and then launching the target without reinjection.

When a plug-in works after being attached to a decrypted IPA main executable but crashes after TrollFools selects an early framework, compare initializer order. The optional pre-main compatibility mode should report `Loading Mode: Pre-main deferred`, request only `@rpath/TrollFoolsLoader.dylib`, and list the plug-in in `Frameworks/TrollFoolsLoader.plist`. It must remove any direct load command for that deferred plug-in. A crash log is still required to distinguish a remaining hook-engine or app-version incompatibility.

If a faulting thread contains hundreds of consecutive frames with the same plug-in image offset, treat it as recursion even when the termination namespace is `FRONTBOARD` and the code is `0x8BADF00D`. Confirm the image index, repeated offset count, stack-guard address, and the first non-repeated caller. Build 262 protects repeated entries into plug-in-owned UIKit visibility setter hooks after `dlopen`; constructor-time recursion, non-UIKit methods, and arbitrary plug-in logic remain plug-in failures and must stay visible in diagnostics.

Do not label a crash as “iOS 18 incompatibility” without evidence identifying one of these layers.

## Report Integrity

Injection reports should preserve:

- target app, bundle ID/path, executable path, system version, and signing backend
- main and selected target Mach-O architecture, magic, CPU type/subtype, load commands, UUID, platform, and minimum OS
- original/final signature offsets and sizes, CodeDirectory version, CDHash, code-slot validity, XML/DER entitlement state, and CMS presence
- dylib architecture, install name, dependencies, rpaths, Objective-C/Swift metadata
- chained fixups, exports trie, function starts, data-in-code, and `__LINKEDIT`
- added load commands, warnings, errors, backup path, signing result, validation result, and rollback status
- direct versus pre-main deferred loading mode, loader manifest entries, and conversion away from stale direct load commands

Never remove report viewing or sharing while changing the success/failure UI.

## Device Rule

The user persistently authorizes OpenSSH and Frida for this project's diagnosis: process enumeration, attach, spawn, script loading, debug injection, and target-app launch or termination may be used without repeated approval. Changes within ordinary App Store app or TrollFools containers, plug-in files, injection backups, validated RootHide hidden temporary directories, and installation/testing of TrollFools TIPA builds are also allowed. Keep transactional backup, rollback, and exact-path validation.

Never modify system/rootfs, system partition, bootstrap, preboot, launchd, Dopamine, or RootHide core files or boot configuration without new operation-specific authorization. Treat `/System`, `/bin`, `/sbin`, system `/usr`, `/Library`, and `/basebin` as protected. Do not update `jbctl`, clear or rebuild trust caches, install packages into protected paths, restart system services, perform a userspace reboot, or reboot the device. Normal app-scoped trust registration performed by TrollFools and read-only trust-cache inspection remain allowed.
