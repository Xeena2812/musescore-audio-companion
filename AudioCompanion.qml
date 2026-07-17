import MuseScore
import QtQuick
import QtQuick.Controls

// v1.2.0
MuseScore {
    id: root
    title: "Audio Companion"
    description: "Plays an audio file in sync with score playback"
    version: "1.2.0"
    pluginType: "dialog"
    width: 460
    height: 176

    // ── Persistent settings ───────────────────────────────────────────────
    property var _cfg: null

    function _cfgGet(key, def) {
        if (_cfg) {
            var v = _cfg[key]
            if (v !== undefined && v !== null) return v
        }
        return def
    }
    function _cfgSet(key, val) {
        if (_cfg) _cfg[key] = val
    }

    function _initSettings() {
        var iniPath = Qt.resolvedUrl("audio-companion.ini").toString().replace(/^file:\/\//, "")
        var body =
            'fileName: "' + iniPath + '"\n' +
            'property string scoreFileMap: "{}"\n' +
            'property string lastFilePath: ""\n' +
            'property real   volume: 1.0\n' +
            'property int    delayMs: 0\n'

        try {
            _cfg = Qt.createQmlObject('import QtCore\nSettings {\n' + body + '}', root, "cfg")
            console.log("[AudioCompanion] Settings: QtCore OK → " + iniPath)
            return
        } catch (e) {
            console.log("[AudioCompanion] Settings: QtCore failed: " + e)
        }

        try {
            _cfg = Qt.createQmlObject('import Qt.labs.settings\nSettings {\n' + body + '}', root, "cfg")
            console.log("[AudioCompanion] Settings: Qt.labs.settings OK → " + iniPath)
            return
        } catch (e) {
            console.log("[AudioCompanion] Settings: Qt.labs.settings failed: " + e)
        }

        console.log("[AudioCompanion] Settings: UNAVAILABLE — values will not persist")
    }

    // ── VLC HTTP bridge ───────────────────────────────────────────────────
    property string _vlcBase: "http://127.0.0.1:9090"
    property string _vlcPass: "musescore"
    property bool   vlcConnected: false
    property string vlcState: "stopped"    // "stopped" | "playing" | "paused"

    function _vlcGet(query, cb) {
        var xhr = new XMLHttpRequest()
        var url = _vlcBase + "/requests/status.xml" + (query ? "?" + query : "")
        xhr.open("GET", url, true)
        xhr.timeout = 1500
        var encoded = (typeof btoa === "function")
            ? btoa(":" + _vlcPass)
            : "Om11c2VzY29yZQ=="
        xhr.setRequestHeader("Authorization", "Basic " + encoded)
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return
            if (cb) cb(xhr.status === 200, xhr.responseText, xhr.status)
        }
        xhr.send()
    }

    function _parseVlc(xml) {
        var m = xml.match(/<state>(\w+)<\/state>/)
        if (!m) return
        var s = m[1]
        root.vlcConnected = true
        root.vlcState     = s
        root.isPlaying    = (s === "playing")
        var tm = xml.match(/<time>(\d+)<\/time>/)
        var lm = xml.match(/<length>(\d+)<\/length>/)
        if (tm) root.vlcPosition = parseInt(tm[1])
        if (lm) root.vlcLength   = parseInt(lm[1])
        if (s === "playing")
            root.statusText = "▶  " + root.fileName
        else if (s === "paused")
            root.statusText = "⏸  " + root.fileName
        else
            root.statusText = "v" + version + " — " + (root.fileName || "Ready")
    }

    function vlcPlay() {
        if (filePath === "") return
        var input = encodeURIComponent("file://" + filePath)
        _vlcGet("command=in_play&input=" + input, function (ok, xml) {
            if (ok) _parseVlc(xml)
            else root.statusText = "VLC not responding"
        })
    }

    function vlcTogglePause() {
        _vlcGet("command=pl_pause", function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    function vlcStop() {
        _vlcGet("command=pl_stop", function (ok, xml) {
            if (ok) _parseVlc(xml)
            root.isPlaying = false
        })
    }

    function vlcSeek(ms) {
        _vlcGet("command=seek&val=" + Math.round(ms / 1000) + "s",
                function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    function vlcVolume(v) {
        _vlcGet("command=volume&val=" + Math.round(v * 256),
                function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    // ── Play mode ─────────────────────────────────────────────────────────
    // "both" | "audio" | "score"
    property string playMode: "both"

    // ── Dual transport ────────────────────────────────────────────────────
    function transportPlay() {
        var scoreEnabled = (playMode !== "audio")
        var audioEnabled = (playMode !== "score")

        // If audio is wanted but no file is loaded, fall back to score-only.
        if (audioEnabled && root.filePath === "") {
            if (!scoreEnabled) return
            audioEnabled = false
        }

        if (scoreEnabled) root._scoreIsPlaying = true

        var delay = _cfgGet("delayMs", 0)
        if (scoreEnabled && audioEnabled) {
            if (delay >= 0) {
                cmd("play")
                if (delay > 0) {
                    _delayTarget = "vlc"
                    delayTimer.interval = delay
                    delayTimer.restart()
                } else {
                    vlcPlay()
                }
            } else {
                vlcPlay()
                _delayTarget = "score"
                delayTimer.interval = -delay
                delayTimer.restart()
            }
        } else if (scoreEnabled) {
            cmd("play")
        } else {
            vlcPlay()
        }
    }

    function transportPause() {
        // Guard: cmd("play") in MU4 is a toggle — calling it on a stopped score
        // would restart it. Only send it if we know the score is currently playing.
        if (playMode !== "audio" && root._scoreIsPlaying) cmd("play")
        if (playMode !== "score") vlcTogglePause()
        delayTimer.stop()
    }

    function transportStop() {
        if (playMode !== "audio") cmd("stop")
        if (playMode !== "score") vlcStop()
        delayTimer.stop()
        root._scoreIsPlaying = false
    }

    function transportRewind() {
        if (playMode !== "audio") cmd("rewind")
        if (playMode !== "score") vlcSeek(0)
    }

    // ── Runtime state ─────────────────────────────────────────────────────
    property string filePath: ""
    property string fileName: ""
    property bool   isPlaying: false
    property bool   _scoreIsPlaying: false   // tracks whether we started score playback
    property string statusText: "v" + version + " — Ready"
    property string currentScoreKey: ""
    property var    fileDialog: null
    property string _delayTarget: ""
    property int    vlcPosition: 0
    property int    vlcLength: 0
    property bool   _vlcLaunched: false
    property int    _vlcPollFail: 0

    function _fmtTime(s) {
        var m = Math.floor(s / 60)
        var sec = Math.floor(s % 60)
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    function vlcSkip(deltaS) {
        var target = Math.max(0, Math.min(root.vlcLength, root.vlcPosition + deltaS))
        vlcSeek(target * 1000)
    }

    function _tryLaunchVlc() {
        Qt.openUrlExternally(Qt.resolvedUrl("start-vlc-server.sh").toString())
        _vlcLaunched = true
        _vlcPollFail = 0
        root.statusText = "Starting VLC…"
    }

    // ── Settings helpers ──────────────────────────────────────────────────

    function scoreKey() {
        if (!curScore) return ""
        var p = curScore.path || ""
        return p !== "" ? p : (curScore.scoreName || "")
    }

    function loadForScore() {
        var key = scoreKey()
        currentScoreKey = key
        var path = ""
        if (key !== "") {
            try {
                path = JSON.parse(_cfgGet("scoreFileMap", "{}"))[key] || ""
            } catch (e) {}
        }
        path = path || _cfgGet("lastFilePath", "")
        if (path !== "") {
            root.filePath = path
            root.fileName = path.split("/").pop()
            root.statusText = "v" + version + " — " + root.fileName
        }
    }

    function saveFileForScore() {
        _cfgSet("lastFilePath", root.filePath)
        var key = scoreKey()
        if (key === "") return
        try {
            var map = JSON.parse(_cfgGet("scoreFileMap", "{}"))
            map[key] = root.filePath
            _cfgSet("scoreFileMap", JSON.stringify(map))
        } catch (e) {
            var fresh = {}
            fresh[key] = root.filePath
            _cfgSet("scoreFileMap", JSON.stringify(fresh))
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    onRun: {
        _initSettings()

        try {
            var dlg = Qt.createQmlObject(
                'import Qt.labs.platform; FileDialog {' +
                '  title: "Select Audio File";' +
                '  nameFilters: ["Audio files (*.mp3 *.wav *.ogg *.flac)", "All files (*)"];' +
                '}',
                root, "fileDialog"
            )
            dlg.accepted.connect(function () {
                var url = dlg.file.toString()
                root.filePath = url.replace(/^file:\/\//, "")
                root.fileName = url.split("/").pop()
                root.statusText = "v" + version + " — " + root.fileName
                saveFileForScore()
            })
            root.fileDialog = dlg
        } catch (e) {
            console.log("[AudioCompanion] FileDialog unavailable, using text input: " + e)
            root.statusText = "Paste a file path and press Enter"
            fallbackRow.visible = true
        }

        loadForScore()
        _vlcGet("", function(ok, xml) {
            if (ok) { _parseVlc(xml) } else { _tryLaunchVlc() }
        })
    }

    Component.onDestruction: root.vlcStop()

    onScoreStateChanged: {
        var key = scoreKey()
        if (key !== currentScoreKey) {
            transportStop()
            loadForScore()
            return
        }
        // Detect score finishing (MU4 exposes state.isPlaying in some versions).
        if (typeof state.isPlaying !== "undefined") {
            if (root._scoreIsPlaying && !state.isPlaying) {
                // Score stopped naturally; stop audio if it's still running.
                if (root.vlcState === "playing" && root.playMode !== "score") {
                    root.vlcStop()
                }
            }
            root._scoreIsPlaying = state.isPlaying
        }
    }

    // ── UI ────────────────────────────────────────────────────────────────

    Timer {
        id: delayTimer
        repeat: false
        onTriggered: {
            if (root._delayTarget === "vlc")    root.vlcPlay()
            else if (root._delayTarget === "score") cmd("play")
            root._delayTarget = ""
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            var prevVlcState = root.vlcState
            root._vlcGet("", function (ok, xml, httpStatus) {
                if (ok) {
                    root._vlcLaunched = false
                    root._vlcPollFail = 0
                    root._parseVlc(xml)
                    // VLC finished naturally while score was running → stop score.
                    if (prevVlcState === "playing" && root.vlcState === "stopped"
                            && root._scoreIsPlaying && root.playMode !== "score") {
                        cmd("stop")
                        root._scoreIsPlaying = false
                    }
                } else {
                    root.vlcConnected = false
                    root.vlcState     = "stopped"
                    root.isPlaying    = false
                    if (root._vlcLaunched && root._vlcPollFail < 5) {
                        root._vlcPollFail++
                        root.statusText = "Starting VLC…"
                    } else {
                        root._vlcLaunched = false
                        root.statusText = "VLC not running — ./start-vlc-server.sh"
                    }
                }
            })
        }
    }

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    Rectangle {
        anchors.fill: parent
        color: pal.window

        Column {
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 10 }
            spacing: 6

            // ── Row 1: file selector ──────────────────────────────────────
            Row {
                id: fileRow
                width: parent.width
                spacing: 8

                Button {
                    id: loadBtn
                    text: root.fileName !== "" ? "Change…" : "Load Audio…"
                    implicitHeight: 28
                    onClicked: {
                        if (root.fileDialog) {
                            root.fileDialog.open()
                        } else {
                            fallbackRow.visible = !fallbackRow.visible
                        }
                    }
                }

                Text {
                    text: root.fileName !== "" ? root.fileName : "No file loaded"
                    color: root.fileName !== "" ? pal.text : pal.mid
                    font.pixelSize: 12
                    elide: Text.ElideMiddle
                    width: fileRow.width - loadBtn.width - 8
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // ── Fallback: text input when FileDialog is unavailable ───────
            Row {
                id: fallbackRow
                visible: false
                width: parent.width
                spacing: 6

                TextField {
                    id: pathField
                    placeholderText: "Paste full audio file path…"
                    width: parent.width - okBtn.width - 6
                    implicitHeight: 28
                    onAccepted: okBtn.clicked()
                }
                Button {
                    id: okBtn
                    text: "OK"
                    implicitHeight: 28
                    onClicked: {
                        var p = pathField.text.trim()
                        if (p === "") return
                        root.filePath = p
                        root.fileName = p.split("/").pop()
                        root.statusText = "v" + version + " — " + root.fileName
                        saveFileForScore()
                        fallbackRow.visible = false
                        pathField.text = ""
                    }
                }
            }

            // ── Row 2: progress bar ───────────────────────────────────────
            Row {
                width: parent.width
                spacing: 6

                Slider {
                    id: progressSlider
                    from: 0; to: Math.max(1, root.vlcLength)
                    value: progressSlider.pressed ? progressSlider.value : root.vlcPosition
                    enabled: root.vlcConnected && root.vlcLength > 0
                    width: parent.width - timeLabel.width - 6
                    implicitHeight: 22
                    onMoved: root.vlcSeek(progressSlider.value * 1000)
                }
                Text {
                    id: timeLabel
                    text: root._fmtTime(root.vlcPosition) + " / " + root._fmtTime(root.vlcLength)
                    color: pal.text; font.pixelSize: 11; width: 72
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // ── Row 3: transport + skip + mode ────────────────────────────
            Row {
                spacing: 3

                Button {
                    text: "⏮"
                    implicitWidth: 30; implicitHeight: 28
                    enabled: root.playMode !== "audio" || (root.vlcConnected && root.filePath !== "")
                    onClicked: root.transportRewind()
                }
                Button {
                    text: "−10s"
                    implicitWidth: 40; implicitHeight: 28
                    enabled: root.vlcConnected && root.filePath !== ""
                    onClicked: root.vlcSkip(-10)
                }
                Button {
                    text: "−3s"
                    implicitWidth: 36; implicitHeight: 28
                    enabled: root.vlcConnected && root.filePath !== ""
                    onClicked: root.vlcSkip(-3)
                }
                Button {
                    text: (root._scoreIsPlaying || root.isPlaying) ? "⏸" : "▶"
                    implicitWidth: 36; implicitHeight: 28
                    enabled: root.playMode === "score"
                             || (root.vlcConnected && root.filePath !== "")
                    onClicked: {
                        var active = root._scoreIsPlaying || root.isPlaying
                                     || root.vlcState === "paused"
                        if (!active) root.transportPlay()
                        else root.transportPause()
                    }
                }
                Button {
                    text: "+3s"
                    implicitWidth: 36; implicitHeight: 28
                    enabled: root.vlcConnected && root.filePath !== ""
                    onClicked: root.vlcSkip(3)
                }
                Button {
                    text: "+10s"
                    implicitWidth: 40; implicitHeight: 28
                    enabled: root.vlcConnected && root.filePath !== ""
                    onClicked: root.vlcSkip(10)
                }
                Button {
                    text: "⏹"
                    implicitWidth: 30; implicitHeight: 28
                    enabled: root.vlcConnected || root._scoreIsPlaying
                    onClicked: root.transportStop()
                }
                // Spacer
                Item { width: 4; height: 1 }
                // Play-mode cycle button: Both → Audio → Score → Both
                Button {
                    text: root.playMode === "both" ? "Both" : (root.playMode === "audio" ? "Audio" : "Score")
                    implicitWidth: 52; implicitHeight: 28
                    ToolTip.visible: hovered
                    ToolTip.text: "Cycle: Both → Audio only → Score only"
                    onClicked: {
                        if (root.playMode === "both")        root.playMode = "audio"
                        else if (root.playMode === "audio")  root.playMode = "score"
                        else                                 root.playMode = "both"
                    }
                }
            }

            // ── Row 4: volume + offset ────────────────────────────────────
            Row {
                width: parent.width
                spacing: 0

                Row {
                    id: volRow
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "Vol"
                        color: pal.text; font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Slider {
                        id: volSlider
                        from: 0.0; to: 1.0
                        value: _cfg ? _cfg.volume : 1.0
                        implicitWidth: 90; implicitHeight: 28
                        onMoved: {
                            _cfgSet("volume", value)
                            root.vlcVolume(value)
                        }
                    }
                    Text {
                        text: Math.round(volSlider.value * 100) + "%"
                        color: pal.text; font.pixelSize: 12; width: 30
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Item { width: 12; height: 1 }

                Row {
                    id: offsetRow
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "Offset"
                        color: pal.text; font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    SpinBox {
                        id: offsetSpin
                        from: -10000; to: 10000
                        value: _cfg ? _cfg.delayMs : 0
                        stepSize: 1
                        editable: true
                        implicitWidth: 96; implicitHeight: 28
                        onValueModified: _cfgSet("delayMs", value)
                        textFromValue: function (v) { return (v >= 0 ? "+" : "") + v }
                        valueFromText: function (t) { return parseInt(t) || 0 }
                    }
                    Text {
                        text: "ms"
                        color: pal.text; font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            // ── Row 5: status ─────────────────────────────────────────────
            Text {
                width: parent.width
                text: root.statusText
                color: root.vlcConnected ? pal.mid : "#c07000"
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
    }
}
