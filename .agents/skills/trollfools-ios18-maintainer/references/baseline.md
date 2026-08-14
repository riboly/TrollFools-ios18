# Project Baseline

## Repository

- Local checkout: `C:\GitHun\TrollFools-ios18`
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
- Dopamine Rootless 3.0.5
- Sileo and Filza
- TrollStore Lite 2.1.1
- Frida 16.3.3 is present, but the device must remain read-only unless the user explicitly permits an operation.

Compatibility priority: this device first, other arm64e iOS 18 devices second, and no regression for iOS 14-17 third.

## Verified Milestones

- Upstream `4.3-253`: imports and installs, but the tested in-place injection did not work.
- `4.3-254`: bad package regression. The generated helper became an approximately 8.44 MB fat arm64+arm64e binary and TrollStore Lite did not react to TIPA import. Do not restore CI code that rebuilds ChOma `ct_bypass` during every workflow.
- `4.3-258`: **DEVICE VERIFIED**. The user confirmed successful injection of the existing `GSPlayerInfo.dylib` on the primary device.
- `4.3-259`: branding and UI release. **STATICALLY VERIFIED** at creation time; injection logic is inherited from the 258 baseline.

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
- Other environments retain the existing CoreTrust/ChOma helper path.
- Preserve original entitlements where the current pipeline does so.
- Validate CodeDirectory code slots after signing and compare original/final slice identity to detect fat-to-thin regressions.

For packaged build 259, `ct_bypass` was a thin arm64 Mach-O with 21 load commands. Its packaged size was 213,376 bytes. The 32-byte growth from build 258 was limited to `__LINKEDIT`/`LC_CODE_SIGNATURE` metadata and the longer `.L` signing identifier.
