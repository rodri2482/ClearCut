<div align="center">

<img src="assets/icon/app_icon.png" width="120" alt="ClearCut" />

# ClearCut

**Anime, movies and series in one app. No ads.**

Stream and download anime episodes, anime movies, TV series and movies. A built-in ad blocker keeps the web player free of ads, pop-ups and redirects.

![Android](https://img.shields.io/badge/Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![License](https://img.shields.io/badge/License-GPL--3.0-FF4D57?style=for-the-badge)

</div>

## Features

- **Anime, movies and series**: browse, search, track and play from one place.
- **Watch ad-free**: the NoFlix web player opens any movie or show by its TMDB id. An AdGuard / EasyPrivacy ad blocker with a native engine removes ads, pop-ups, trackers and redirects.
- **Downloads**: save episodes and movies (including HLS streams with subtitles) for offline viewing. Downloads keep running in the background.
- **Built-in free sources** that work with no setup:
  - **Internet Archive (free films)**: public-domain classics such as sci-fi and horror, comedy and the silent era, played straight from archive.org's MP4 files in up to 1080p.
  - **Project Gutenberg (free books)**: over 70,000 public-domain books with covers, split into chapters, in the Novel reader. If gutenberg.org is down, they load from the official PGLAF mirror.
- **Gestures in the ad-free player**: swipe left or right to seek, swipe up or down on the right for volume and on the left for brightness. The native player also has double-tap seek and pinch-to-zoom.
- **Extensions**: add Aniyomi, CloudStream, Stremio and Mihon extension repositories from **Settings → Extensions**. ClearCut ships with no third-party repositories. You choose which ones to add.
- **Manga and light novels**: separate reading modes with their own readers.
- **Android TV**: a full remote-friendly interface.
- **Private**: no account, no analytics, and no developer servers. History, library and downloads stay on your device.

## Download

Grab the APK for your phone from the [Releases](../../releases) page:

| File | For |
| --- | --- |
| `app-arm64-v8a-release.apk` | Almost every phone from the last 7 years. **Pick this one if unsure.** |
| `app-armeabi-v7a-release.apk` | Older 32-bit phones and some Android TV boxes |
| `app-x86_64-release.apk` | Emulators and x86 Chromebooks |

## Build

Requirements: Flutter 3.44.7, JDK 17, Android SDK. AGP downloads NDK r28c and CMake 3.22.1 itself for the ad-block engine.

```bash
flutter pub get
ZANGETSU_NO_DISCORD=1 flutter build apk --debug
```

`ZANGETSU_NO_DISCORD=1` skips the proprietary Discord SDK, which isn't in this repo.

**Signed release APKs.** Copy `android/key.properties.example` to `android/key.properties` and point it at your keystore. Then run:

```bash
ZANGETSU_NO_DISCORD=1 flutter build apk --release --split-per-abi
```

Without `key.properties`, release builds fall back to debug signing. Never commit the keystore or `key.properties`. Both are git-ignored.

**Windows:** build from a short path such as `C:\Users\you\ClearCut`. The dependency tree exceeds Windows' 260-character path limit when the project is nested deep. Also run `git config --global core.longpaths true` once before `flutter pub get`.

**GitHub Actions:** `.github/workflows/build.yml` builds the APK when started by hand from the Actions tab. Pushing a `v*` tag publishes a release. See the comments in that file for the signing secrets it needs.

## Disclaimer

ClearCut doesn't host any content. It plays media from sources you add or from third-party websites. Whether that's legal depends on where you live and on the content, so you're responsible for what you watch.

## License

ClearCut is free software under the [GNU General Public License v3.0](LICENSE).
It is a modified version of [Zangetsu](https://github.com/Spyou/Zangetsu) (GPL-3.0) and includes the ad-free player and ad-block modules from [NoFlix](https://github.com/zobaer53/NoFlix) (Apache-2.0).
See [NOTICE.md](NOTICE.md) for the full list of components and their licenses.
