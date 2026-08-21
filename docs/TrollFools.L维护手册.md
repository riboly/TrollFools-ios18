# TrollFools.L Fork 维护手册

这份文档用于把当前 fork 的设备环境、已验证基线、开发约束和发布流程交给新的 AI 会话或其他 AI 工具。代码和新日志始终优先于本文档；本文档用于避免重新猜测已经确认过的问题。

## 1. 入口信息

- 本地仓库：当前包含 `.git`、`AGENTS.md`、`TrollFools/` 的仓库根目录；不要依赖固定盘符或绝对路径
- Fork：<https://github.com/riboly/TrollFools-ios18>
- 上游：<https://github.com/Lessica/TrollFools>
- 主分支：`main`
- App 名称：`TrollFools.L`
- Bundle ID：`wiki.qaq.TrollFools.L`
- Debian 包 ID：`wiki.qaq.trollfools.l`
- Repo-local AI Skill：`.agents/skills/trollfools-ios18-maintainer`

## 2. 实际设备

- iPhone XS Max，Apple A12 Bionic，arm64e 设备
- iOS 18.2.1（22C161）
- Dopamine RootHide 3.0.23
- TrollStore Lite 1.0.4
- 已安装 Sileo、Filza、RootHide Manager 1.3.9、Frida Server 17.17.0（RootHide build）

当前设备已从 Dopamine Rootless 切换到 Dopamine RootHide。`4.3-258`、`4.3-262`、`4.3-263` 的既有真机结论来自切换前的 Dopamine Rootless 3.0.5 / TrollStore Lite 2.1.1 环境，仍是必须保留的回归基线。

RootHide 进程会加载 `libroothide.dylib` 并提供 `jbroot` 路径映射；其隐藏根前缀每次环境都可能变化。代码不得写死 `.roothide`、`.jbroot-*` 或本机当前前缀，只能验证 `jbroot` 符号来自已加载的 `libroothide.dylib`，调用它映射工具路径，再检查映射结果是否真的可执行。普通 Rootless 继续使用 `/var/jb` 能力检测。

部分 RootHide shell 或进程视图也会暴露 `/var/jb` 兼容路径，因此后端选择必须先检查经过验证的 `libroothide`/`jbroot` RootHide 能力，再检查普通 rootless `/var/jb/usr/bin/ldid`。真正的 rootless 环境没有已验证的 `jbroot` 符号，不会被误分流。

手机默认只读。AI 可以在用户明确同意时读取日志或设备信息，但禁止安装软件、修改文件、注入进程、重启服务或改变设置，除非当前任务单独明确授权了对应操作。

## 3. 已验证基线

- `4.3-253`：TIPA 能导入安装，但本次目标注入不可用。
- `4.3-254`：出现打包回归，`ct_bypass` 被 CI 替换为约 8.44 MB 的 arm64+arm64e fat helper，TrollStore Lite 点击 TIPA 无反应。
- `4.3-258`：**DEVICE VERIFIED**。用户已在上述真实设备确认 `GSPlayerInfo.dylib` 注入成功。
- `4.3-259`：完成 TrollFools.L 品牌、图标、Bundle ID、广告移除、Dry Run UI 和策略说明；创建时为 **STATICALLY VERIFIED**。
- `4.3-260`：**DEVICE VERIFIED（微信与 Telegram 报告场景）**。严格插件权限和幂等 load-command 验证修复已在真机确认。
- `4.3-261`：加入启动前兼容 Loader；其精确安装包未单独完成真机验证，后续由 262 的保护版本取代。
- `4.3-262`：**DEVICE VERIFIED（DYYY 启动前兼容加载及 UIKit setter 递归场景）**。用户在主设备重新注入并开启兼容加载后确认抖音成功启动。保护实现不绑定 DYYY，但本次结果不代表任意插件、任意 selector 或所有崩溃类型均已验证。
- `4.3-263`：**DEVICE VERIFIED（HBWechatHelper 与 MikotoHelper 报告场景）**。识别经 dyld 确认的 `@rpath/<系统 dylib>`，为插件安全补入 `/usr/lib` rpath，并保持真实第三方依赖缺失为阻断错误。用户已在主设备确认两个插件均能成功注入微信并正常使用；这不代表任意插件依赖均已验证。
- `4.3-264`：**DEVICE FAILED（RootHide / Telegram 12.9.2 / Lead1.44）**。本版加入 RootHide 路径与存储兼容，但签名流程只有动态映射的 `ldid -S`，没有建立 Dopamine RootHide 要求的 custom-trust 信任级别。Telegram 连续在 dyld 启动阶段报告 `Library missing: @rpath/MtProtoKitFramework.framework/MtProtoKitFramework`；下载核对的最终主程序仍含 `@executable_path/Frameworks`，证明不是简单遗漏 rpath。
- `4.3-265`：**DEVICE FAILED（Dopamine RootHide 后端选择）**。本版加入 Bootstrap RootHide 的 `ldid` + `fastPathSign` 流程，但真机 Dopamine RootHide 3.0.23 并不存在 `/basebin/fastPathSign` 或 `/usr/bin/fastPathSign`，导致报告回退到 `CoreTrust/ChOma`，并在修改 Telegram 前因非 4K 对齐 CodeDirectory 被预检阻断。只读检查确认动态映射的 `/usr/bin/ldid` 正常，TrollStore Lite 1.0.4 实际使用 `jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE`。
- `4.3-266`：**DEVICE FAILED（Dopamine RootHide 运行时信任）**。Dry Run 与正式注入均报告成功，但 Telegram 和另一个 App Store App 在不同插件、直接加载和启动前兼容加载下都会闪退。只读检查确认 Telegram 最终目标 CDHash 不在 jailbreak trust cache 中；`jb.pmap_cs.custom_trust` 只从进程主程序读取，写进 framework/dylib 不能信任它们。
- `4.3-267`：新增 `RootHide trust-cache` 后端。动态映射 `libjailbreak.dylib`，验证 `jbclient_trust_executable_recurse` 符号确实来自该镜像，保留 entitlements 并用 `ldid` 签名后，通过 RootHide 专用递归信任域上传每个修改后 Mach-O 的 CDHash。Dry Run 只验证能力和临时副本签名，不写入内核 trust cache。精确构建尚未安装测试，标记 **STATICALLY VERIFIED**。

后续修改不得破坏 `4.3-258` 已验证的注入链路。不要恢复 GitHub Actions 中现场编译并替换 ChOma `ct_bypass` 的步骤。

## 4. 当前关键功能

- 注入前 Mach-O/插件兼容性预检
- arm64/arm64e 和 fat/thin slice 分析
- load commands、header padding、`__LINKEDIT`、CodeDirectory code slots 检查
- `LC_DYLD_CHAINED_FIXUPS`、`LC_DYLD_EXPORTS_TRIE`、`LC_CODE_SIGNATURE` 等状态记录
- 注入前事务备份
- 失败自动 rollback
- 注入后重新解析、签名和 load-command 验证
- TXT/JSON injection report 及查看/分享入口
- `注入调试(Dry Run)`：只在临时副本执行修改和签名模拟，不改变已安装 App，所以下一次启动恢复关闭且插件列表保持为空
- Rootless ad-hoc 签名：尝试内置 `ldid` 和 `/var/jb/usr/bin/ldid`，记录完整退出原因/stdout/stderr
- RootHide fast-path 签名：用于实际提供该工具的 Bootstrap 环境；验证 `jbroot` 来自已加载的 `libroothide.dylib`，动态映射并验证 `/usr/bin/ldid` 与 `fastPathSign`，先执行 `ldid` 再执行 fast-path 签名
- Dopamine RootHide trust-cache 签名：验证映射后的 `/usr/bin/ldid` 与 `/usr/lib/libjailbreak.dylib`，校验 `jbclient_trust_executable_recurse` 的镜像来源；结构化保留原 entitlements，执行 `ldid` 后通过 RootHide 专用递归信任域上传 CDHash。候选路径只用于当前能力与诊断，不保存随机隐藏前缀
- RootHide 存储隔离：Injector Caches、日志、报告和持久插件目录动态映射到隐藏根；更新检查不使用共享 URLSession 的磁盘缓存或 Cookie 存储
- 启动前兼容加载：目标 framework 仅加载 `TrollFoolsLoader.dylib`，由 loader 在所有 framework 初始化完成后、`UIApplicationMain` 前按 `TrollFoolsLoader.plist` 清单加载插件；用于“注入成功但插件构造阶段闪退”的场景
- 兼容加载重入保护：插件 `dlopen` 完成后，仅包装该插件在 `UIView` 子类上实现的 `setHidden:`、`setAlpha:`、`setUserInteractionEnabled:` hook；同一 hook 对同一对象递归时转发到父类 setter，避免插件内部重复 setter 导致栈溢出
- 系统 dylib 别名兼容：当插件依赖为 `@rpath/<leaf>.dylib` 时，用 `dlopen_preflight` 检查 `/usr/lib/<leaf>.dylib` 是否由当前 iOS/dyld cache 提供；确认后检查插件 header padding 并补 `/usr/lib` rpath，Dry Run 与真实注入执行同一规范化

## 5. 关键代码位置

- `InjectView.swift`：注入请求、Dry Run 分支、成功/失败界面
- `SettingsView.swift`：注入策略与 Dry Run UI
- `InjectorV3.swift`：初始化、能力和签名后端检测、临时路径
- `InjectorV3+Bundle.swift`：目标 App/Mach-O 枚举与策略
- `InjectorV3+Inject.swift`：preflight、注入事务、Dry Run、签名、验证、rollback、报告
- `InjectorV3+Command.swift`：insert_dylib、ChOma、ldid、ct_bypass 和命令日志
- `InjectorV3+MachO.swift`：Mach-O、CodeDirectory、CDHash、架构和 load-command 解析
- `InjectorV3+Backup.swift`：备份和恢复
- `SuccessView.swift` / `FailureView.swift`：报告查看与分享
- `.github/workflows/compile.yml`：日常 GitHub Actions 构建
- `devkit/bump-version.sh`：版本号和 TrollFools.L 品牌持久化

## 6. 出现 Bug 时必须提供什么

至少提供：

```text
TrollFools.L 版本：
iOS / Dopamine / TrollStore Lite 版本：
目标 App 和 Bundle ID：
插件名称：
关闭注入调试的结果：
开启注入调试的结果：
injection report 路径：
TrollFools App 日志路径：
iOS crash/Jetsam 日志路径：
最后一个正常版本：
```

必须区分：TIPA 导入失败、预检失败、Mach-O 修改失败、ldid/签名失败、验证/回滚失败、AMFI/dyld 启动拒绝、插件初始化崩溃。不能把所有问题直接归因于“iOS 18 不支持”。

RootHide 下如果报告仍显示 `CoreTrust/ChOma`，先读取报告中的能力诊断：TrollStore Lite 注册、rootless `ldid`、RootHide `ldid` 映射、`fastPathSign` 映射和 recursive trust API 状态。Dopamine RootHide 3.0.23 缺少 `fastPathSign` 属于已知环境差异，只要递归信任 API 可用就应选择 `RootHide trust-cache`。不得把当前设备的 `.jbroot-*` 实际值复制进源码。

`jb.pmap_cs.custom_trust=PMAP_CS_APP_STORE` 不是 framework/dylib 的签名方案。RootHide 只在进程启动时从主程序 entitlement 读取它，并只修改主 CodeDirectory 的 trust。systemwide trust-file 路径还会主动跳过没有 TrollStore Lite marker 的 App Store bundle，因此“`ldid` 成功、CodeDirectory 有效”不能证明修改后的 framework 已可加载。正式注入必须对每个新签名 Mach-O 调用经过镜像来源校验的 `jbclient_trust_executable_recurse`；Dry Run 不得为了测试临时文件污染内核 trust cache。

RootHide 下不得在真实 `/var/mobile/Library/Caches/wiki.qaq.TrollFools.L` 保存 Injector 数据；`temporaryRoot` 和持久插件目录必须走同一套已验证 `jbroot` 映射。更新检查使用 ephemeral URLSession，以免主动创建持久 HTTP storage。`Saved Application State` 属于系统场景恢复链路，当前 RootHide 没有可验证的公开重定向能力；不要用 `UIApplicationExitsOnSuspend` 等会破坏正常挂起/恢复的设置规避它。

iOS 的系统 dylib 可能只存在于 dyld shared cache，`FileManager.fileExists("/usr/lib/...")` 返回 false 不能证明依赖缺失。对于 `@rpath/<leaf>.dylib`，应先用 dyld 的 `dlopen_preflight` 检查规范 `/usr/lib` 路径；成功时可通过插件自身的 `/usr/lib` rpath 解析，失败且 App/同批资产中也找不到时才属于真正未解析依赖。不得把任意 `@rpath` 依赖直接降级为警告。

`FRONTBOARD 0x8BADF00D` 不一定只是“插件加载太慢”。如果触发线程同时出现同一个插件 image offset 数百次连续重复，并最终接近 stack guard，应判定为插件递归导致的栈耗尽；watchdog 只是启动时间被递归消耗后的次生终止。Build 262 的可选兼容 Loader 会保护插件自有 `setHidden:`、`setAlpha:`、`setUserInteractionEnabled:` hook 的同对象递归重入，且该机制已在 DYYY 报告场景完成真机验证；它不会吞掉任意插件异常，不会覆盖其他 selector，也不会修改插件偏好。

Dry Run 显示 `SAFE TO INJECT` 且插件列表为空属于正确行为；它不会实际注入。Dry Run 通过也不等于已经完成真机启动验证。

## 7. 开发原则

1. 先读当前仓库、日志和完整调用链，再修改。
2. 优先兼容层、bug fix、diagnostics、validation 和 rollback，避免大规模重写。
3. 不修改现有 `GSPlayerInfo.dylib` 来掩盖注入器问题。
4. 不关闭签名/Mach-O validation，不用 try/catch 吞掉根因。
5. 保留原始 entitlements，校验签名前后 slice、CodeDirectory 和 load commands。
6. 使用运行时 capability detection，不仅按 `iOS >= 18` 分支。
7. RootHide 路径必须通过已验证的 `libroothide`/`jbroot` 能力获得；普通 Rootless 保持 `/var/jb`。RootHide 内还要按能力区分 Bootstrap fast-path 与 Dopamine recursive trust，不得把三者混为同一固定路径或签名流程。
8. 中文 UI 文案写入本地化文件，长说明必须允许换行。
9. 修改前检查 Git dirty state，不覆盖用户未提交改动。
10. 真实设备未测试时只标记 `STATICALLY VERIFIED`，不得宣称支持已经真机验证。
11. 代码修改产生了可复用的维护、诊断或发布经验时，必须同步更新本手册和 repo-local Skill，并随代码一起 push 到 GitHub；repo-local Skill 是用户级已安装 Skill 的同步源。

## 8. 构建和发布

网络访问使用局域网 mihomo：

```powershell
$env:HTTP_PROXY='http://192.168.6.110:7892'
$env:HTTPS_PROXY='http://192.168.6.110:7892'
$env:ALL_PROXY='socks5://192.168.6.110:7892'
```

正常流程：

1. 检查 `git status`，完成最小代码修改和静态检查。
2. 仅在需要应用新包时递增版本；文档修改不递增版本。
3. 提交并推送 fork。
4. 推送 `main` 后由 `.github/workflows/compile.yml` 自动构建；也可使用 `workflow_dispatch` 手动重跑。
5. 下载 TIPA/DEB/dSYM。
6. 解析 TIPA 内 Info.plist，核对名称、Bundle ID、版本、ZIP 完整性和 `0755` 权限。
7. 解析主程序及 `ct_bypass` Mach-O 架构、slice 数和签名区，检查 helper 是否异常膨胀。
8. 核对主程序同时包含 `fastPathSign`、`jbclient_trust_executable_recurse`、`/usr/lib/libjailbreak.dylib` 和 RootHide 能力诊断；核对 `TrollFoolsLoader.dylib` 为 arm64+arm64e、install name 为 `@rpath/TrollFoolsLoader.dylib`，包含 `__DATA,__interpose` 和 `Guarded %lu reentrant UIKit setter hook(s)` 诊断字符串；确认它只存在于 App 资源内，不残留为独立 rootless 库。
9. 使用 `devkit/collect-dsyms.sh` 按架构合并同名 dSYM，并确认 Loader/Tweak dSYM 均包含 arm64+arm64e，避免复制覆盖 arm64e 调试符号。
10. 计算 SHA-256，并复制到当前任务指定的输出目录；不要假设固定桌面路径。
11. 输出 GitHub Actions 链接、提交哈希、文件路径、SHA-256 和验证级别。

## 9. 新会话直接用法

### Codex 或支持 Skill 的工具

先安装本目录的 Skill，然后发送：

```text
使用 $trollfools-ios18-maintainer 处理这个问题：<问题描述>。
日志在：<路径>。
先读取仓库和日志定位根因，再做最小修改、GitHub Actions 编译、TIPA 核验和仓库同步。禁止写入我的手机。
```

### 不支持 Skill 的其他 AI

发送：

```text
当前工作目录是 TrollFools-ios18 仓库。请先读取 ./AGENTS.md、
./docs/TrollFools.L维护手册.md 和当前仓库代码，然后处理：<问题>。
附件：<日志或截图路径>。先诊断根因，禁止写入手机，完成后构建、核验产物并同步 fork。
```

更完整的模板在 Skill 的 `references/request-template.md`。

## 10. Skill 安装

Skill 源目录始终使用仓库相对路径：

`.agents/skills/trollfools-ios18-maintainer`

将整个 Skill 文件夹复制到工具自己的用户级 Skills 目录，重新开启会话后即可使用 `$trollfools-ios18-maintainer`。Codex 通常使用 `$CODEX_HOME/skills`；其他工具以自身配置为准。不支持 Skill 的工具直接读取本维护手册和 Skill 内的 `SKILL.md`。

Skill 自检命令：

```powershell
python <quick_validate.py 的实际路径> .\.agents\skills\trollfools-ios18-maintainer
```
