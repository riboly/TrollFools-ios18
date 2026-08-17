# Changelog

## 4.3 Build 263 (2026-08-17)

修复插件把 iOS 系统 dylib 写成 `@rpath/<名称>` 时，被依赖预检误判为缺少第三方库而拒绝注入的问题。

### 修复与优化

- dyld cache 能力检测：仅当 `dlopen_preflight("/usr/lib/<名称>")` 确认当前 iOS 可解析该系统库时，才将对应 `@rpath` 依赖视为系统库，不使用易过期的插件/App 白名单。
- 安全 rpath 规范化：检查插件每个 Mach-O slice 的 header padding 后补入 `/usr/lib` rpath，使 dyld 能在运行时解析系统库别名；真正缺失的第三方 dylib 仍会阻止注入。
- Dry Run 一致性：Dry Run 临时副本执行与真实注入相同的系统 rpath 和 Substrate load-command 规范化，再重新签名及验证。
- 注入后验证：复制后的插件必须在所有相关 slice 中保留 `/usr/lib` rpath 和有效 CodeDirectory，否则事务回滚。
- 覆盖报告：修复 `HBWechatHelper.dylib` 的 `libiconv/libbz2/libz/libobjc/libc++/libSystem` 误报，以及 `MikotoHelper.dylib` 的 `libobjc/libc++/libSystem/libsqlite3` 误报。
- 真机验证：用户确认 Build 263 在主设备上可成功注入 `HBWechatHelper.dylib` 和 `MikotoHelper.dylib`，两个插件均可在微信正常使用。

------

## 4.3 Build 263 (2026-08-17) [EN]

Fixed dependency preflight rejecting plug-ins whose iOS system dylibs use `@rpath/<name>` aliases.

### Fixed and improved

- Dyld-cache capability detection: An `@rpath` dependency is treated as a system dylib only when `dlopen_preflight("/usr/lib/<name>")` confirms that the current iOS can resolve it. No app or plug-in allowlist is used.
- Safe rpath normalization: After checking every plug-in Mach-O slice for usable header padding, injection adds `/usr/lib` as an rpath so dyld can resolve verified system aliases. Missing third-party dylibs remain fatal.
- Dry Run parity: Temporary Dry Run copies receive the same system-rpath and Substrate load-command normalization before re-signing and validation.
- Post-injection validation: Every relevant copied plug-in slice must retain the `/usr/lib` rpath and a valid CodeDirectory, otherwise the transaction rolls back.
- Report coverage: Fixes false missing-dependency results for the system libraries reported by `HBWechatHelper.dylib` and `MikotoHelper.dylib`.
- Device validation: The user confirmed that Build 263 successfully injects both `HBWechatHelper.dylib` and `MikotoHelper.dylib` on the primary device and that both plug-ins work normally in WeChat.

------

## 4.3 Build 262 (2026-08-17)

修复兼容加载成功后，部分插件的 UIKit setter hook 因对同一对象重复发送相同 setter 而递归至栈溢出的问题。

### 修复与优化

- 通用重入保护：启动前兼容 Loader 在每个插件加载后扫描该插件实现的 `setHidden:`、`setAlpha:`、`setUserInteractionEnabled:` hook；同一 hook 对同一对象递归进入时绕过重复插件调用并落到父类 UIKit setter。
- 作用域隔离：保护仅在用户主动开启“启动前兼容加载”时生效，不改变默认直载模式，也不绑定目标 App、插件名称或某个设置键。
- 崩溃诊断：确认 `0x8BADF00D` 可能是栈溢出先耗尽启动时间后的次生 watchdog；应同时检查重复插件帧，不能只按启动超时处理。
- 发布校验：CI 确认打包 Loader 包含重入保护诊断字符串。
- 真机验证：用户在 iPhone XS Max / iOS 18.2.1 上重新注入 DYYY 并开启启动前兼容加载后确认抖音成功启动；该结果验证的是已覆盖 UIKit setter 的同类递归保护，不代表所有插件崩溃类型。

------

## 4.3 Build 262 (2026-08-17) [EN]

Fixed stack exhaustion after compatibility loading when a plug-in's UIKit setter hook sends the same setter to the same object recursively.

### Fixed and improved

- Generic reentrancy guards: After loading each plug-in, the pre-main loader scans plug-in-owned `setHidden:`, `setAlpha:`, and `setUserInteractionEnabled:` hooks. A recursive entry into the same hook for the same object bypasses the repeated plug-in call and reaches the superclass UIKit setter.
- Isolated scope: Guards are active only in the opt-in pre-main compatibility mode. Direct loading remains unchanged, and no app name, plug-in name, or preference key is hard-coded.
- Crash diagnosis: `0x8BADF00D` can be secondary to stack recursion consuming the launch allowance; repeated plug-in frames must be checked before treating the report as a simple launch timeout.
- Release validation: CI verifies that the packaged loader contains the reentrancy-guard diagnostic string.
- Device validation: The user confirmed that Douyin launched successfully after reinjecting DYYY with pre-main compatibility loading on the iPhone XS Max / iOS 18.2.1 test device. This validates the covered UIKit setter recursion class, not every possible plug-in crash.

------

## 4.3 Build 261 (2026-08-17)

修复部分插件注入和签名均成功、但因目标 framework 初始化顺序过早而导致 App 启动闪退的问题。

### 新增

- 启动前兼容加载：新增按 App 独立保存的可选模式。目标 Mach-O 只加载 `TrollFoolsLoader.dylib`，Loader 在 load-time framework 初始化完成后、`UIApplicationMain` 前按清单加载插件。
- CLI：`inject` 命令新增 `--deferred` 参数。
- 注入报告：新增 `Loading Mode`，区分 `Direct` 与 `Pre-main deferred`。

### 修复与优化

- 模式转换：重新注入时可在直载和延迟加载之间安全转换，并清理旧插件 load command。
- 插件管理：停用、启用、卸载及全部移除均同步维护 Loader 清单；最后一个延迟插件移除后清理 Loader。
- 事务保障：Loader 与清单纳入 Dry Run、签名验证、备份和回滚。
- 发布验证：GitHub Actions 校验 Loader 的 arm64/arm64e slices、install name、`__interpose` section 及 DEB 独立库残留。
- 调试符号：按架构合并同名 dSYM，避免 artifact 汇总时覆盖 arm64e 调试符号，并校验 Loader/Tweak dSYM 的双架构完整性。

------

## 4.3 Build 261 (2026-08-17) [EN]

Fixed launch crashes caused by some successfully injected and signed plug-ins initializing before the target app's frameworks were ready.

### Added

- Pre-main compatibility loading: Added an opt-in per-app mode. The target Mach-O loads only `TrollFoolsLoader.dylib`, which loads manifest plug-ins after load-time framework initialization and before `UIApplicationMain`.
- CLI: Added `--deferred` to the `inject` command.
- Injection report: Added `Loading Mode` to distinguish `Direct` and `Pre-main deferred`.

### Fixed and improved

- Mode conversion: Re-injection can safely move a plug-in between direct and deferred loading while removing stale load commands.
- Plug-in management: Disable, enable, eject, and remove-all flows keep the loader manifest synchronized and remove the loader after the final deferred plug-in.
- Transaction safety: Included the loader and manifest in Dry Run, signing validation, backup, and rollback.
- Release validation: GitHub Actions checks loader arm64/arm64e slices, install name, `__interpose` section, and standalone DEB library residue.
- Debug symbols: Merge same-name dSYMs by architecture so artifact collection cannot overwrite arm64e symbols, and validate dual-architecture Loader/Tweak dSYMs.

------

## 4.3 Build 260 (2026-08-17)

修复部分插件因源文件权限过严，在完成复制和签名后无法由 TrollFools 验证、导致注入事务回滚的问题。

### 修复

- 插件权限：导入后、改属主前补齐 Mach-O 的读取/执行权限及包目录的遍历权限，兼容 `0600` 等严格权限的 dylib/framework。
- 幂等注入：仅在本次确实新增或规范化 load command/rpath 时要求 CDHash 变化；已有相同命令时仍完整验证 CodeDirectory、架构和依赖，不再误判签名失败。
- 注入报告：去重事务错误，并将 load command 状态从“已添加”改为“已请求”，避免重复或误导信息。
- 版本工具：build number 改为基于当前版本顺序递增，避免文档提交导致版本号跳跃。

------

## 4.3 Build 260 (2026-08-17) [EN]

Fixed injection rollback when strict source permissions prevented TrollFools from validating a plug-in after copying and signing it.

### Fixed

- Plug-in permissions: Ensure imported Mach-Os are readable/executable and bundle directories are traversable before ownership changes, including dylibs/frameworks imported with modes such as `0600`.
- Idempotent injection: Require a changed CDHash only when this run adds or normalizes a load command/rpath; existing commands still receive full CodeDirectory, architecture, and dependency validation.
- Injection reports: De-duplicate transaction errors and report load commands as requested instead of always claiming they were added.
- Version tooling: Increment the current build number sequentially instead of deriving it from the repository commit count.

------

## 4.3 Build 253 (2026-04-23)

修复与 MachOKit 有关的一处断言崩溃。

------

## 4.3 Build 253 (2026-04-23) [EN]

Fixed an assertion crash related to MachOKit.

------

## 4.3 Build 246 (2026-04-16)

修复二次注入时可能误选已注入动态库作为目标 Mach-O 的问题。

### 修复

- 注入目标选取：修复追加注入时，上次注入的动态库可能被误选为注入目标的问题。  
  新增三层防御：从注入前备份读取原始 Load Commands 以还原真实依赖链；枚举阶段跳过 `.troll-fools.bak` 备份文件；通过备份差分精确识别并排除已注入的动态库。

------

## 4.3 Build 246 (2026-04-16) [EN]

Fixed an issue where re-injection could incorrectly select a previously-injected dylib as the target Mach-O.

### Fixed

- Target selection: Fixed re-injection potentially picking a previously-injected dylib as the injection target.  
  Added three-layer defense: read original load commands from pre-injection backup to restore the true dependency chain; skip `.troll-fools.bak` backup files during enumeration; use backup-diff to precisely identify and exclude previously-injected dylibs.

------

## 4.3 (2026-04-13)

本次版本聚焦于“动态加载框架兼容性”和“页面说明可理解性”，并包含插件管理流程调整与资源清理。

### 修复

- 注入兼容性：修复部分 Unity/运行时 `dlopen` 场景下无法命中可注入目标的问题。  
  当主程序静态链接交集为空时，改为回退扫描 `Frameworks/` 中可用 Mach-O（含一级目录下 `.dylib`）。
- 插件管理：调整“移除插件”流程，区分已启用与已禁用插件：  
  已启用插件执行卸载；已禁用插件执行标记清理，降低批量处理风险。

### 新增

- 高级选项：新增“启用兼容模式回退”开关（默认开启），可控制是否在无静态链接命中时启用回退候选。
- 结果页提示：当本次注入通过兼容模式完成时，在“已完成”下方显示额外提示。

### 优化

- 候选筛选：回退候选新增过滤，排除 `libswift*` 与已忽略注入相关动态库/框架，并统一大小写处理。
- 诊断日志：增强 Mach-O 扫描日志，输出候选数量、文件大小、加密/不可读统计与最终选择结果，便于定位“无可用目标”问题。
- 设置说明：优化高级选项页面结构与说明文案，减少非技术用户理解成本。
- 广告与资源：移除内置广告位 `Letterpress` 及相关本地化词条/图标资源；更新营销图素材。

### 本地化

- 更新 `en/zh-Hans/it/vi` 词条，补充兼容模式与设置说明相关文案，并清理移除条目对应文案。

------

## 4.3 (2026-04-13) [EN]

This release focuses on dynamic-framework injection compatibility and clearer user guidance, plus plugin-management flow adjustments and resource cleanup.

### Fixed

- Injection compatibility: Fixed cases (notably Unity/runtime `dlopen` flows) where no injectable target could be selected.  
  When the static-link intersection is empty, TrollFools now falls back to scanning eligible Mach-O files under `Frameworks/` (including top-level `.dylib`).
- Plugin management: Updated plugin removal flow to handle enabled vs disabled plugins separately:  
  enabled plugins are ejected, while disabled plugins are cleaned via desist/marker path handling.

### Added

- Advanced Settings: Added **Enable Compatibility Fallback** (default ON) to control fallback candidate behavior when no static-link match is found.
- Result-page notice: Added a subtitle under **Completed** when injection succeeds through compatibility fallback.

### Improved

- Candidate filtering: Fallback candidates now exclude `libswift*` and ignored injection-related dylib/framework names, with consistent case-insensitive handling.
- Diagnostics: Expanded Mach-O scan logs with candidate counts, file sizes, encrypted/unreadable stats, and final target selection.
- Settings clarity: Refined Advanced Settings layout and explanatory copy for better non-technical readability.
- Ads/assets: Removed built-in `Letterpress` ad entry and related localization/icon assets; refreshed marketing artwork.

### Localization

- Updated `en/zh-Hans/it/vi` strings for compatibility-fallback and settings guidance, and removed strings for deleted entries.
