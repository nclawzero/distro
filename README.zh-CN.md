# NCZ —— 智能体 Linux 发行版

> **🌐 语言：** [English](README.md) · 简体中文
>
> **📚 从这里开始：** [AI/ML 软件栈参考](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/AI-ML-STACK.zh-CN.md) ([English](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/AI-ML-STACK.md)) · [我们是如何走到这一步的 —— 工程复盘](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/HOW-DID-WE-GET-HERE.zh-CN.md) ([English](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/HOW-DID-WE-GET-HERE.md)) · [NCZ-OS 组织结构](docs/NCZ-OS-ORGANIZATION.md)

**NCZ Distribution Core**（NCZ 发行版核心）是 NCZ 的心脏：一个面向 **Arm 和 Intel
系统的智能体 Linux 发行版**，也是智能体记忆系统 **MNEMOS** 的家。

NCZ 交付一套完整的、为自主智能体就绪的操作系统 —— 加固过的 Ubuntu 基础系统、
常驻的智能体栈、设备端 AI（NPU / GPU / CPU 嵌入）以及 MNEMOS 记忆 —— 它可在边缘
板卡、桌面和服务器上启动并运行，横跨 **Arm**（如 CIX Sky1、Raspberry Pi）与
**Intel / x86-64** 硬件。

本仓库是该发行版的**共享、硬件无关的核心**：用户态、智能体栈、AI 运行时、桌面、
品牌化以及 CLI —— 每一种硬件变体都在其之上构建。各平台专属的*构建器*消费这个
核心，只添加其硬件独有的部分（内核、固件、引导器、设备树）。

---

## 包含什么

- **MNEMOS** —— 智能体记忆操作系统。为智能体提供生产级记忆，通过 MCP、一个
  OpenAI 兼容网关，以及原生 `/v1/*` REST 与所有主流框架互操作。NCZ 是它的家。
  → [`ncz-os/mnemos`](https://github.com/ncz-os/mnemos)
- **智能体栈** —— ZeroClaw 作为 Podman quadlet 开箱即用；OpenClaw 和 Hermes 由
  运维者通过 `ncz` CLI 选装。
- **设备端 AI** —— 通过 `mnemos-embedkit` 在 NPU / GPU / CPU 上自动生成嵌入，
  每个芯片目标上的 API 都相同。
- **桌面** —— 一个精致的、带 NCZ 品牌的 XFCE 环境（*Reinhardt* 桌面变体），
  或一个无头服务器配置（*Magnetar*）。
- **`ncz` CLI** —— 面向智能体栈与车队的运维工具。

## 如何组织

```
NCZ Distribution Core （本仓库 —— 共享用户态）
        │ 被消费
        ▼
各变体构建器（构建机制因平台而异）
  cix-installer     CIX Sky1 (Arm)        — d-i / debootstrap 网络安装
  pi-gen            Raspberry Pi (Arm)    — pi-gen 镜像
  (x86-64 构建器)   Intel / AMD 桌面      — 规划中

各变体内核：  linux-cix · linux-rpi · …
BSP / Yocto： meta-cix（已注册的 BSP 层）· meta · meta-base
打包 / 工具：  debs · ncz-tools
```

该核心作为一个钉死版本的 git 子模块被消费（对离线/气隙镜像构建友好）；`.deb`
打包是未来的一个选项。

完整的组织结构与迁移计划见 [`docs/`](docs/)。

## 规范源与镜像

GitLab `ncz-os/*` 是**规范的事实来源**。GitHub 和 Codeberg 是保持同步的**镜像**
—— 切勿把镜像当作主仓库来推送。

- GitLab（规范）：https://gitlab.com/ncz-os/distro-core
- GitHub（镜像）：https://github.com/ncz-os/distro-core
- Codeberg（镜像）：https://codeberg.org/ncz-os/distro-core

## 支持的硬件（以及实际测试过什么）

> *设计上*厂商中立 ≠ 处处测试过。迄今为止，该发行版只在**一块**板卡上验证过。
> 测试者和捐赠的硬件是扩展此列表的最快途径。

| 架构 | 目标 | 状态 |
| --- | --- | --- |
| Arm (aarch64) | **CIX Sky1 — Minisforum MS-R1**（32 GB / 64 GB） | ✅ **已测试** —— 唯一验证过的平台 |
| Arm (aarch64) | **CIX Sky1 — Radxa Orion O6 / O6N** | ❌ **未测试 —— 招募测试者，需要板子**（板卡不同，SoC 相同） |
| Arm (aarch64) | **CIX Sky1 — Framework 扩展板** | ❌ 未测试 —— 手头没有硬件 |
| Arm (aarch64) | **CIX Sky1 — Orange Pi（Cix 变体）** | ❌ 未测试 —— 手头没有硬件 |
| Arm (aarch64) | Raspberry Pi | 🚧 构建器已存在（pi-gen）；尚未验证 |
| Intel / AMD (x86-64) | 桌面 / 服务器 | 🗺️ 规划中 |

**如果你能帮忙：** 一块 O6（或任何非 MS-R1 的 Cix 板卡）到我们手上，或一位社区
测试者提交 issue，都能直接解除支持的阻塞。Radxa、Framework、Orange Pi —— 我们
非常想要一块板子。

## 许可证

Apache-2.0。见 [`LICENSE`](LICENSE)。
