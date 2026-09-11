param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$LocalFile,
    [string]$RemoteFile = "/home/vehicle_course",
    [string]$PortName = "",
    [int]$Baud = 115200,
    [switch]$Install,
    [switch]$Run
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $here "gec-serial.ps1") -Action xfer -LocalFile $LocalFile -RemoteFile $RemoteFile -PortName $PortName -Baud $Baud -Install:$Install -Run:$Run
exit $LASTEXITCODE
