<!-- Translated from docs/guides/tailscale-userspace.md at 2b014a24 -->

# 不在 Mac 上配置 VPN 运行 Tailscale（进阶）

本指南在 Mac 的终端中运行 Tailscale，而不安装桌面端 Tailscale 应用，因此不会在 Mac 上添加系统 VPN 或网络扩展。Heeler 会加入同一个 tailnet，并通过 Mac 的常规 SSH 登录。

你需要使用包含 **Settings > Overlay Networks** 的 Heeler 版本，并准备好 [Homebrew](https://brew.sh/) 以及一个可以添加设备的 Tailscale 账号。如果希望使用常规的桌面端 Tailscale 应用，请改用[通过 Tailscale 连接 Heeler](tailscale.md)。

## 1. 准备 Mac

先完成[准备 Host](overlay-networks.md#准备-host)，然后确认 Mac 本机的 SSH 服务正常响应：

```sh
nc -vz 127.0.0.1 22
```

连接应当成功。如果被拒绝，请检查是否已开启 **Remote Login**（远程登录）。

## 2. 安装 Tailscale

```sh
brew install --formula tailscale
```

请不要使用 `brew services` 启动它，而是按下面第 3 步的方式运行。

## 3. 启动 Tailscale

打开一个终端窗口（记为**终端 A**）并运行：

```sh
TS_BIN="$(brew --prefix tailscale)/bin"
TS_STATE_DIR="$HOME/.local/share/heeler-tailscale"
umask 077
mkdir -p "$TS_STATE_DIR"
chmod 700 "$TS_STATE_DIR"
"$TS_BIN/tailscaled" \
  --tun=userspace-networking \
  --statedir="$TS_STATE_DIR" \
  --socket="$TS_STATE_DIR/tailscaled.socket"
```

请保持**终端 A** 处于打开状态。Tailscale 仅在该窗口打开期间运行。

## 4. 登录 Mac 节点

打开第二个终端窗口（记为**终端 B**）并运行：

```sh
TS_BIN="$(brew --prefix tailscale)/bin"
TS_STATE_DIR="$HOME/.local/share/heeler-tailscale"
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" up \
  --hostname=heeler-mac-userspace
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" status
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" ip -4
```

1. 打开 `up` 命令输出的登录链接，登录 Heeler 将要加入的同一个 tailnet。
2. 如果你的 tailnet 开启了设备审批，请在管理控制台中批准这台 Mac。
3. 记下 `ip -4` 输出的 IPv4 地址。

> [!IMPORTANT]
> 在此模式下，tailnet 中任何获准访问这台 Mac 的设备，都可以访问 Mac 本机监听的所有服务（而不仅是 SSH）。请在 tailnet 的[访问控制规则](https://tailscale.com/docs/features/access-control/grants)中，仅允许 Heeler 访问这台 Mac 的 `tcp:22` 端口。

## 5. 连接 Heeler

1. 在 Heeler 中添加网络：按[从 Heeler 加入同一个 tailnet](tailscale.md#3-从-heeler-加入同一个-tailnet)操作。
2. 将 Mac 添加为 Host：按[从 Heeler 连接](overlay-networks.md#从-heeler-连接)操作。在 **Network** 下选择该网络，通过 **Choose from Tailnet…** 选择 `heeler-mac-userspace`，或直接输入第 4 步记下的 IPv4 地址。
3. 端口填 `22`，填入 Mac 用户名和第 1 步选择的登录方式。**Jump Host** 留空。
4. 按[验证连接](overlay-networks.md#验证连接)完成测试。

## 停止或移除 Mac 节点

如需停止通过 tailnet 访问这台 Mac，在**终端 A** 中按 **Control-C** 即可。需要恢复时，重新执行第 3 步。重启 Mac 或注销账户后 Tailscale 也会停止，因此使用 Heeler 期间请保持 Mac 唤醒且**终端 A** 打开。

如需将这台 Mac 从 tailnet 中移除，请在**终端 A** 仍在运行时执行：

```sh
"$(brew --prefix tailscale)/bin/tailscale" \
  --socket="$HOME/.local/share/heeler-tailscale/tailscaled.socket" logout
```

然后在**终端 A** 中按 **Control-C**，并删除保存的本地状态：

```sh
rm -rf "$HOME/.local/share/heeler-tailscale"
```

如果管理控制台中仍显示该 Mac 节点，请在控制台中将其移除。如需移除 Heeler，也请一并在管理控制台中删除 Heeler 设备。

## 故障排查

| 问题 | 检查项 |
| --- | --- |
| 终端 B 无法连接 Tailscale，或显示了另一台机器 | 确保终端 A 仍在运行，并完整复制终端 B 中的命令。 |
| Mac 在线但 SSH 超时 | 确认在 Mac 上运行 `nc -vz 127.0.0.1 22` 成功，且访问规则允许 Heeler 访问该 Mac 的 `tcp:22`。 |
| Mac 上的其他应用无法访问 tailnet 设备 | 这是预期行为。在此模式下，Mac 本机应用不走 tailnet，但 tailnet 设备仍可连入 Mac。 |
| 重启后无法连接 | 在终端 A 中重新运行第 3 步。 |

命令已对照 Tailscale 1.104.1 核对（2026 年 10 月）。

维护者：参见[指南维护记录](../../agents/overlay-network-guides.md)。
