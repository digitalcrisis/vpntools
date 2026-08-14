# NordVPNWireGuardGenTool

A PowerShell script that generates a NordVPN WireGuard (`.conf`) configuration using your own NordVPN account access token — no NordVPN app required, no manual key hunting.

It can target a specific server, let NordVPN recommend the best server in a country, or narrow that recommendation down to a specific city. It can also render the config as a scannable QR code directly in the terminal, and optionally skip writing a file to disk entirely.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Internet access (queries `api.nordvpn.com` and, for QR codes, `nuget.org` once to cache the QRCoder library)
- A NordVPN account with an active subscription

## Setup

1. Generate an access token at https://my.nordaccount.com/dashboard/nordvpn/access-tokens/authorize/.
   - Choose "Set to expire in 30 days" or "Doesn't expire," depending on how often you're willing to regenerate it.
2. Open the script and paste your token into the `$DefaultAccessToken` variable near the top:
   ```powershell
   $DefaultAccessToken = "PASTE_YOUR_ACCESS_TOKEN_HERE"
   ```
   Alternatively, skip this and pass `-AccessToken` on the command line each time instead.

3. If Windows blocks the script from running, either:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\NordVPNWireGuardGenTool.ps1 ...
   ```
   or unblock it once and allow local scripts:
   ```powershell
   Unblock-File -Path .\NordVPNWireGuardGenTool.ps1
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```

## Usage

Pick **one** of three ways to select a server:

| Mode | Example | What it does |
|---|---|---|
| Specific server | `-ServerHostname "us12223.nordvpn.com"` | Builds a config for that exact server |
| Country (recommended) | `-CountryCode "CA"` | Asks NordVPN for the lowest-load, nearest server in that country |
| Country + city | `-CountryCode "US" -City "Houston"` | Filters to that city, picks the lowest-load match |

```powershell
# Specific server
.\NordVPNWireGuardGenTool.ps1 -ServerHostname "us12223.nordvpn.com"

# Best server in Canada
.\NordVPNWireGuardGenTool.ps1 -CountryCode "CA"

# Best server in Houston, US
.\NordVPNWireGuardGenTool.ps1 -CountryCode "US" -City "Houston"

# Same as above, but don't save a .conf file — just print/QR it
.\NordVPNWireGuardGenTool.ps1 -CountryCode "US" -City "Houston" -NoConf
```

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-AccessToken` | No* | Your NordVPN access token. Falls back to `$DefaultAccessToken` in the script if omitted. |
| `-ServerHostname` | One of these three | A specific server hostname, e.g. `us12223.nordvpn.com`. |
| `-CountryCode` | One of these three | 2-letter country code, e.g. `US`, `CA`, `DE`. |
| `-City` | No (requires `-CountryCode`) | City name, e.g. `Houston`. Narrows the country recommendation to one city. |
| `-OutputPath` | No | Directory to write the `.conf` file to. Defaults to the current directory. |
| `-NoQr` | No | Skip rendering the QR code in the console. |
| `-NoConf` | No | Don't write a `.conf` file at all — config is still printed/QR'd. |

\* Required if you didn't hardcode a default token in the script.

## What it does, step by step

1. **Authenticates** to `api.nordvpn.com/v1/users/services/credentials` using your access token and retrieves your NordLynx (WireGuard) private key.
2. **Resolves a server**, depending on mode:
   - *Hostname:* pulls the full server list and filters client-side by exact hostname match (NordVPN's API has no hostname filter parameter).
   - *Country only:* looks up the country's internal ID, then calls NordVPN's `recommendations` endpoint filtered to that country and WireGuard, sorted by load.
   - *Country + city:* pulls the full server list and filters client-side by country code and city name, then picks the lowest-load match itself (NordVPN's API doesn't reliably support city-level filtering server-side).
3. **Builds the config** in standard WireGuard format:
   ```ini
   [Interface]
   PrivateKey = ...
   Address = 10.5.0.2/32
   DNS = 103.86.96.100

   [Peer]
   PublicKey = ...
   Endpoint = <server_ip>:51820
   AllowedIPs = 0.0.0.0/0, ::/0
   PersistentKeepalive = 25
   ```
4. **Writes the file** as `<hostname>_wireguard.conf` (unless `-NoConf`), then prints it and shows it as a QR code (unless `-NoQr`) for quick import into the WireGuard mobile app via **Add Tunnel → Scan from QR code**.

## The QR code

QR rendering uses QR Coder (https://github.com/codebude/QRCoder), a compiled .NET library downloaded once from `nuget.org` and cached at `%LOCALAPPDATA%\QRCoderCache`. It's loaded as a binary assembly via `Add-Type` rather than installed as a PowerShell module, specifically to avoid Windows Defender/AMSI flagging PowerShell-script-based QR modules (a known false-positive pattern with some PSGallery QR generators).

## Security notes

- **Your access token is a credential.** Anyone who has it can retrieve your NordLynx private key. Don't commit this script to a shared repo or cloud-synced folder with your token filled in.
- **The generated config (and its QR code) contain your private key in plaintext.** Anyone who can read the `.conf` file, see your screen, or scroll back through your terminal history can use it to connect as you. Run `cls`/`Clear-Host` after scanning if that's a concern.
- **Rotate your token** periodically, especially after testing/sharing it, at the same [access token page](https://my.nordaccount.com/dashboard/nordvpn/access-token/).
- Consider setting `-OutputPath` to somewhere outside of cloud-synced folders (OneDrive, Dropbox, etc.) if you do keep `.conf` files on disk.

## Known limitations

- NordVPN's location data is **city-level only** — there's no "state" filter. To target a US state, use whichever NordVPN city is in it.
- City name matching is exact (case-sensitive-ish via NordVPN's own naming) — if `-City` returns "No WireGuard-capable servers found," check the spelling against [nordvpn.com/servers](https://nordvpn.com/servers/).
- I notice that you drop the City in names of cieis, example New York City will be New York, and Mexico City will be Mexico, etc.
- The country + city and hostname modes fetch NordVPN's full server list (~16,000 entries) on every run rather than caching it, so those modes take a few seconds longer than the country-only recommendation mode.
