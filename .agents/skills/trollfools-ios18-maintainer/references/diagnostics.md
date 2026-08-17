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

### `ldid` Exits Nonzero

Require the binary path, operation, target, exit code/signal, stdout, and stderr. Confirm both bundled and `/var/jb/usr/bin/ldid` candidates were attempted in rootless mode. A generic `return value 1` is a logging defect, not a root-cause diagnosis.

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

When a plug-in works after being attached to a decrypted IPA main executable but crashes after TrollFools selects an early framework, compare initializer order. The optional pre-main compatibility mode should report `Loading Mode: Pre-main deferred`, request only `@rpath/TrollFoolsLoader.dylib`, and list the plug-in in `Frameworks/TrollFoolsLoader.plist`. It must remove any direct load command for that deferred plug-in. A crash log is still required to distinguish a remaining hook-engine or app-version incompatibility.

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

Use USB/Frida/SSH only for read-only collection explicitly requested by the user. Do not install anything, replace app files, sign binaries in place, inject a process, or alter the device while diagnosing unless that exact write operation is newly authorized.
