# 新会话请求模板

## 最短用法

支持 Skill 的 AI：

```text
使用 $trollfools-ios18-maintainer 处理下面的问题。先读取真实仓库和附件，先定位根因，再做最小修改、GitHub Actions 编译和包体核验；不要写入我的手机。

问题：<描述现象>
版本：<TrollFools.L 版本>
附件：<日志/注入报告/崩溃报告路径>
期望：<正确行为>
```

不支持 Skill 的 AI：

```text
当前工作目录是 TrollFools-ios18 仓库。请先读取：
1. ./AGENTS.md
2. ./docs/TrollFools.L维护手册.md
3. 当前仓库代码

然后处理下面的问题。先诊断根因，再做最小修改、构建、产物核验和仓库同步。禁止在手机中安装或修改任何文件。

问题：<描述>
附件：<路径>
```

## Bug 信息

尽量附上：

```text
TrollFools.L 版本：
iOS / 月余环境 / TrollStore Lite 版本：
目标 App 与 Bundle ID：
插件名称：
关闭注入调试时的结果：
打开注入调试时的结果：
注入报告路径：
App 日志路径：
iOS 崩溃报告路径：
是否能稳定复现：
最后一次正常版本：
```

## 功能请求

```text
使用 $trollfools-ios18-maintainer 给 TrollFools.L 增加以下功能：<功能>。
保持 4.3-258 已验证的注入链路，不破坏 iOS 14-17；RootHide 只能使用经过验证的动态 `jbroot` 映射，不得写死隐藏前缀。
请先指出修改文件、函数、风险和验证方法，再实现、触发 GitHub Actions、核验 TIPA，并同步到 fork。
```
