# Project Baseline

## Repository

- Local checkout: the current Git repository root; its absolute location may change
- Fork: `https://github.com/riboly/TrollFools-ios18`
- Upstream: `https://github.com/Lessica/TrollFools`
- Primary branch: `main`
- Product name: `TrollFools.L`
- Bundle ID: `wiki.qaq.TrollFools.L`
- Debian package ID: `wiki.qaq.trollfools.l`

Do not assume these values remain current. Confirm them from Git before editing.

## Primary Device

- iPhone XS Max
- Apple A12 Bionic, arm64e-capable hardware
- iOS 18.2.1 build 22C161
- Dopamine RootHide 3.0.23
- Sileo and Filza
- RootHide Manager 1.3.9
- TrollStore Lite 1.0.4
- Frida Server 17.17.0 RootHide build is present, but the device must remain read-only unless the user explicitly permits an operation.

Compatibility priority: this device first, other arm64e iOS 18 devices second, and no regression for iOS 14-17 third.

The device-verified `4.3-258`, `4.3-262`, and `4.3-263` milestones below were established before the device changed environments, on Dopamine Rootless 3.0.5 with TrollStore Lite 2.1.1. Preserve them as regression baselines rather than reclassifying them as RootHide results.

## Verified Milestones

- Upstream `4.3-253`: imports and installs, but the tested in-place injection did not work.
- `4.3-254`: bad package regression. The generated helper became an approximately 8.44 MB fat arm64+arm64e binary and TrollStore Lite did not react to TIPA import. Do not restore CI code that rebuilds ChOma `ct_bypass` during every workflow.
- `4.3-258`: **DEVICE VERIFIED**. The user confirmed successful injection of the existing `GSPlayerInfo.dylib` on the primary device.
- `4.3-259`: branding and UI release. **STATICALLY VERIFIED** at creation time; injection logic is inherited from the 258 baseline.
- `4.3-260`: **DEVICE VERIFIED for the reported WeChat and Telegram plug-ins** on the primary device. The strict-permission and idempotent-validation fixes resolved their injection failures. This does not imply that every plug-in is device-verified.
- `4.3-261`: pre-main compatibility loader for plug-ins that crash during early framework initialization. Superseded by the device-tested Build 262 guard revision; the exact Build 261 package was not separately device-verified.
- `4.3-262`: **DEVICE VERIFIED for the reported DYYY pre-main UIKit setter recursion** on the primary device. Two earlier DYYY crash logs showed 501 repeated `DYYY.dylib` frames and stack exhaustion; after reinjection with Build 262 and Pre-main Compatibility Loading enabled, the user confirmed that the app launched successfully. The implementation is not DYYY-specific, but this result does not verify unrelated selectors, arbitrary plug-in crashes, or every plug-in.
- `4.3-263`: **DEVICE VERIFIED for the reported HBWechatHelper and MikotoHelper plug-ins** on the primary device. System dyld-cache alias detection and plug-in `/usr/lib` rpath normalization fixed their `@rpath/<leaf>.dylib` false missing-dependency failures; the user confirmed that both plug-ins inject successfully and work normally in WeChat. This does not verify arbitrary plug-in dependencies.
- `4.3-264`: **DEVICE FAILED for RootHide injection**. Telegram 12.9.2 build 34474 repeatedly terminated at dyld launch with `Library missing: @rpath/MtProtoKitFramework.framework/MtProtoKitFramework` after the selected framework had been modified and ad-hoc signed. The final main executable still contained `@executable_path/Frameworks`, so the failure exposed the incomplete RootHide signing flow rather than a missing rpath command.
- `4.3-265`: **DEVICE FAILED for Dopamine RootHide capability selection**. The direct-injection report selected `CoreTrust/ChOma` and rejected Telegram's non-4K-aligned CodeDirectory before modification. Read-only device inspection confirmed the mapped `/usr/bin/ldid` exists, while `/basebin/fastPathSign` and `/usr/bin/fastPathSign` do not exist on Dopamine RootHide 3.0.23. TrollStore Lite 1.0.4 instead advertises `jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE` in its helper.
- `4.3-266`: **DEVICE FAILED for Dopamine RootHide runtime trust**. Dry Run and real injection both reported success, but Telegram and another App Store app crashed at launch with different plug-ins and with direct or pre-main deferred loading. Read-only inspection showed the signed Telegram target CDHash was absent from the jailbreak trust cache. Dopamine reads `jb.pmap_cs.custom_trust` only from the process main executable, so adding it to frameworks and dylibs did not trust them.
- `4.3-267`: **DEVICE FAILED for Dopamine RootHide runtime trust**. The recursive API returned zero but RootHide's recursive collector also skipped the modified App Store framework because the app container had no `_TrollStoreLite` marker. The framework CDHash remained absent from the jailbreak trust cache and Telegram crashed at launch.
- `4.3-268`: copies removable-App Mach-Os to the validated hidden temporary root, calls the RootHide recursive trust API there, copies the randomized signed result back transactionally, and validates the final CDHash through dynamically mapped `jbctl trustcache info`. It never creates `_TrollStoreLite`. The exact build is **STATICALLY VERIFIED** until installed. A manual device control confirmed that trusting Telegram's modified `MtProtoKitFramework` CDHash restores a stable launch.

Build 259 artifact source commit: `b604d276408d7ccb2ecaab946d1bf7bde8f576d4`.

## Important Fix Sequence

- `95e0657`: transactional injection diagnostics, Mach-O inspection, preflight, validation, backup, and rollback.
- `4763148`: attempted stable ChOma helper build.
- `b3a35c3`: restored the packaged TrollStore Lite-compatible helper and removed CI helper rebuilding.
- `bf09645`: backup diagnostics and report display.
- `df59e5d`: backup path aliases and report sharing.
- `cf09c6c`: rootless ldid candidate fallback and real Dry Run signing simulation.
- `9bc39e0`: ldid diagnostic logging import fix.
- `b604d27`: TrollFools.L branding, bundle identifier, icon, advertising removal, Dry Run UI, and injection strategy descriptions.
- `990a3e0`: strict imported plug-in permissions and idempotent load-command validation; later device-verified for the reported WeChat and Telegram plug-ins.

## Pre-main Compatibility Loading

Direct loading remains the default and preserves the device-verified injection path. For a plug-in that injects and signs successfully but crashes during a constructor or Objective-C `+load`, the per-app **Pre-main Compatibility Loading** option makes the selected target load only `@rpath/TrollFoolsLoader.dylib`. The loader reads `Frameworks/TrollFoolsLoader.plist` and `dlopen`s the listed plug-ins immediately before `UIApplicationMain`, after load-time framework initializers have completed.

The mode must remain opt-in. Injection, Dry Run, validation, disable/enable, eject, backup, rollback, and direct/deferred conversion must keep the loader and manifest transactional. A device crash log is still authoritative if a plug-in continues to fail.

After each successful `dlopen`, the loader may wrap plug-in-owned implementations of `setHidden:`, `setAlpha:`, and `setUserInteractionEnabled:` on `UIView` subclasses. The wrapper only bypasses a repeated entry by the same plug-in hook for the same object and forwards that recursive call to the superclass setter. It must not become a process-wide swizzle and must not key behavior to a specific app, plug-in, class, or preference.

## Injection Pipeline Map

- `TrollFools/InjectView.swift`: UI request, Dry Run selection, success/failure presentation.
- `TrollFools/InjectorV3.swift`: injector initialization, backend capability selection, temporary paths.
- `TrollFools/InjectorV3+Bundle.swift`: app bundle and injectable target Mach-O enumeration.
- `TrollFools/InjectorV3+Inject.swift`: preflight, transaction, injection, Dry Run simulation, final validation, rollback trigger, report writing.
- `TrollFools/InjectorV3+Command.swift`: insert_dylib/ChOma/ldid/helper command execution and diagnostics.
- `TrollFools/InjectorV3+MachO.swift`: thin/fat Mach-O parsing, arm64/arm64e identification, load-command and CodeDirectory inspection.
- `TrollFools/InjectorV3+Backup.swift`: backup manifest and rollback.
- `TrollFools/SuccessView.swift` and `FailureView.swift`: report viewing and sharing.

The typical dylib path is copied into the target app's `Frameworks` directory. TrollFools inserts `@executable_path/Frameworks` as an rpath and adds an `@rpath/<asset>` load command to a selected unencrypted Mach-O, then signs and validates it.

## Signing Baseline

- Rootless capability is detected from an executable `/var/jb/usr/bin/ldid`.
- Rootless ad-hoc signing tries the bundled `ldid` and then `/var/jb/usr/bin/ldid`, recording exit reason, stdout, and stderr.
- RootHide capability is detected only when the `jbroot` symbol resolves from loaded `libroothide.dylib`, maps `/usr/bin/ldid`, and the mapped result is executable. The random hidden prefix must never be persisted or hard-coded.
- Validated RootHide backends take precedence over the `/var/jb` rootless check because a RootHide shell or process view may expose a `/var/jb` compatibility path. True rootless processes have no validated `libroothide`/`jbroot` capability and still select the rootless backend.
- Bootstrap RootHide signing tries the bundled `ldid` and then the dynamically mapped RootHide `ldid`, followed by dynamically mapped `fastPathSign`; every command records its exit reason, stdout, and stderr.
- Dopamine RootHide trust-cache capability requires dynamically mapped `libjailbreak.dylib`, a `jbclient_trust_executable_recurse` symbol whose image origin matches that library, and dynamically mapped `/basebin/jbctl` for post-call verification. Signing preserves the original entitlement dictionary and runs `ldid`; removable-App files are trusted as hidden staging copies, copied back with an identical CDHash, and then required to appear in the jailbreak trust cache.
- `jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE` is not a framework or dylib signing mechanism. RootHide's process-start hook reads it only from the main executable and changes only the main CodeDirectory trust. Both systemwide and recursive collectors skip removable App Store bundle paths without a container-level TrollStore Lite marker, and both may return zero after collecting no CDHashes.
- Dry Run must not upload temporary CDHashes into the kernel trust cache. It validates the mapped library, symbol origin, signing path, and CodeDirectory locally; real injection performs the trust upload after each successful signature.
- If RootHide capability selection falls back to ChOma, the report must list TrollStore Lite registration, rootless `ldid`, mapped RootHide `ldid`, mapped `fastPathSign`, and recursive trust API status.
- RootHide maps Injector temporary storage, logs, reports, and persistent plug-ins into the hidden root. The update checker uses an ephemeral URLSession without disk cache or persistent cookie storage.
- Other environments retain the existing CoreTrust/ChOma helper path.
- Preserve original entitlements where the current pipeline does so.
- Validate CodeDirectory code slots after signing and compare original/final slice identity to detect fat-to-thin regressions.

For packaged build 259, `ct_bypass` was a thin arm64 Mach-O with 21 load commands. Its packaged size was 213,376 bytes. The 32-byte growth from build 258 was limited to `__LINKEDIT`/`LC_CODE_SIGNATURE` metadata and the longer `.L` signing identifier.
