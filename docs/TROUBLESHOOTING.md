# PartyBox Network Troubleshooting

[Setup guide](../QUICKSTART.md) · [Reference](REFERENCE.md)

Discovery is where this kind of app breaks. Work through these in order.

### 9.1 Prove the host is advertising at all

From any Mac on the same network:

```bash
dns-sd -B _partybox._tcp local.
```

You should see a line naming your host, e.g.:

```
Timestamp     A/R  Flags  if Domain  Service Type     Instance Name
12:04:31.882  Add      3   6 local.  _partybox._tcp.  Living-Room's PartyBox
```

- **Host listed** → advertising works; the problem is on the phone or between the phone and the host.
  Go to 9.3.
- **Nothing listed** → the host isn't advertising, or mDNS isn't crossing to your Mac. Go to 9.2.

To also see the address and port it resolves to:

```bash
dns-sd -L "Living-Room's PartyBox" _partybox._tcp local.
```

The TXT record shown there carries `v=2` (protocol version) and `id=<uuid>` (this host launch's instance).

### 9.2 Read the host's own log

The transport logs under the OSLog subsystem **`PartyNet`** (categories `HostTransport`,
`ClientTransport`, `PartyHost`).

**Mac host:**

```bash
log stream --predicate 'subsystem == "PartyNet"' --level debug
```

**Apple TV host:** open **Console.app** on your Mac, select the Apple TV in the sidebar (it must be
network-paired, per [Apple TV pairing](../QUICKSTART.md#52-pair-the-apple-tv-with-xcode-over-the-network)), and filter on `PartyNet`.

The line you're looking for, emitted right after the listeners bind:

```
PartyBox host ready on TCP 52408, UDP 52409
```

- **You see it** → the host is up and bound. Discovery is the problem, not startup.
- **You don't** → the host never started. The lobby status line will say
  `Could not start: <error>`. Usual causes: Local Network permission denied ([§9.3](#93-local-network-permission-on-the-iphone)), or the macOS
  firewall blocking incoming connections ([§9.4](#94-macos-firewall-mac-host-only)).

Other useful debug-level lines when things go wrong mid-party: `Control connection ended: …`,
`UDP flow ended: …`, `Input acknowledgment failed: …`, `Client session ended: …`, `Broadcast failed: …`.

### 9.3 Local Network permission on the iPhone

This is the single most common cause of "it just doesn't find anything."

The app tells you when it detects it. Any error containing *denied* or *policy* is rewritten to:

> *"Local Network access is off. Enable it for PartyBox Controller in Settings, then try again."*

And after 4 seconds with no hosts found you get the generic card:

> *"Make sure the host is open on the same Wi‑Fi network. If asked, allow Local Network access. You can
> change that permission in Settings."*

Fix it:

1. **Settings ▸ PartyBox Controller ▸ Local Network** — toggle **on**.
   (The **OPEN SETTINGS** button on that card takes you straight there.)
2. Force-quit and relaunch the app.
3. If the toggle isn't there at all, iOS never recorded a decision. Reset privacy prompts with
   **Settings ▸ General ▸ Transfer or Reset iPhone ▸ Reset ▸ Reset Location & Privacy**, then relaunch
   the app and tap **Allow**.

Do the same check on the **host** side: tvOS **Settings ▸ Apps ▸ PartyBox ▸ Local Network**, macOS
**System Settings ▸ Privacy & Security ▸ Local Network**.

### 9.4 macOS firewall (Mac host only)

**System Settings ▸ Network ▸ Firewall**:

- If the firewall is on, open **Options…** and confirm `PartyBox` is listed as
  **Allow incoming connections**.
- Make sure **Block all incoming connections** is **off** — it silently kills the TCP listener regardless
  of per-app settings.
- If PartyBox isn't listed, delete any stale entry, rebuild, and relaunch so the alert fires again.

There are **no fixed ports to open** — the listeners take ephemeral ports every launch, so per-port
firewall rules are useless here. Allow the application, not a port.

### 9.5 Router and Wi-Fi configuration

If `dns-sd` finds nothing from a Mac that's on the same Wi-Fi as the host:

| Check | Why |
|---|---|
| **AP / client isolation off** | Isolation lets devices reach the internet but not each other. Kills PartyBox entirely. |
| **Not a guest network** | Guest SSIDs almost always enable isolation. Put everyone on the main SSID. |
| **Same subnet** | Host and phones must share one subnet. A separate IoT VLAN or a second router in NAT mode will break it. |
| **mDNS forwarded across bands** | Some mesh systems (and some "smart" band-steering) drop mDNS between 2.4 GHz and 5 GHz. Symptom: *"discovery works sometimes."* Force the phones and the host onto the same band to test. |
| **No VPN on the phone** | A VPN profile can capture the local subnet. Disable it and retry. |

`CANDIDATE STACK.md` puts it this way:

> **Router config:** you control the AP, so just confirm client isolation is off and mDNS isn't being
> dropped across bands — some consumer mesh gear does this by default and it presents as
> "discovery works sometimes."

Remember there is **no AWDL/peer-to-peer fallback** — `peerToPeerIncluded(false)` is set on every listener,
browser and connection. If mDNS over the infrastructure network doesn't work, nothing works.

### 9.6 "INCOMPATIBLE VERSION" in the host list

The host row is orange, disabled, and labelled `INCOMPATIBLE VERSION`. The Bonjour TXT record's `v` field
doesn't match `PartyNetConstants.protocolVersion` (currently `2`).

Cause: the phone and the host were built from different commits. Rebuild **both** apps from the same
checkout and reinstall. If you're on TestFlight, ship a new controller build alongside your host update.

### 9.7 Play is laggy or the latency badge is orange

The badge on each phone shows measured round-trip time; it turns orange at **50 ms**.

What's happening under the hood, so you know what to blame:

- Input goes over **UDP at 60 Hz**. If the host stops acknowledging UDP for **1 second**, the phone
  silently falls back to sending input over **TCP at ~30 Hz** and keeps playing. It feels heavier but it
  doesn't disconnect.
- The control channel pings every **2 seconds** and gives up after **6 seconds** without a reply.

Things that actually help, in order of effect:

1. **Put the host on Ethernet.** Biggest single win — it takes the host out of Wi-Fi contention.
2. Move everyone to **5 GHz** and off any congested 2.4 GHz channel.
3. Get the phones physically closer to the AP; eight phones all transmitting at 60 Hz is real airtime.
4. Kick anything doing a big download off the network for the duration.

### 9.8 Last-resort escape hatch: connect by address

If Bonjour is broken on the venue's network and you can't fix it, a **Debug** build of the controller can
bypass discovery entirely:

1. Get the host's IP and TCP port from the log line in [§9.2](#92-read-the-hosts-own-log)
   (`PartyBox host ready on TCP 52408, …`).
2. Run the controller from Xcode with a launch argument
   (**Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments**):

   ```
   --host 192.168.1.42:52408
   ```

   IPv6 works too, bracketed, with an optional scope: `--host [fe80::1%en0]:52408`.
3. The picker gains an extra row named **UI Test Host**. Tap it to connect directly.

Caveats: this is compiled out of Release builds, the port changes every time the host restarts, and it
only helps for phones you can run from Xcode. It's a debugging tool, not a party feature.

### 9.9 Security reminder

The control channel is **plain JSON over TCP with no TLS**, and there is **no join code or pairing
secret**. Any device on the LAN running the controller app can join your party and take a seat. That's
fine on your home network; don't do it on a shared or public one.

---
