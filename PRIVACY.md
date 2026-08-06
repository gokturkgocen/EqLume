# Eqlume Privacy Policy

Last updated: July 21, 2026

Eqlume is a system-wide equalizer for macOS. The app is designed to process audio locally and minimize the data it handles.

## Audio processing

Eqlume requests Audio Recording permission so it can capture system audio, apply equalization, and immediately play the processed signal through the active output device. Audio is processed in memory on the Mac. Eqlume does not record audio to disk, upload audio, or share audio with the developer or third parties.

## Now-playing information

When automatic preset selection is enabled, Eqlume may read the title, artist, playback state, and album artwork of the media currently playing in supported apps and browsers. Depending on the selected integration, this information may be obtained through macOS Automation, the Spotify Web API, MusicBrainz, or the Apple iTunes Search API.

Track and artist names may be sent to MusicBrainz and the Apple iTunes Search API to look up genre and artwork metadata. These services process requests under their own privacy policies and terms. Eqlume does not operate an analytics or tracking server and the developer does not receive these requests.

In builds that include the optional local classifier, Eqlume can analyze a short audio window when online catalog lookup does not identify a track. This classification occurs entirely on the Mac and no audio is transmitted. The Mac App Store build does not include this classifier and falls back to a general sound profile instead.

## Spotify integration

Spotify integration is optional. Users provide their own Spotify Client ID and authorize access through Spotify OAuth. Access and refresh tokens are stored in the macOS Keychain. Eqlume uses them to read current playback and queue information. Disconnecting Spotify from Eqlume removes the stored access and refresh tokens; the non-secret Client ID remains locally stored to make reconnection easier.

## Storage

Eqlume stores language, preset, automatic-mode, and launch-at-login preferences locally. Spotify credentials and tokens are stored in the macOS Keychain. The app does not include advertising, third-party analytics, behavioral tracking, or a developer-operated cloud account.

## Data retention and deletion

Eqlume does not retain audio recordings or maintain a developer-accessible user database. Local preferences can be removed by deleting the app's container or preferences. Spotify credentials can be deleted by using the disconnect action in Eqlume or Keychain Access.

## Contact

Questions and privacy requests can be submitted through the public project support page:

https://github.com/gokturkgocen/Eqlume/issues

## Changes

Material changes to this policy will be published in this file with an updated revision date.
