import MuseScore
import QtQuick
import QtQuick.Controls

// v0.5.0
MuseScore {
    id: root
    title: "Audio Companion"
    description: "Plays an audio file in sync with score playback"
    version: "0.5.0"
    pluginType: "dock"
    dockArea: "bottom"
    width: 460
    implicitHeight: 122

    // ── Persistent settings ───────────────────────────────────────────────
    // QSettings default path is blocked by the snap sandbox (AccessError).
    // Fix: supply an explicit fileName inside the plugins folder, which the
    // snap can always write to. Probe QtCore (Qt 6) then Qt.labs.settings.
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
        // Qt.resolvedUrl resolves relative to this QML file, so the INI lands
        // next to AudioCompanion.qml — a path the snap sandbox can write to.
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

    // ── Audio engine ──────────────────────────────────────────────────────
    property var _player: null
    property var _audioOut: null

    function _initAudio() {
        try {
            var ao = Qt.createQmlObject('import QtMultimedia; AudioOutput {}', root, "audioOut")
            var mp = Qt.createQmlObject('import QtMultimedia; MediaPlayer { autoPlay: false }', root, "player")
            mp.audioOutput = ao
            ao.volume = _cfgGet("volume", 1.0)

            // Sync isPlaying and statusText from actual playback state
            mp.playbackStateChanged.connect(function () {
                var playing = (mp.playbackState === 1)  // MediaPlayer.PlayingState
                root.isPlaying = playing
                if (playing) {
                    root.statusText = "▶  " + root.fileName
                } else if (mp.playbackState === 2) {    // PausedState
                    root.statusText = "⏸  " + root.fileName
                } else {
                    root.statusText = "v" + version + " — " + (root.fileName || "Ready")
                }
            })

            mp.errorOccurred.connect(function (error, errorString) {
                root.statusText = "Error: " + errorString
                root.isPlaying = false
                console.log("[AudioCompanion] MediaPlayer error " + error + ": " + errorString)
            })

            root._player   = mp
            root._audioOut = ao
            console.log("[AudioCompanion] Audio engine: OK")
        } catch (e) {
            console.log("[AudioCompanion] Audio engine failed: " + e)
        }
    }

    function _applySource() {
        if (!_player || filePath === "") return
        _player.source = "file://" + filePath
    }

    // ── Runtime state ─────────────────────────────────────────────────────
    property string filePath: ""
    property string fileName: ""
    property bool   isPlaying: false
    property string statusText: "v" + version + " — Ready"
    property string currentScoreKey: ""
    property var    fileDialog: null

    onFilePathChanged: {
        _applySource()
        if (_player) _player.stop()
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
        console.log("[AudioCompanion] loadForScore key=" + key + " path=" + path)
        if (path !== "") {
            root.filePath = path
            root.fileName = path.split("/").pop()
            root.statusText = "v" + version + " — " + root.fileName
        }
    }

    function saveFileForScore() {
        _cfgSet("lastFilePath", root.filePath)
        var key = scoreKey()
        console.log("[AudioCompanion] saveFileForScore key=" + key + " path=" + root.filePath)
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
        _initAudio()

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
                console.log("[AudioCompanion] File selected: " + root.filePath)
            })
            root.fileDialog = dlg
            console.log("[AudioCompanion] FileDialog: OK")
        } catch (e) {
            console.log("[AudioCompanion] FileDialog unavailable, using text input: " + e)
            root.statusText = "Paste a file path and press Enter"
            fallbackRow.visible = true
        }

        loadForScore()
    }

    onScoreStateChanged: {
        var key = scoreKey()
        if (key !== currentScoreKey) {
            if (_player) _player.stop()
            loadForScore()
        }
    }

    // ── UI ────────────────────────────────────────────────────────────────

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    Rectangle {
        anchors.fill: parent
        color: pal.window

        Column {
            anchors { fill: parent; margins: 10 }
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

            // ── Row 2: transport + volume + offset ────────────────────────
            Row {
                width: parent.width
                spacing: 0

                Row {
                    spacing: 4

                    Button {
                        text: "⏮"
                        implicitWidth: 38; implicitHeight: 32
                        enabled: root.filePath !== ""
                        onClicked: { if (root._player) root._player.position = 0 }
                    }
                    Button {
                        text: root.isPlaying ? "⏸" : "▶"
                        implicitWidth: 38; implicitHeight: 32
                        enabled: root.filePath !== ""
                        onClicked: {
                            if (!root._player) return
                            if (root._player.playbackState === 1) root._player.pause()
                            else root._player.play()
                        }
                    }
                    Button {
                        text: "⏹"
                        implicitWidth: 38; implicitHeight: 32
                        enabled: root.filePath !== ""
                        onClicked: { if (root._player) root._player.stop() }
                    }
                }

                Item { width: 12; height: 1 }

                Row {
                    id: volRow
                    spacing: 5
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
                        implicitWidth: 90; implicitHeight: 32
                        onMoved: {
                            _cfgSet("volume", value)
                            if (root._audioOut) root._audioOut.volume = value
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
                    spacing: 5
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
                        stepSize: 10
                        implicitWidth: 96; implicitHeight: 32
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

                Item { width: 10; height: 1 }

                Text {
                    text: root.statusText
                    color: pal.mid; font.pixelSize: 11
                    elide: Text.ElideRight
                    width: parent.width - 38*3 - 4*2 - 12
                           - (volRow.width + 12)
                           - (offsetRow.width + 10)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
