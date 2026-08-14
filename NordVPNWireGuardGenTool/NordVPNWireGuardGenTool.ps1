<#
.SYNOPSIS
    Generates a NordVPN WireGuard config, using your own NordVPN account access token.

.DESCRIPTION
    1. Get your access token:
       https://my.nordaccount.com/dashboard/nordvpn/access-token/f
       Click "Generate new token" and copy it.

    2. Run this script one of these ways:
       .\New-NordVpnWireGuardConfig.ps1 -ServerHostname "us12223.nordvpn.com"
       .\New-NordVpnWireGuardConfig.ps1 -CountryCode "CA"
       .\New-NordVpnWireGuardConfig.ps1 -CountryCode "US" -City "Houston"
       .\New-NordVpnWireGuardConfig.ps1 -CountryCode "US" -City "Houston" -NoConf

.PARAMETER AccessToken
    Your NordVPN account access token (treat like a password).

.PARAMETER ServerHostname
    A specific NordVPN server hostname, e.g. us12223.nordvpn.com. Use this OR
    -CountryCode (optionally with -City), not both.

.PARAMETER CountryCode
    A 2-letter country code (e.g. US, CA, DE). Alone, gets NordVPN's recommended
    (lowest-load, nearest) WireGuard server in that country. Combine with -City
    to narrow to a specific city.

.PARAMETER City
    A city name (e.g. "Houston", "Bogota"). Must be used together with -CountryCode.
    Picks the lowest-load matching server in that city. NordVPN's location data
    is city-level only -- there's no separate "state" filter.

.PARAMETER OutputPath
    Optional. Where to write the .conf file (if not skipped). Defaults to current directory.

.PARAMETER NoQr
    Optional. Skip rendering the QR code in the console.

.PARAMETER NoConf
    Optional. Don't write a .conf file to disk at all. Config is still printed
    to console and/or shown as a QR code (unless -NoQr is also set).

.NOTES
    SECURITY: This script has a hardcoded default access token below for convenience.
    Anyone who can read this file can read your token, and anyone with the token can
    pull your WireGuard private key. Keep this file out of cloud-synced folders, git
    repos, or anywhere else with broader access than just you.

    The QR code (and the printed config) both encode your PrivateKey in the clear.
    Anyone who can see your screen or terminal scrollback can scan/read it and use
    your tunnel. Clear your terminal (cls) after scanning if that's a concern.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AccessToken,

    [Parameter(Mandatory = $false)]
    [string]$ServerHostname,

    [Parameter(Mandatory = $false)]
    [string]$CountryCode,

    [Parameter(Mandatory = $false)]
    [string]$City,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$NoQr,

    [Parameter(Mandatory = $false)]
    [switch]$NoConf
)

if ([string]::IsNullOrWhiteSpace($ServerHostname) -and [string]::IsNullOrWhiteSpace($CountryCode)) {
    throw "Specify either -ServerHostname (e.g. us12223.nordvpn.com) or -CountryCode (e.g. US)."
}

if (-not [string]::IsNullOrWhiteSpace($ServerHostname) -and -not [string]::IsNullOrWhiteSpace($CountryCode)) {
    throw "Specify only one of -ServerHostname or -CountryCode, not both."
}

if (-not [string]::IsNullOrWhiteSpace($City) -and [string]::IsNullOrWhiteSpace($CountryCode)) {
    throw "-City requires -CountryCode as well (e.g. -CountryCode US -City Houston)."
}

# --- Set your default access token here ---
# Generate one at: https://my.nordaccount.com/dashboard/nordvpn/access-token/
$DefaultAccessToken = "PASTE_YOUR_ACCESS_TOKEN_HERE"

if (-not $PSBoundParameters.ContainsKey('AccessToken')) {
    $AccessToken = $DefaultAccessToken
}

if ([string]::IsNullOrWhiteSpace($AccessToken) -or $AccessToken -eq "PASTE_YOUR_ACCESS_TOKEN_HERE") {
    throw "No access token set. Either edit `$DefaultAccessToken` at the top of this script, or pass -AccessToken explicitly."
}

$ErrorActionPreference = "Stop"

function Get-NordVpnPrivateKey {
    param([string]$Token)

    $pair = "token:$Token"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $basicAuth = [System.Convert]::ToBase64String($bytes)

    $headers = @{ Authorization = "Basic $basicAuth" }

    Write-Host "Fetching your WireGuard private key..."
    $response = Invoke-RestMethod -Uri "https://api.nordvpn.com/v1/users/services/credentials" -Headers $headers -Method Get

    if (-not $response.nordlynx_private_key) {
        throw "Failed to retrieve private key. Check that your access token is valid."
    }

    return $response.nordlynx_private_key
}

function Get-NordVpnCountryId {
    param(
        [string]$Code,
        [string]$City
    )

    Write-Host "Looking up country id for '$Code'..."
    $countries = Invoke-RestMethod -Uri "https://api.nordvpn.com/v1/servers/countries" -Method Get

    $country = $countries | Where-Object { $_.code -eq $Code.ToUpper() } | Select-Object -First 1

    if (-not $country) {
        throw "No NordVPN country found matching code: $Code"
    }

    } else {
        Write-Host "Matched: $($country.name) (country_id $($country.id))"
    }

    return $country.id
}

function Get-NordVpnRecommendedServer {
    param([int]$CountryId)

    Write-Host "Fetching recommended WireGuard server..."
    $uri = "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=$CountryId&filters[servers_technologies][identifier]=wireguard_udp&limit=1"
    $servers = Invoke-RestMethod -Uri $uri -Method Get

    if (-not $servers -or $servers.Count -eq 0) {
        throw "No recommended WireGuard server found for country_id $CountryId."
    }

    $server = $servers[0]
    $wgTech = $server.technologies | Where-Object { $_.identifier -eq "wireguard_udp" }
    $publicKeyMeta = $wgTech.metadata | Where-Object { $_.name -eq "public_key" }

    if (-not $publicKeyMeta) {
        throw "Could not find WireGuard public key for recommended server $($server.hostname)."
    }

    $city = ($server.locations | Select-Object -First 1).country.city.name
    Write-Host "Recommended: $($server.hostname) in $city (load $($server.load)%)"

    return [PSCustomObject]@{
        Hostname  = $server.hostname
        PublicKey = $publicKeyMeta.value
        IpAddress = $server.station
    }
}

function Get-NordVpnServerByLocation {
    param(
        [string]$CountryCode,
        [string]$City
    )

    Write-Host "Looking up servers in $City, $CountryCode..."

    # NordVPN's recommendations endpoint doesn't reliably support a city-level
    # filter, so we pull the full server list and filter client-side on both
    # country code and city name, then pick the lowest-load match ourselves.
    $uri = "https://api.nordvpn.com/v1/servers?limit=16384"
    $servers = Invoke-RestMethod -Uri $uri -Method Get

    $matched = $servers | Where-Object {
        $loc = $_.locations | Select-Object -First 1
        $loc -and
        $loc.country.code -eq $CountryCode.ToUpper() -and
        $loc.country.city.name -eq $City -and
        ($_.technologies | Where-Object { $_.identifier -eq "wireguard_udp" })
    }

    if (-not $matched -or $matched.Count -eq 0) {
        throw "No WireGuard-capable servers found in '$City, $CountryCode'. Check the spelling/casing matches NordVPN's city name exactly."
    }

    $best = $matched | Sort-Object load | Select-Object -First 1

    $wgTech = $best.technologies | Where-Object { $_.identifier -eq "wireguard_udp" }
    $publicKeyMeta = $wgTech.metadata | Where-Object { $_.name -eq "public_key" }

    Write-Host "Picked: $($best.hostname) (load $($best.load)%) out of $($matched.Count) matching servers"

    return [PSCustomObject]@{
        Hostname  = $best.hostname
        PublicKey = $publicKeyMeta.value
        IpAddress = $best.station
    }
}

function Get-NordVpnServerInfo {
    param([string]$Hostname)

    Write-Host "Looking up server details for $Hostname..."

    # NordVPN's API has no direct hostname filter parameter, so we pull the full
    # server list and filter client-side. limit=16384 comfortably covers the
    # full server count.
    $uri = "https://api.nordvpn.com/v1/servers?limit=16384"
    $servers = Invoke-RestMethod -Uri $uri -Method Get

    $server = $servers | Where-Object { $_.hostname -eq $Hostname } | Select-Object -First 1

    if (-not $server) {
        throw "No server found matching hostname: $Hostname"
    }

    $wgTech = $server.technologies | Where-Object { $_.identifier -eq "wireguard_udp" }

    if (-not $wgTech) {
        throw "Server $Hostname does not support WireGuard."
    }

    $publicKeyMeta = $wgTech.metadata | Where-Object { $_.name -eq "public_key" }

    if (-not $publicKeyMeta) {
        throw "Could not find WireGuard public key for $Hostname."
    }

    $city = ($server.locations | Select-Object -First 1).country.city.name
    Write-Host "Matched: $($server.hostname) in $city"

    return [PSCustomObject]@{
        Hostname  = $server.hostname
        PublicKey = $publicKeyMeta.value
        IpAddress = $server.station
    }
}

function Show-QrCode {
    param([string]$Content)

    $qrCoderVersion = "1.6.0"
    $cacheDir = Join-Path $env:LOCALAPPDATA "QRCoderCache"
    $dllPath = Join-Path $cacheDir "QRCoder.dll"

    if (-not (Test-Path $dllPath)) {
        Write-Host "Fetching QRCoder library (one-time download, cached at $cacheDir)..."
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

        $nupkgUrl = "https://www.nuget.org/api/v2/package/QRCoder/$qrCoderVersion"
        $nupkgPath = Join-Path $cacheDir "QRCoder.$qrCoderVersion.zip"

        try {
            Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgPath -UseBasicParsing

            $extractDir = Join-Path $cacheDir "extract"
            Expand-Archive -Path $nupkgPath -DestinationPath $extractDir -Force

            $found = Get-ChildItem -Path (Join-Path $extractDir "lib") -Recurse -Filter "QRCoder.dll" |
                Sort-Object { $_.Directory.Name -eq "netstandard2.0" } -Descending |
                Select-Object -First 1

            if (-not $found) {
                throw "Could not locate QRCoder.dll inside the downloaded package."
            }

            Copy-Item -Path $found.FullName -Destination $dllPath -Force
            Remove-Item -Path $nupkgPath, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "Could not download/prepare QRCoder: $($_.Exception.Message)"
            Write-Warning "Skipping QR code."
            return
        }
    }

    try {
        Add-Type -Path $dllPath

        $qrGenerator = New-Object QRCoder.QRCodeGenerator
        $qrCodeData = $qrGenerator.CreateQrCode($Content, [QRCoder.QRCodeGenerator+ECCLevel]::Q)
        $asciiQr = New-Object QRCoder.AsciiQRCode($qrCodeData)

        Write-Host ""
        Write-Host "Scan with the WireGuard app (Add Tunnel > Scan from QR code):"
        Write-Host ""
        Write-Host $asciiQr.GetGraphicSmall()
        Write-Host ""
    } catch {
        Write-Warning "Failed to render QR code: $($_.Exception.Message)"
    }
}

# --- Main ---

$privateKey = Get-NordVpnPrivateKey -Token $AccessToken

if ($City) {
    $null = Get-NordVpnCountryId -Code $CountryCode -City $City
    $serverInfo = Get-NordVpnServerByLocation -CountryCode $CountryCode -City $City
} elseif ($CountryCode) {
    $countryId = Get-NordVpnCountryId -Code $CountryCode
    $serverInfo = Get-NordVpnRecommendedServer -CountryId $countryId
} else {
    $serverInfo = Get-NordVpnServerInfo -Hostname $ServerHostname
}

$configContent = @"
[Interface]
PrivateKey = $privateKey
Address = 10.5.0.2/32
DNS = 103.86.96.100

[Peer]
PublicKey = $($serverInfo.PublicKey)
Endpoint = $($serverInfo.IpAddress):51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"@

if (-not $NoConf) {
    $shortName = ($serverInfo.Hostname -split '\.')[0]
    $outFile = Join-Path -Path $OutputPath -ChildPath "$shortName`_wireguard.conf"
    Set-Content -Path $outFile -Value $configContent -NoNewline
    Write-Host "Config written to: $outFile"
} else {
    Write-Host "Skipping .conf file (-NoConf specified)."
}

Write-Host ""
Write-Host $configContent

if (-not $NoQr) {
    Show-QrCode -Content $configContent
}
