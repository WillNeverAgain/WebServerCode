[CmdletBinding()]
param()

& "$PSScriptRoot\stop-cloudflared.ps1"
& "$PSScriptRoot\start-cloudflared.ps1" -Background
