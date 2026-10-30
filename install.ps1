# Installs the Spotify Display controls helper for the current user:
# starts it now and every time you log in (shortcut in the Startup folder).

$launcher = Join-Path $PSScriptRoot 'start-helper.vbs'

$startup = [Environment]::GetFolderPath('Startup')
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startup 'Spotify Wallpaper Helper.lnk'))
$sc.TargetPath = 'wscript.exe'
$sc.Arguments = "`"$launcher`""
$sc.WorkingDirectory = $PSScriptRoot
$sc.Save()

# the helper exits by itself if it's already running
Start-Process wscript.exe "`"$launcher`""

Write-Host ''
Write-Host 'Spotify Display controls installed.' -ForegroundColor Green
Write-Host 'The helper now runs in the background and starts automatically when you log in.'
Write-Host 'Re-select the wallpaper in Wallpaper Engine to see the controls.'
Write-Host 'Keep this folder where it is; to remove the helper, run uninstall.cmd.'
