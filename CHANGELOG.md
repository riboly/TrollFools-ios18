# Changelog

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
