# Removes the Spotify Display controls helper: stops it and removes it from startup.

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Spotify Wallpaper Helper.lnk'
if (Test-Path $lnk) { Remove-Item $lnk }

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*spotify-helper.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Write-Host ''
Write-Host 'Spotify Display controls removed. You can delete this folder now.' -ForegroundColor Green
