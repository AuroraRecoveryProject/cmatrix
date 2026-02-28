# Android / Recovery 运行 cmatrix 记录

本文记录在 Android arm64（含 recovery 环境）运行本项目 `cmatrix` 时遇到的关键问题、根因与对应修复方案，并给出可复现的验证步骤。

## 目标

- 构建可在 Android arm64 上运行的 `cmatrix`（静态链接 ncurses）。
- 在 recovery 的“真实终端”中能正确初始化 ncurses（不再报 `Error opening terminal: ...`）。
- 能在失败时输出足够诊断信息，而不是盲猜。

## 编译 cmatrix 为 Android recovery 可用二进制（arm64）

本文是“操作手册”：用本仓库现有脚本，在 macOS/Linux 主机上交叉编译出 **Android arm64 recovery 可用**的 `cmatrix`，并推送到设备 `/tmp` 运行。

适用场景：recovery 用户空间极简、缺库、缺 terminfo 数据库，因此需要 **静态链接 ncurses** + 自带（推送）terminfo。

### 1. 前置条件

#### 1.1 主机工具

- `adb`（能连接到设备 recovery）
- Android NDK（建议 NDK r27+）
- `curl`（用于下载 ncurses 源码压缩包）

> `push_terminfo_android.sh` 会检查主机 `tic` 是否存在；但当前脚本优先从 `/usr/share/terminfo` 复制已编译条目，通常不会走 `tic`。

#### 1.2 环境变量

设置 NDK 路径（示例）：

- `export ANDROID_NDK="$HOME/Library/Android/sdk/ndk/27.3.13750724"`

验证：

- `test -d "$ANDROID_NDK/toolchains/llvm"`

### 2. 构建（生成 recovery 可用二进制）

在仓库根目录执行：

- `./build_android.sh`

成功后产物位置：

- `build_android/cmatrix`

#### 2.1 构建为何能在 recovery 上跑（关键点）

- **静态链接 ncurses**：`cmatrix` 依赖 curses，recovery 通常没有系统库；脚本会编译 `ncurses` 并静态链接 `libncursesw.a`。
- **static PIE + TLS 对齐修复**：Android arm64 loader 对 TLS 段对齐要求严格。
  - 编译参数包含 `-fno-emulated-tls`，确保 `__thread` 生成真实 TLS 段。
  - 可执行文件以 PIE 方式链接（并静态链接）。
  - `cmatrix.c` 中包含 64 对齐 TLS 变量，确保 `PT_TLS Align >= 64`。

### 3. 生成并推送 terminfo（最小集合）

在仓库根目录执行：

- `./push_terminfo_android.sh`

当前脚本生成的最小条目为：

- `android_terminfo/x/xterm-256color`

并推送到设备：

- `/tmp/terminfo/android_terminfo`

> 如果你的 recovery 终端实际 `TERM` 不是 `xterm-256color`，你需要把脚本扩展为同时推送对应条目，否则 ncurses 可能找不到 terminfo。

### 4. 一键 push + 启动（推荐）

#### 4.1 一键 push 并运行

- `./push_and_start_android.sh`

它会把以下文件推到设备 `/tmp`：

- `/tmp/cmatrix`
- `/tmp/cmatrix_start.sh`
- `/tmp/terminfo/android_terminfo/...`

然后通过 `adb shell -t` 分配 PTY 并启动。

#### 4.2 只 push 不运行

- `./push_and_start_android.sh --no-run`

适合你已经在 recovery 的真实终端里手动执行。

## 问题与解决方案

### 问题 1：运行即崩溃（TLS segment underaligned）

#### 现象

在 Android/arm64 上执行 `cmatrix` 直接被 loader 中止，报错类似：

- `executable's TLS segment is underaligned ... needs to be at least 64 for ARM64 Bionic`

#### 根因

Android Bionic 对 ARM64 的 TLS Program Header（`PT_TLS`）对齐有硬性要求：对齐必须 ≥ 64。

若编译/链接导致 TLS 段对齐只有 8（常见于使用 emulated TLS 或 TLS 布局无法提升对齐），Bionic loader 会直接拒绝加载。

#### 解决方案

同时满足两点：

1. **禁用 emulated TLS**：构建参数加入 `-fno-emulated-tls`，确保 `__thread` 真正进入 `PT_TLS`。
2. **强制 64 对齐的 TLS 变量**：在 `cmatrix.c` 中为 Android/aarch64 增加 `aligned(64)` 的 `__thread` 变量，使链接产物的 `PT_TLS Align` 提升到 64。

#### 验证

在主机上用 NDK 的 `llvm-readelf -l` 检查可执行文件 program headers：

- 期望 `PT_TLS` 的 `Align` 显示为 `0x40`。

### 问题 2：`Error opening terminal: xterm-256color`（ncurses 初始化失败）

#### 现象

在设备端执行时，报：

- `Error opening terminal: xterm-256color.`

#### 根因候选（常见组合）

- 设备端没有可用的 terminfo 数据库（Android/recovery 常缺 `/usr/share/terminfo`）。
- `TERM` 对应的 terminfo 条目不存在或目录布局不匹配。
- ADB 未分配 PTY（需要 `adb shell -t`），导致 `isatty()`/终端能力不满足。

#### 解决方案

1. **推送最小 terminfo 集合到设备**

- 使用脚本 `push_terminfo_android.sh` 生成并 push 条目：`xterm-256color`。
- 当前仅保留传统首字母目录布局：`x/xterm-256color`。

1. **使用 PTY 运行**
   - 交互启动建议使用：`adb shell -t`

2. **统一运行入口（设备端启动器）**
   - 使用 `cmatrix_start.sh` 在设备上设置：
     - `TERM`
     - `TERMINFO` / `TERMINFO_DIRS`

- 在 terminfo 不存在时会提示并尝试降级；但如果你只推送了 `xterm-256color`，则仅该 TERM 可用。

#### 验证（推荐流程）

- 一键 push + 启动：
  - `./push_and_start_android.sh`

- 显式指定 TERM：
  - `./push_and_start_android.sh --term xterm-256color`

#### 如何验证当前使用的是哪份 terminfo（/system vs /tmp）

有些 Android 环境本身就带有 `/system/etc/terminfo/...`，这会让你“即使不推送 /tmp/terminfo 也能跑”。为了验证 recovery 场景（只依赖你推送的最小 terminfo）是否可靠，**不要尝试删除 /system 里的文件**，直接用环境变量强制 ncurses 只在你指定的目录里查找。

1) 查看设备上有哪些位置存在 `xterm-256color`：

- `adb shell 'ls -l /system/etc/terminfo/x/xterm-256color 2>/dev/null || true; ls -l /tmp/terminfo/android_terminfo/x/xterm-256color 2>/dev/null || true'`

2) 强制只使用你推送的 `/tmp` terminfo 运行（推荐 `-t` 分配 PTY）：

- `adb shell -t 'export TERM=xterm-256color; export TERMINFO_DIRS=/tmp/terminfo/android_terminfo; unset TERMINFO; unset TERMCAP TERMPATH; export HOME=/tmp/empty_home && mkdir -p "$HOME"; /tmp/cmatrix'`

说明：

- 这里用 `TERMINFO_DIRS=/tmp/terminfo/android_terminfo` 是为了“锁死”搜索路径，避免 ncurses 回退去命中 `/system/etc/terminfo`。
- `HOME=/tmp/empty_home` 用于避免意外命中 `$HOME/.terminfo`。

3) 反证（可选）：临时挪走 `/tmp` 的条目，应该失败；再挪回去：

- `adb shell -t 'mv /tmp/terminfo/android_terminfo/x/xterm-256color /tmp/terminfo/android_terminfo/x/xterm-256color.bak; export TERM=xterm-256color; export TERMINFO_DIRS=/tmp/terminfo/android_terminfo; unset TERMINFO; unset TERMCAP TERMPATH; export HOME=/tmp/empty_home && mkdir -p "$HOME"; /tmp/cmatrix; echo "exit=$?"; mv /tmp/terminfo/android_terminfo/x/xterm-256color.bak /tmp/terminfo/android_terminfo/x/xterm-256color'`

> 说明：为定位该问题曾临时加入过 `CMATRIX_DEBUG_TERMINAL` 诊断输出（探测 terminfo/调用 setupterm 等），后续已还原移除。

### 问题 3：构建过程中 ncurses 安装失败（写 /etc/terminfo）

#### 现象

执行 `./build_android.sh` 时，`ncurses` 的 `make install` 可能尝试在主机写入 `/etc/terminfo`，导致失败（无权限/路径不可写）。

#### 根因

交叉编译场景下，我们只需要静态库和头文件；安装 terminfo 数据库到主机的默认路径既没必要也常会失败。

#### 解决方案

在 `build_android.sh` 中将 ncurses 的安装步骤改为只安装库与头文件：

- `make install.libs install.includes`

避免执行会触发 terminfo database 安装的 `make install`。

## 一键脚本与设备路径

为了适配 recovery，设备端默认使用 `/tmp`：

- 二进制：`/tmp/cmatrix`
- 设备端启动器：`/tmp/cmatrix_start.sh`
- terminfo：`/tmp/terminfo/android_terminfo`

对应脚本：

- 主机端一键：`push_and_start_android.sh`
- terminfo push：`push_terminfo_android.sh`
- 设备端启动器：`cmatrix_start.sh`
