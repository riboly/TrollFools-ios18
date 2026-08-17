---
name: trollfools-ios18-maintainer
description: Maintain, diagnose, build, package, and release the riboly/TrollFools-ios18 fork (TrollFools.L) for TrollStore Lite and Dopamine rootless devices. Use for TrollFools injection failures, Dry Run reports, ldid/code-signing errors, Mach-O or arm64e compatibility, UI feature requests, TIPA installation failures, GitHub Actions builds, release packaging, or regressions against the device-verified 4.3-258 baseline.
---

# TrollFools iOS 18 Maintainer

Treat the checked-out repository and supplied device logs as authoritative. Do not infer behavior from upstream alone.

## Start Every Task

1. Locate the repository from the current working directory, repo-local Skill path, or its `origin` URL. Never rely on a fixed local absolute path.
2. Read `AGENTS.md`, `references/baseline.md`, and the files relevant to the request.
3. Run `scripts/snapshot.ps1` or equivalent read-only checks.
4. Inspect `git status` before editing. Preserve unrelated user changes.
5. Classify the task as UI, injection pipeline, Mach-O, signing, packaging, or device-only diagnosis.

## Non-Negotiable Baseline

- Preserve the injection behavior of version `4.3-258`, confirmed working on the real target device.
- Treat `4.3-259` branding/UI/package as statically verified until installed and tested on the device.
- Treat `4.3-262` as device-verified for the reported DYYY pre-main UIKit setter recursion on the primary device. This verifies the generic guard for that failure class, not every plug-in or crash class.
- Treat `4.3-263` as statically verified until the reported HBWechatHelper and MikotoHelper injections are tested on the primary device.
- Keep Dopamine rootless distinct from RootHide and rootful. Use `/var/jb`; do not introduce `.roothide` or randomized `.jbroot-*` assumptions.
- Treat a connected iPhone as read-only. Do not install packages, alter files, inject processes, restart services, or change settings unless the user explicitly authorizes that exact operation in the current task.
- Do not modify `GSPlayerInfo.dylib` to hide an injector defect.
- Do not disable Mach-O or signature validation to make injection pass.
- Prefer capability detection over an `iOS >= 18` special case.

## Diagnose Before Editing

Read [references/diagnostics.md](references/diagnostics.md). Request or inspect the injection report, application log, crash log, exact TIPA version, target bundle ID, and plug-in metadata. Separate these failure layers:

1. TIPA import or installation
2. preflight/Dry Run
3. load-command modification
4. ldid/CoreTrust signing
5. post-injection validation or rollback
6. AMFI/dyld launch rejection
7. plug-in initialization/runtime crash

Dry Run intentionally modifies temporary copies only. A successful Dry Run must leave the managed plug-in list unchanged.

## Implement Conservatively

- Read the complete call path before changing it.
- Keep edits near existing ownership boundaries: `InjectorV3+Inject.swift`, `InjectorV3+Command.swift`, `InjectorV3+MachO.swift`, `InjectorV3+Backup.swift`, and the relevant SwiftUI view.
- Preserve entitlements, transactional backup, validation, report sharing, and rollback behavior.
- Add focused diagnostics for unknown failures; include executable path, command, backend, exit reason, stdout, and stderr without secrets.
- For constructor or Objective-C `+load` crashes caused by injecting into an early framework, use the optional pre-main deferred loader rather than weakening validation. Preserve direct loading as the default baseline.
- In pre-main mode, keep post-`dlopen` UIKit setter reentrancy guards scoped to implementations owned by the loaded plug-in. Never apply a process-wide setter swizzle or hard-code an app, plug-in, class, or preference key.
- Treat `0x8BADF00D` plus hundreds of identical plug-in frames as recursion/stack exhaustion with a secondary watchdog termination. A watchdog code alone is not proof that `dlopen` was merely slow.
- For `@rpath/<leaf>.dylib`, do not infer a missing system library from filesystem absence. Accept it as a system dyld-cache alias only when `dlopen_preflight` confirms `/usr/lib/<leaf>.dylib`, add `/usr/lib` to the plug-in after validating every slice's header padding, and keep unknown third-party dependencies fatal.
- Keep all user-facing Chinese strings in localization files.
- Update `devkit/bump-version.sh` if a branding or identifier change must survive future version bumps.
- When reusable maintenance knowledge changes, update this repo-local Skill and the maintenance manual, push both with the code, then sync the installed Skill from this directory.

## Validate And Release

Follow [references/release.md](references/release.md). At minimum:

1. Review the diff and run available static checks.
2. Build through `.github/workflows/compile.yml` on GitHub Actions.
3. Download and validate the TIPA and DEB rather than trusting a green workflow alone.
4. Verify plist identity, ZIP readability and permissions, Mach-O slice count, and `ct_bypass` size/architecture.
5. When the deferred loader is present, verify arm64+arm64e slices, `@rpath/TrollFoolsLoader.dylib`, the `__interpose` section, and the packaged reentrancy-guard diagnostic string.
6. Copy final artifacts to the output directory requested in the current task.
7. Commit and push only intended files.
8. Report `STATICALLY VERIFIED`, `DEVICE VERIFIED`, or `NOT VERIFIED` accurately.

## References

- [references/baseline.md](references/baseline.md): device, repository, verified versions, architecture, and source map.
- [references/diagnostics.md](references/diagnostics.md): failure triage and required evidence.
- [references/release.md](references/release.md): GitHub Actions, proxy, packaging, and verification checklist.
- [references/request-template.md](references/request-template.md): reusable Chinese prompts for new sessions.
