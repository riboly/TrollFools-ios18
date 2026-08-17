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
- Dopamine Rootless 3.0.5
- TrollStore Lite 2.1.1
- 已安装 Sileo、Filza、Frida 16.3.3

这是 Dopamine Rootless，不是 RootHide，也不是 Rootful。Rootless 工具路径以 `/var/jb` 为主，不得加入 `.roothide` 或随机 `.jbroot-*` 路径假设。

手机默认只读。AI 可以在用户明确同意时读取日志或设备信息，但禁止安装软件、修改文件、注入进程、重启服务或改变设置，除非当前任务单独明确授权了对应操作。

## 3. 已验证基线

- `4.3-253`：TIPA 能导入安装，但本次目标注入不可用。
- `4.3-254`：出现打包回归，`ct_bypass` 被 CI 替换为约 8.44 MB 的 arm64+arm64e fat helper，TrollStore Lite 点击 TIPA 无反应。
- `4.3-258`：**DEVICE VERIFIED**。用户已在上述真实设备确认 `GSPlayerInfo.dylib` 注入成功。
- `4.3-259`：完成 TrollFools.L 品牌、图标、Bundle ID、广告移除、Dry Run UI 和策略说明；创建时为 **STATICALLY VERIFIED**。

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
- 启动前兼容加载：目标 framework 仅加载 `TrollFoolsLoader.dylib`，由 loader 在所有 framework 初始化完成后、`UIApplicationMain` 前按 `TrollFoolsLoader.plist` 清单加载插件；用于“注入成功但插件构造阶段闪退”的场景

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

Dry Run 显示 `SAFE TO INJECT` 且插件列表为空属于正确行为；它不会实际注入。Dry Run 通过也不等于已经完成真机启动验证。

## 7. 开发原则

1. 先读当前仓库、日志和完整调用链，再修改。
2. 优先兼容层、bug fix、diagnostics、validation 和 rollback，避免大规模重写。
3. 不修改现有 `GSPlayerInfo.dylib` 来掩盖注入器问题。
4. 不关闭签名/Mach-O validation，不用 try/catch 吞掉根因。
5. 保留原始 entitlements，校验签名前后 slice、CodeDirectory 和 load commands。
6. 使用运行时 capability detection，不仅按 `iOS >= 18` 分支。
7. 中文 UI 文案写入本地化文件，长说明必须允许换行。
8. 修改前检查 Git dirty state，不覆盖用户未提交改动。
9. 真实设备未测试时只标记 `STATICALLY VERIFIED`，不得宣称支持已经真机验证。
10. 代码修改产生了可复用的维护、诊断或发布经验时，必须同步更新本手册和 repo-local Skill，并随代码一起 push 到 GitHub；repo-local Skill 是用户级已安装 Skill 的同步源。

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
8. 核对 `TrollFoolsLoader.dylib` 为 arm64+arm64e、install name 为 `@rpath/TrollFoolsLoader.dylib`，并包含 `__DATA,__interpose`；确认它只存在于 App 资源内，不残留为独立 rootless 库。
9. 计算 SHA-256，并复制到当前任务指定的输出目录；不要假设固定桌面路径。
10. 输出 GitHub Actions 链接、提交哈希、文件路径、SHA-256 和验证级别。

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
