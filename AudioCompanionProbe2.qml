import MuseScore
import QtQuick
import QtQuick.Controls
import QtMultimedia

// Probe 2: start latency, seek-while-playing, playback-rate ratio, 60 s drift.
// Measures Qt's reported clock vs wall clock; it cannot measure audible output latency.
MuseScore {
    id: root
    title: "Audio Companion Probe 2"
    description: "QtMultimedia start-latency/drift probe (not the real plugin)"
    version: "0.1"
    pluginType: "dialog"
    width: 560
    height: 640

    property string path: ""
    property string log: ""
    property var onPos: null      // called on every position change
    property var onState: null    // called on every state change
    property bool running: false

    function say(s) { log += s + "\n" }
    function later(ms, fn) { tm.fn = fn; tm.interval = ms; tm.restart() }
    onRun: say("Pick a file (>2 min), then Run probe 2 (~100 s)")

    Timer { id: tm; property var fn: null; onTriggered: if (fn) fn() }

    MediaPlayer {
        id: mp
        audioOutput: AudioOutput { }
        onErrorOccurred: (e, s) => root.say("ERROR " + e + ": " + s)
        onPositionChanged: if (root.onPos) root.onPos(position)
        onPlaybackStateChanged: if (root.onState) root.onState(playbackState)
    }

    function stats(a) {
        var s = a.slice().sort(function (x, y) { return x - y })
        var sum = 0; for (var i = 0; i < a.length; i++) sum += a[i]
        return "min " + s[0] + " med " + s[Math.floor(s.length / 2)] + " max " + s[s.length - 1] + " mean " + Math.round(sum / a.length) + " ms"
    }

    // Phase A: play() -> state Playing, and -> position first >= 30 ms
    function phaseA() {
        var n = 8, i = 0, tState = [], tPos = []
        function trial() {
            if (i >= n) {
                say("A start latency over " + n + " trials:")
                say("  to state=Playing: " + stats(tState))
                say("  to position>=30ms: " + stats(tPos))
                onPos = null; onState = null; mp.stop(); phaseB(); return
            }
            mp.stop(); mp.position = 0
            later(400, function () {
                var t0 = Date.now(), gotS = false, gotP = false
                onState = function (st) { if (!gotS && st === MediaPlayer.PlayingState) { gotS = true; tState.push(Date.now() - t0) } }
                onPos = function (p) {
                    if (!gotP && p >= 30) { gotP = true; tPos.push(Date.now() - t0); onPos = null; i++; mp.stop(); later(300, trial) }
                }
                mp.play()
                later(3000, function () { if (!gotP) { say("  trial " + i + " timed out"); onPos = null; i++; trial() } })
            })
        }
        trial()
    }

    // Phase B: seek during playback; position must be target + elapsed afterwards
    function phaseB() {
        say("B seek while playing:")
        var targets = [40000, 5000, 120000, 20000], j = 0
        mp.position = 0; mp.play()
        function seekNext() {
            if (j >= targets.length) { mp.pause(); phaseC(); return }
            var tg = targets[j++], t0 = Date.now()
            mp.position = tg
            later(1000, function () {
                var wall = Date.now() - t0
                var exp = tg + wall
                say("  seek " + tg + ": after " + wall + "ms pos=" + mp.position + " (expected ~" + exp + ", err " + (mp.position - exp) + "ms)")
                seekNext()
            })
        }
        later(1500, seekNext)
    }

    // Phase C: playbackRate 1.5 and 0.75, pitch-corrected? (listen) + clock ratio
    function phaseC() {
        say("C playback rate:")
        var rates = [1.5, 0.75, 1.0], k = 0
        mp.position = 10000; mp.play()
        function rateNext() {
            if (k >= rates.length) { mp.pause(); phaseD(); return }
            var r = rates[k++]
            mp.playbackRate = r
            later(300, function () {
                var p0 = mp.position, t0 = Date.now()
                later(5000, function () {
                    var adv = mp.position - p0, wall = Date.now() - t0
                    say("  rate " + r + ": media " + adv + "ms / wall " + wall + "ms = " + (adv / wall).toFixed(3))
                    rateNext()
                })
            })
        }
        later(1500, rateNext)
    }

    // Phase D: 60 s drift, sampled every 10 s
    function phaseD() {
        say("D drift over 60 s (media advance minus wall):")
        mp.playbackRate = 1.0; mp.position = 20000; mp.play()
        later(1500, function () {
            var p0 = mp.position, t0 = Date.now(), n = 0
            function sample() {
                n++
                var wall = Date.now() - t0, adv = mp.position - p0
                say("  t=" + (wall / 1000).toFixed(1) + "s diff " + (adv - wall) + "ms")
                if (n >= 6) { mp.stop(); say("DONE"); running = false; return }
                later(10000, sample)
            }
            later(10000, sample)
        })
    }

    function runProbe() {
        if (running) return
        if (path === "") { say("no file"); return }
        log = ""; running = true
        mp.source = "file://" + path
        say("Qt multimedia probe 2 on " + path.split("/").pop())
        later(800, function () { say("dur=" + mp.duration + "ms seekable=" + mp.seekable); phaseA() })
    }

    function pickFile() {
        try {
            var dlg = Qt.createQmlObject('import Qt.labs.platform; FileDialog { title: "Audio"; nameFilters: ["Audio (*.mp3 *.flac *.wav *.ogg)"] }', root, "dlg")
            dlg.accepted.connect(function () {
                root.path = decodeURIComponent(dlg.file.toString().replace(/^file:\/\//, "")); pathField.text = root.path
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
                Button { text: "Run probe 2"; onClicked: root.runProbe() }
                Button { text: "Copy log"; onClicked: { area.selectAll(); area.copy(); area.deselect() } }
                Button { text: "Close"; onClicked: { mp.stop(); root.quit() } }
            }
            TextField { id: pathField; width: parent.width; placeholderText: "or type absolute path"; onTextChanged: root.path = text }
            ScrollView {
                width: parent.width; height: parent.height - 90
                TextArea { id: area; readOnly: true; selectByMouse: true; color: "#eee"; text: root.log; font.family: "monospace"; font.pixelSize: 11; wrapMode: Text.Wrap }
            }
        }
    }
}
