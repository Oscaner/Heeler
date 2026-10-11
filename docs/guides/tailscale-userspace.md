# Tailscale without a VPN on the Mac (advanced)

This guide runs Tailscale on the Mac from Terminal instead of the Tailscale app, so the Mac gets no VPN or network extension. Heeler joins the same tailnet and logs in to the Mac over its normal SSH.

You need a Heeler version with **Settings > Overlay Networks**. You also need [Homebrew](https://brew.sh/) and a Tailscale account that can add devices. For the usual setup with the Tailscale app, follow [Connect Heeler through Tailscale](tailscale.md) instead.

## 1. Prepare the Mac

Complete [Prepare the Host](overlay-networks.md#prepare-the-host). Then check that SSH answers on the Mac itself:

```sh
nc -vz 127.0.0.1 22
```

The connection should succeed. If it is refused, check that **Remote Login** is on.

## 2. Install Tailscale

```sh
brew install --formula tailscale
```

Don't start it with `brew services`; use step 3 instead.

## 3. Start Tailscale

Open a Terminal window (**Terminal A**) and run:

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

Leave Terminal A open. Tailscale runs only while this window is open.

## 4. Sign the Mac in

Open a second window (**Terminal B**) and run:

```sh
TS_BIN="$(brew --prefix tailscale)/bin"
TS_STATE_DIR="$HOME/.local/share/heeler-tailscale"
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" up \
  --hostname=heeler-mac-userspace
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" status
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" ip -4
```

1. Open the login link that `up` prints and sign in to the tailnet Heeler will join.
2. If your tailnet requires device approval, approve the Mac in the admin console.
3. Write down the IPv4 address that `ip -4` prints.

> [!IMPORTANT]
> In this mode, any tailnet device that is allowed to reach the Mac can connect to every service listening on the Mac itself, not only SSH. In your tailnet's [access rules](https://tailscale.com/docs/features/access-control/grants), allow Heeler to reach this Mac only on `tcp:22`.

## 5. Connect Heeler

1. Add the network in Heeler: follow [Join the same tailnet from Heeler](tailscale.md#3-join-the-same-tailnet-from-heeler).
2. Add the Mac as a Host: follow [Connect from Heeler](overlay-networks.md#connect-from-heeler). Under **Network**, pick this network. Use **Choose from Tailnet…** to pick `heeler-mac-userspace`, or type the IPv4 address from step 4.
3. Use port `22`, your Mac username, and the sign-in method you picked in step 1. Leave **Jump Host** blank.
4. Run through [Verify the connection](overlay-networks.md#verify-the-connection).

## Stop or remove the Mac

To stop tailnet access to the Mac, press **Control-C** in Terminal A. To start again, run step 3 again. Tailscale also stops when you restart the Mac or log out, so keep the Mac awake and Terminal A open while you use Heeler.

To remove the Mac from the tailnet, run this while Terminal A is still running:

```sh
"$(brew --prefix tailscale)/bin/tailscale" \
  --socket="$HOME/.local/share/heeler-tailscale/tailscaled.socket" logout
```

Then press **Control-C** in Terminal A and delete the saved state:

```sh
rm -rf "$HOME/.local/share/heeler-tailscale"
```

If the Mac still appears in the Tailscale admin console, remove it there. To remove Heeler, delete Heeler's device in the admin console too.

## Troubleshooting

| Problem | Check |
| --- | --- |
| Terminal B can't connect to Tailscale, or shows a different machine | Keep Terminal A running, and copy the commands in Terminal B exactly. |
| The Mac is online but SSH times out | `nc -vz 127.0.0.1 22` works on the Mac, and your access rules allow Heeler to reach the Mac on `tcp:22`. |
| Other Mac apps can't reach tailnet devices | Expected. In this mode, the Mac's own apps get no tailnet access. Tailnet devices can still reach the Mac. |
| It stopped working after a restart | Run step 3 again in Terminal A. |

Commands were checked against Tailscale 1.104.1 in October 2026.

Maintainers: see the [guide maintenance record](../agents/overlay-network-guides.md).
