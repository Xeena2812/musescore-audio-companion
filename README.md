# MuseScore Audio Companion

A MuseScore 4 plugin that plays an external audio file in sync with score playback. Useful for following along with a recording while reading the score — rehearsal tracks, backing tracks, reference recordings, and so on.

## Features

- Load an audio file (MP3, WAV, OGG, FLAC) per score
- Play/Pause/Stop/Rewind drives both MuseScore and the audio simultaneously
- ±3 s / ±10 s skip buttons and a seekable progress bar
- Configurable ms-level delay offset so the audio and score stay in sync
- Volume control
- Remembers which audio file belongs to each score

## Requirements

- **MuseScore Studio 4** (developed and tested on 4.6.5)
- **VLC media player** — `sudo apt install vlc`
- **Linux** (developed on Ubuntu with snap-installed MuseScore; other platforms untested)

## Installation

**1. Copy the plugin files**

```bash
cp AudioCompanion.qml start-vlc-server.sh ~/Documents/MuseScore4/Plugins/
```

**2. Enable the plugin in MuseScore**

Plugins → Manage Plugins → find *Audio Companion* → check the box → Close

## Usage

**1. Start the VLC server**

The plugin delegates audio playback to a headless VLC instance controlled over HTTP. Start it once before using the plugin and keep the terminal open:

```bash
~/Documents/MuseScore4/Plugins/start-vlc-server.sh
```

Custom port and password are supported:

```bash
./start-vlc-server.sh 9090 mypassword
```

**2. Open the plugin**

Plugins → Audio Companion

The plugin will try to connect to VLC automatically. If the status bar shows *VLC not running*, check that the server script is running.

**3. Load an audio file**

Click **Load Audio…** and select your file. The plugin remembers your choice per score.

**4. Play**

Press ▶ — both the score and the audio start together. Use the **Offset** spinner to adjust sync in milliseconds (positive = audio starts after the score, negative = audio starts before).

## Why VLC?

MuseScore 4 installed via snap does not have a working GStreamer backend for Qt's built-in `QMediaPlayer`. The plugin works around this by talking to VLC's HTTP remote-control API instead of playing audio directly.

## License

MIT
