# Reel

An Infuse-style iPhone player for the movies and TV on the Nomad router's SMB
share (a mirror of Bucket_A). It connects straight to the share, so there's no
server software involved: the app lists the folders itself, looks titles up on
TMDB, and plays the files with VLC. Nothing is transcoded.

- **Library:** Home (Keep Watching, Recently Added), plus a poster grid per library
- **Watch progress on the share:** where you got to in each video is kept in a hidden `.reel/progress` folder on
  the share, so every phone running Reel (or a reinstall) resumes in the same place and shows the same Keep Watching.
  Each install writes its own file and the newest entry wins, so the SMB login needs write access.
- **Detail pages:** movie and show pages with seasons, episode stills and descriptions
- **Thumbnails:** anything without a TMDB poster or episode still shows a frame from the video itself. Frames are
  taken one at a time, wait while a scan or playback is running, and are cached, so each file is only read once.
  A show tries an episode still, then frames from its first three episodes; an episode with no readable frame uses the
  show's backdrop. If nothing loads at all, a title card is generated, so every show and episode has a picture.
- **Playback:** resume and watch progress, autoplay of the next episode, audio and subtitle track choice. Sidecar `.srt` files from Bazarr are picked up automatically.
- **Formats:** everything on Bucket_A plays: MKV/MP4/WebM/AVI, H.264/HEVC/AV1/Xvid, DTS/E-AC3/Opus, and SRT/ASS/PGS/DVD subtitles.

## Install on your iPhone (free Apple ID)

1. Install Xcode from the Mac App Store and open it once.
2. Clone this repo and open `Reel.xcodeproj`. The first open downloads VLCKit (a few hundred MB), so give it a minute.
3. In Xcode, sign in: Xcode → Settings → Accounts → **+** → Apple ID.
4. Click the **Reel** target → **Signing & Capabilities** and set Team to "*your name* (Personal Team)".
   If it complains the bundle ID is taken, change `me.eamonmurphy.reel` to anything unique.
5. Plug the iPhone in and pick it as the run destination at the top of the window.
6. On the iPhone, go to Settings → Privacy & Security → **Developer Mode**, turn it on and restart.
7. Press **Run** (⌘R). The first time, the phone will refuse to open it. Go to Settings → General →
   VPN & Device Management, tap your Apple ID and **Trust** it, then run again.
8. When Reel asks to find devices on your local network, allow it. Without that it can't reach the router.

With a free Apple ID the install expires after **7 days**. Plug in and press Run again to renew it;
your library and watch progress are kept.

## Set up in the app

Open the Settings tab:

- **SMB server:** the router's IP (e.g. `192.168.8.1`), the share name, and the SMB username and password.
  Tap **Test Connection** with the share left empty to see which shares the router offers.
- **Libraries:** these default to `movies`, `TV` and `childrens-shows`, the Bucket_A folder names. Change them
  if the share on the router is laid out differently. The folder button lists what's actually there once
  Test Connection has succeeded.
- **TMDB:** optional, for posters, descriptions and episode names. It's free: make an account at
  themoviedb.org, then go to Settings → API and paste either the API key or the read access token.
  The Kids library has TMDB off because its YouTube "episodes" aren't real episode numbers.

Then **Scan Now**. The first scan with TMDB takes a minute or so; after that only new files are looked up.
The app rescans on its own when opened, at most every 15 minutes, and you can pull down on any screen to
rescan.

## Checking the share from the Mac

`reelscan` runs the app's scanner in a terminal. Use it to check the router's share and folder layout
without building the app:

```sh
cd Packages/ReelCore
swift run reelscan --host 192.168.8.1 --share media --user USER --password PASS \
  --movies movies --shows TV --shows childrens-shows
```

It prints what it found, plus anything it couldn't name properly. Add `--all` to list everything.

## Layout

```
project.yml            XcodeGen spec (Reel.xcodeproj is generated from it)
Reel/                  the iOS app: SwiftUI + SwiftData
  Model/               settings, SwiftData models, scan/TMDB sync, artwork cache
  Player/              VLCKit wrapper and the player screen
  Views/               Home, library grids, detail pages, Settings
Packages/ReelCore/     no UI, builds on Linux too
  NameParser           release names → titles, years, SxxEyy, subtitle languages
  LibraryScanner       walks a library folder into movies / shows / episodes
  SMBFileSource        AMSMB2 wrapper; builds the smb:// URLs VLC plays
  TMDB                 search and season lookups
```

After editing `project.yml`, regenerate the project with `brew install xcodegen && xcodegen`.

## Known limits

- **HDR:** HDR10 and Dolby Vision files play, but VLC tone-maps them to SDR.
- **Atmos:** Atmos tracks play as regular 5.1/stereo.
- **Remote playback:** away from the router's network you'd need a VPN into it, and enough upload
  bandwidth at the Nomad end for the file's bitrate, since there's no transcoding to fall back on.
- **SMB version:** VLC's SMB client needs SMB2 or later on the router, not SMB1.
