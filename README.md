# TrollFools

[now-on-havoc]: https://havoc.app/package/trollfools

[<img width="150" src="https://docs.havoc.app/img/badges/get_square.svg" />][now-on-havoc]

In-place tweak injection with insert_dylib and ChOma.  
Proudly written in SwiftUI.  

Expected to work on all iOS versions supported by opa334’s TrollStore (i.e. iOS 14.0 - 17.0).

## TrollFools.L Fork Maintenance / AI 维护入口

This fork contains an iOS 18/rootless compatibility layer, transactional backup and rollback, injection diagnostics, Dry Run signing simulation, and the `TrollFools.L` branding. The application build is still produced by the existing Xcode/Theos workflow; the Markdown and Agent Skill files below do not participate in compilation.

本 fork 已加入 iOS 18/Rootless 兼容诊断、事务备份与回滚、注入后验证、Dry Run 签名模拟以及 `TrollFools.L` 品牌修改。维护资料不会参与 App 编译。

AI 或开发者开始维护前，按顺序读取：

1. [AGENTS.md](AGENTS.md)：必须遵守的基线和约束
2. [TrollFools.L 维护手册](docs/TrollFools.L维护手册.md)：设备环境、历史问题、代码位置、构建和验证流程
3. [Repo-local Agent Skill](.agents/skills/trollfools-ios18-maintainer/SKILL.md)：可导入 Codex 或其他支持 Agent Skills 的工具
4. [新会话请求模板](.agents/skills/trollfools-ios18-maintainer/references/request-template.md)：Bug 和功能请求模板

已确认的回归基线：`4.3-258` 已在 iPhone XS Max/A12、iOS 18.2.1、Dopamine Rootless 3.0.5、TrollStore Lite 2.1.1 上完成真实注入验证。后续维护不得破坏该链路。

### 支持 Agent Skills 的 AI

将当前仓库中的 `.agents/skills/trollfools-ios18-maintainer` 导入对应工具，然后在新会话发送：

```text
使用 $trollfools-ios18-maintainer 处理下面的问题。当前工作目录是 TrollFools-ios18 仓库。
请先读取仓库中的 AGENTS.md、维护手册、当前代码和附件，定位根因后再做最小修改、验证、GitHub Actions 构建、产物核验和仓库同步。禁止写入我的手机。

问题：<现象或功能需求>
版本：<TrollFools.L 版本>
附件：<日志、注入报告、崩溃报告或截图路径>
期望：<正确行为>
```

### 不支持 Agent Skills 的 AI

在仓库根目录打开 AI 工具，然后发送：

```text
当前工作目录是 TrollFools-ios18 仓库。请先读取 ./AGENTS.md、
./docs/TrollFools.L维护手册.md 和当前代码，再处理下面的问题。
先诊断根因，再做最小修改、验证、GitHub Actions 构建、产物核验和仓库同步。禁止写入我的手机。

问题：<现象或功能需求>
附件：<日志、注入报告、崩溃报告或截图路径>
```

仓库位置或成品目录改变时，只需在仓库根目录启动 AI，或明确告诉 AI 当前仓库/附件/输出目录；提示词不依赖固定的 Windows 绝对路径。

## Limitations

- [x] Removable system applications
- [x] Decrypted App Store applications (TrollStore applications)
- [x] Encrypted App Store applications with bare dynamic library

## Build

See GitHub Actions for the latest build status.  
PRs are always welcome.

## Milestones

- [x] `optool` is buggy so we need to compile a statically linked `install_name_tool` or `llvm-install-name-tool` on iOS to achieve a smaller package size.
- [x] Support for `.deb` or `.zip`.

## Credits

This project is inspired by [Patched-TS-App](https://github.com/34306/Patched-TS-App) by **[Huy Nguyen](https://x.com/Little_34306) and [Nathan](https://x.com/dedbeddedbed)**.

- [ChOma](https://github.com/opa334/ChOma) by [@opa334](https://github.com/opa334) and [@alfiecg24](https://github.com/alfiecg24)
- [MachOKit](https://github.com/p-x9/MachOKit) by [@p-x9](https://github.com/p-x9)
- [insert_dylib](https://github.com/tyilo/insert_dylib) by [@tyilo](https://github.com/tyilo)

## License

See [LICENSE](LICENSE).
