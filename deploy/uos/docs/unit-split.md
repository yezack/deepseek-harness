# 两单元拆分（已废弃）

本文件记录的是**旧方案**：把 UOS 离线包拆成 `body`（本体）与 `plugins`（插件）两个
单元，各自一个 tar.gz（`dsh-uos-body-*.tar.gz` / `dsh-uos-plugins-*.tar.gz`）。

该方案已被 [component-distribution.md](component-distribution.md) 取代：

- 分发不再是"一个整包或两个单元包"，而是**目录 + installer + 每个组件一个包**；
- 升级不再是"整单元替换"，而是按组件粒度替换，并带事务与回滚；
- 浏览器 deb 不再随包携带（改用 Electron 界面 + 系统浏览器探测）；
- 只有离线介质，没有在线更新通道。

同目录的 `test-unit-split.sh` / `test-upgrade-units.sh` 也针对旧布局，待替换为
`test-components.sh`（见新文档 §8 验收用例）。
