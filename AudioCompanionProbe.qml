import MuseScore
import QtQuick
import QtQuick.Controls
import QtMultimedia

// Probe: can QtMultimedia replace VLC? Loads a file, plays it, seeks to several
// positions and shows seek latency/accuracy and playback drift on screen.
MuseScore {
    id: root
    title: "Audio Companion Probe"
    description: "QtMultimedia seek/playback probe (not the real plugin)"
    version: "0.1"
    pluginType: "dialog"
    width: 560
    height: 640

    property string path: ""
    property string log: ""
    property var targets: [0, 5000, 30000, 60000, 10000, 90000, 2000]
    property int ti: -1
    property double tStart: 0
    property double driftWall: 0
    property int driftPos: 0

    function say(s) { log += s + "\n" }
    onRun: say("Qt " + Qt.platform.os + "; pick a file, then Run probe")

    MediaPlayer {
        id: mp
        audioOutput: AudioOutput { id: ao }
        onErrorOccurred: (e, s) => root.say("ERROR " + e + ": " + s)
        onMediaStatusChanged: root.say("status " + mediaStatus + " dur=" + duration + "ms seekable=" + seekable + " hasAudio=" + hasAudio)
        onPlaybackStateChanged: root.say("state " + playbackState)
    }

    Timer {   // polls the seek until reached
        id: poll; interval: 5; repeat: true
        onTriggered: {
            var dt = Date.now() - root.tStart
            var err = mp.position - root.targets[root.ti]
            if (Math.abs(err) < 150 || dt > 3000) {
                poll.stop()
                root.say("seek " + root.targets[root.ti] + " -> pos " + mp.position + " (err " + err + "ms, latency " + dt + "ms)")
                nextSeek.start()
            }
        }
    }
    Timer { id: nextSeek; interval: 300; onTriggered: root.step() }
    Timer {   // after seeks, measure drift over 8 s of playback
        id: driftT; interval: 8000
        onTriggered: {
            var wall = Date.now() - root.driftWall
            var adv = mp.position - root.driftPos
            root.say("drift: wall " + wall + "ms, media advanced " + adv + "ms (diff " + (adv - wall) + "ms)")
            mp.stop(); root.say("DONE")
        }
    }

    function step() {
        ti++
        if (ti >= targets.length) {
            say("measuring drift (8 s)...")
            driftPos = mp.position; driftWall = Date.now(); driftT.start(); return
        }
        tStart = Date.now()
        mp.position = targets[ti]
        poll.start()
    }

    function runProbe() {
        log = ""
        if (path === "") { say("no file"); return }
        ti = -1
        mp.source = "file://" + path
        mp.play()
        startDelay.start()
    }
    Timer { id: startDelay; interval: 1500; onTriggered: { root.say("playing, pos=" + mp.position); root.step() } }

    function pickFile() {
        try {
            var dlg = Qt.createQmlObject('import Qt.labs.platform; FileDialog { title: "Audio"; nameFilters: ["Audio (*.mp3 *.flac *.wav *.ogg)"] }', root, "dlg")
            dlg.accepted.connect(function () {
                var p = dlg.file.toString().replace(/^file:\/\//, "")
                root.path = decodeURIComponent(p); pathField.text = root.path
            })
            dlg.open()
        } catch (e) { say("FileDialog unavailable: " + e) }
    }

    Rectangle {
        anchors.fill: parent
        color: "#202020"
    Column {
        anchors { fill: parent; margins: 16 }
        spacing: 8
        Row {
            spacing: 8
            Button { text: "Browse…"; onClicked: root.pickFile() }
            Button { text: "Run probe"; onClicked: root.runProbe() }
            Button { text: "Stop"; onClicked: { mp.stop(); poll.stop(); driftT.stop() } }
            Button { text: "Close"; onClicked: root.quit() }
        }
        TextField {
            id: pathField; width: parent.width; placeholderText: "or type absolute path"
            onTextChanged: root.path = text
        }
        Text { text: "pos " + mp.position + " / " + mp.duration + " ms  state " + mp.playbackState; color: "#bbb" }
        ScrollView {
            width: parent.width; height: parent.height - 120
            TextArea { readOnly: true; color: "#eee"; text: root.log; font.family: "monospace"; font.pixelSize: 11; wrapMode: Text.Wrap }
        }
    }
    }
}
