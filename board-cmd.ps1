param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [int]$WaitMs = 2000,
    [string]$PortName = "",
    [int]$Baud = 115200
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $here "gec-serial.ps1") -Action cmd -Command $Command -WaitMs $WaitMs -PortName $PortName -Baud $Baud
exit $LASTEXITCODE
