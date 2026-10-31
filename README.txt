Spotify Display - controls helper
=================================

Adds play/pause, previous/next, shuffle, repeat, seeking and a Spotify volume
slider to the "Spotify Display" wallpaper for Wallpaper Engine.

Install
  1. Extract this folder somewhere you keep it, e.g. Documents\SpotifyDisplay-Controls
  2. Double-click install.cmd
  3. Re-select the wallpaper in Wallpaper Engine

Remove
  Double-click uninstall.cmd, then delete the folder.

What it does
  A small PowerShell script (spotify-helper.ps1) runs hidden in the background.
  It reads what Spotify is playing through the Windows media controls, can
  control playback and Spotify's volume (Windows volume mixer), and fetches
  lyrics from lrclib.net, with NetEase Cloud Music and lyrics.ovh as backups
  when lrclib is down or doesn't have the song. Lyrics it found are kept in
  %LOCALAPPDATA%\SpotifyDisplay\lyrics so they also work when those sites are
  down. It only listens on your own PC (http://localhost:5757) and is plain
  text, so you can read exactly what it does.

Files
  spotify-helper.ps1  the helper itself
  AppVolume.cs        Spotify volume through the Windows audio API
  start-helper.vbs    starts the helper without a console window
  install / uninstall adds or removes the helper from Windows startup
