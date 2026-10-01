# Reel

An iPhone and iPad player for the movies and TV on the Nomad router's SMB
share (a mirror of Bucket_A). It connects straight to the share, so there's no
server software involved: the app lists the folders itself, looks titles up on
TMDB, and plays the files with VLC. Nothing is transcoded. It can use a WebDAV
server instead of SMB, e.g. Nextcloud, a Synology or QNAP NAS, or `rclone serve webdav`.

- **Library:** Home (Keep Watching, Recently Added), plus a poster grid per library with its own Keep Watching row
- **Collections:** tabs that gather movies and shows from any library by filters: age rating, genre (or not in a
  genre), library, year, TMDB rating and length, matching any or all of them. A **Kids & Family** collection is there to
  start with. The ••• menu on a movie or show page adds it to or removes it from a collection by hand, whatever the
  filters say. Collections are set up in Settings or from the filter button on their tab, and are kept on this device.
- **Tabs:** Settings → Tabs shows or hides each library's and collection's tab. A hidden library is still scanned and
  still shows on Home.
- **Watch progress on the share:** where you got to in each video is kept in a hidden `.reel/progress` folder on
  the share, so every phone running Reel (or a reinstall) resumes in the same place and shows the same Keep Watching.
  Each install writes its own file and the newest entry wins, so the SMB login needs write access.
- **Detail pages:** movie and show pages with a full-width backdrop fading into a page tinted by the artwork, the title
  logo, genres, age and TMDB ratings, cast with photos, directors or creators, seasons, episode stills and descriptions.
  Tap anyone in the cast for their photo, biography and everything in the library they're in. **More Like This** picks
  from the library, TMDB's recommendations first, then titles sharing the most genres (or, for YouTube downloads with
  no TMDB match, the rest of that library). Cast, genres and recommendations for the whole library come from TMDB during
  the scan, one request per title the first time, and are kept, so all of this works offline too.
- **Thumbnails:** anything without a TMDB poster or episode still shows a frame from the video itself. Frames are
  taken one at a time, wait while a scan or playback is running, and are cached, so each file is only read once.
  They're saved in a hidden `.reel/frames` folder on the share too, so once one phone has a video's frame, every other
  phone (or a reinstall) loads that small JPEG instead of reading the video again. Turn off **Video Thumbnails → Save
  on the Share** in Settings to keep them on the phone only.
  A show tries an episode still, then frames from its first three episodes; an episode with no readable frame uses the
  show's backdrop. If nothing loads at all, a title card is generated, so every show and episode has a picture.
- **Playback:** resume and watch progress, autoplay of the next episode, audio and subtitle track choice. Sidecar `.srt` files from Bazarr are picked up automatically.
  The subtitles menu can also add a file to the playing video, from anywhere on the share or from the Files app;
  it's kept on the phone and loads again whenever that video plays.
- **iPad:** bigger posters, episodes side by side, and any orientation, Split View or Stage Manager. The player
  doesn't force landscape there, and a keyboard works: space plays and pauses, ← and → skip, Esc closes.
- **Offline:** artwork from TMDB is saved on the device during scans, so the library looks the same with no
  internet, e.g. on the router's own WiFi on a plane. A scan with no internet still counts; TMDB lookups wait until
  there's a connection. Playback pauses if the headphones disconnect.
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

## Install with SideStore

[SideStore](https://sidestore.io) re-signs apps with your Apple ID and refreshes them from the phone, so
there's no need to plug in every 7 days.

1. In SideStore, open **Sources** → **+** and add
   `https://github.com/eamonflanaganmurphy/reel/releases/latest/download/source.json`
2. Open the Reel source and tap **Get**. SideStore signs Reel with your Apple ID and installs it.
3. Allow local network access when Reel asks, then set it up as below.

Every push to `main` that builds and passes the tests is released as a new version, and SideStore
offers it under **My Apps** → **Updates**. Your library and watch progress are kept.
A free Apple ID allows 3 sideloaded apps at once, and SideStore itself uses one of them.

To install a local build instead, run `./scripts/build-ipa.sh`, AirDrop `build/Reel.ipa` to the
iPhone, and pick it in SideStore under **My Apps** → **+**.

## Set up in the app

Tap the gear at the top of Home to open Settings:

- **Server:** pick **SMB** or **WebDAV**, then:
  - **SMB:** the router's IP (e.g. `192.168.8.1`), the share name, and the SMB username and password.
    Tap **Test Connection** with the share left empty to see which shares the router offers.
  - **WebDAV:** the server's WebDAV address including any folder, e.g. `http://192.168.8.1/webdav` or
    `https://cloud.example.com/remote.php/dav/files/USER`, and its username and password. With no `http://` or
    `https://`, Reel uses http for an IP address or `.local` name and https for anything else.
  Library folders, watch progress and artwork are all relative to the share, so pointing WebDAV at the same folder
  the SMB share holds keeps the library and everyone's progress as they were.
- **Libraries:** these default to `movies`, `TV` and `childrens-shows`, the Bucket_A folder names. Change them
  if the share on the router is laid out differently. The folder button lists what's actually there once
  Test Connection has succeeded.
- **TMDB:** optional, for posters, descriptions and episode names. It's free: make an account at
  themoviedb.org, then go to Settings → API and paste either the API key or the read access token.
  The Kids library has TMDB off because its YouTube "episodes" aren't real episode numbers.

Then **Scan Now**. The first scan with TMDB takes a minute or so; after that only new files are looked up.
The app rescans on its own when opened, at most every 15 minutes, and you can pull down on any screen to
rescan.

## On a plane (the router's own WiFi)

- Set **Address** to `192.168.8.1`, the router's LAN address, not its Tailscale one: over Tailscale the router
  encrypts every byte of video, which its CPU can't keep up with.
- Open Reel with internet first and let a scan finish, so the artwork is saved for offline.
- Join the router's **5 GHz** network if you have the choice. The library tops out at 15 Mbit/s, so two streams need
  about 30 Mbit/s at most.

## Checking the share from the Mac

`reelscan` runs the app's scanner in a terminal. Use it to check the router's share and folder layout
without building the app:

```sh
cd Packages/ReelCore
swift run reelscan --host 192.168.8.1 --share media --user USER --password PASS \
  --movies movies --shows TV --shows childrens-shows
```

It prints what it found, plus anything it couldn't name properly. Add `--all` to list everything.
For a WebDAV server, use `--webdav http://192.168.8.1/webdav` in place of `--host` and `--share`.

## Layout

```
project.yml            XcodeGen spec (Reel.xcodeproj is generated from it)
scripts/build-ipa.sh   builds an unsigned build/Reel.ipa for SideStore
sidestore/source.json  the SideStore source; CI fills in each release's version
Reel/                  the iOS app: SwiftUI + SwiftData
  Model/               settings, SwiftData models, scan/TMDB sync, artwork cache
  Player/              VLCKit wrapper and the player screen
  Views/               Home, library grids, detail pages, Settings
Packages/ReelCore/     no UI, builds on Linux too
  NameParser           release names → titles, years, SxxEyy, subtitle languages
  LibraryScanner       walks a library folder into movies / shows / episodes
  ShareConfig          server settings, errors, and the smb:// or http(s):// URLs VLC plays
  SMBFileSource        AMSMB2 wrapper
  WebDAVFileSource     WebDAV over URLSession: PROPFIND listings, ranged reads, progress writes
  TMDB                 search and season lookups
```

After editing `project.yml`, regenerate the project with `brew install xcodegen && xcodegen`.

## Known limits

- **HDR:** HDR10 and Dolby Vision files play, but VLC tone-maps them to SDR.
- **Atmos:** Atmos tracks play as regular 5.1/stereo.
- **Remote playback:** away from the router's network you'd need a VPN into it, and enough upload
  bandwidth at the Nomad end for the file's bitrate, since there's no transcoding to fall back on.
- **SMB version:** VLC's SMB client needs SMB2 or later on the router, not SMB1.
- **WebDAV over https:** the server needs a certificate iOS trusts. A NAS's self-signed one won't do;
  use http on your own network, or a real certificate (e.g. Tailscale's `tailscale cert`).
