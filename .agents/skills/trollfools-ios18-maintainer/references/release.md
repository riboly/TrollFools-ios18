# Build And Release Workflow

## Before Editing

```powershell
git status --short --branch
git log -5 --oneline
```

Read the code before changing it. Do not overwrite unrelated dirty files.

## Versioning

Use `devkit/bump-version.sh` or update all version sources consistently. Confirm the script preserves:

- display name `TrollFools.L`
- bundle ID `wiki.qaq.TrollFools.L`
- package ID `wiki.qaq.trollfools.l`

Do not bump the app version for documentation-only changes.

## GitHub Actions

The normal CI entry is `.github/workflows/compile.yml`, triggered with `workflow_dispatch`. It uses Xcode 15.4, pinned Theos, rootless packaging, `make package`, and uploads TIPA/DEB/dSYM artifacts.

For network operations in the user's environment, use:

```powershell
$env:HTTP_PROXY='http://192.168.6.110:7892'
$env:HTTPS_PROXY='http://192.168.6.110:7892'
$env:ALL_PROXY='socks5://192.168.6.110:7892'
```

When GitHub CLI authentication is needed, obtain credentials from Git Credential Manager without printing tokens. Never place a token in source, logs, or documentation.

## Artifact Validation

Do not equate a successful workflow with a usable TrollStore Lite package. After downloading artifacts:

1. Run ZIP integrity checks and count entries.
2. Parse `Payload/TrollFools.app/Info.plist` and localized plist strings.
3. Confirm bundle/display/version identifiers.
4. Confirm executable ZIP permissions are `0755`.
5. Parse main executable and `ct_bypass` Mach-O headers and slice counts.
6. Check `LC_CODE_SIGNATURE`, CodeDirectory identifier, and unexpected helper growth.
7. Confirm `Assets.car` changed when the icon was changed.
8. Calculate SHA-256 for final TIPA and DEB.

When `TrollFoolsLoader.dylib` is packaged, also verify that it is executable, contains arm64 and arm64e slices, has install name `@rpath/TrollFoolsLoader.dylib`, contains `__DATA,__interpose`, and is not left as a standalone `/usr/local/lib` or `/var/jb/usr/local/lib` package entry.

Regression tripwire: do not reintroduce CI steps that rebuild and replace `TrollFools/ct_bypass` with a large fat helper. The source helper at the 259 baseline was 204,800 bytes; the signed packaged helper was approximately 213 KB and thin arm64.

## Delivery

Copy final packages into a versioned directory under the output path requested in the current task. Do not persist a machine-specific checkout or artifact path in prompts or source files.

Report:

- final filenames and absolute paths
- SHA-256 values
- source commit and GitHub Actions run URL
- remote push status
- exact validation label

Use these labels literally:

- `STATICALLY VERIFIED`: source/artifact checks passed, no real-device test
- `DEVICE VERIFIED`: exact build and workflow passed on the stated device
- `NOT VERIFIED`: required validation did not run or failed
