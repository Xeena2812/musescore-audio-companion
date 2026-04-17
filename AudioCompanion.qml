import MuseScore
import QtQuick
import QtQuick.Controls

// v0.9.1
MuseScore {
    id: root
    title: "Audio Companion"
    description: "Plays an audio file in sync with score playback"
    version: "0.9.1"
    pluginType: "dialog"
    width: 460
    height: 144

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

    // ── VLC HTTP bridge ───────────────────────────────────────────────────
    // QMediaPlayer has no backend in the snap sandbox. Instead we talk to
    // a headless VLC instance over its HTTP remote-control API (port 9090).
    // Start VLC with: ./start-vlc-server.sh  (in this repo)
    // VLC 3.x requires a non-empty password; default matches the script.
    property string _vlcBase: "http://127.0.0.1:9090"
    property string _vlcPass: "musescore"
    property bool   vlcConnected: false
    property string vlcState: "stopped"    // "stopped" | "playing" | "paused"

    // Fire-and-forget GET; cb(ok, responseText, httpStatus)
    function _vlcGet(query, cb) {
        var xhr = new XMLHttpRequest()
        var url = _vlcBase + "/requests/status.xml" + (query ? "?" + query : "")
        xhr.open("GET", url, true)
        xhr.timeout = 1500
        // VLC 3 Basic auth: user="" password=_vlcPass
        // btoa may not be available in all MU4 JS engine versions;
        // fall back to pre-computed value for the default password.
        var encoded = (typeof btoa === "function")
            ? btoa(":" + _vlcPass)
            : "Om11c2VzY29yZQ=="  // btoa(":musescore")
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
        var s = m[1]                           // "playing" | "paused" | "stopped"
        root.vlcConnected = true
        root.vlcState     = s
        root.isPlaying    = (s === "playing")
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

    function vlcVolume(v) {   // v: 0.0–1.0 → VLC 0–512 (256 = 100 %)
        _vlcGet("command=volume&val=" + Math.round(v * 256),
                function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    // ── Runtime state ─────────────────────────────────────────────────────
    property string filePath: ""
    property string fileName: ""
    property bool   isPlaying: false
    property string statusText: "v" + version + " — Ready"
    property string currentScoreKey: ""
    property var    fileDialog: null

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
            vlcStop()
            loadForScore()
        }
    }

    // ── UI ────────────────────────────────────────────────────────────────

    // Poll VLC every second to track playback state and detect when it stops.
    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            root._vlcGet("", function (ok, xml, httpStatus) {
                if (ok) {
                    root._parseVlc(xml)
                } else {
                    root.vlcConnected = false
                    root.vlcState     = "stopped"
                    root.isPlaying    = false
                    // httpStatus 0 = network unreachable; 401 = bad auth; 404 = wrong URL
                    root.statusText   = "VLC: HTTP " + httpStatus + " — start-vlc-server.sh?"
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

            // ── Row 2: transport + volume + offset ────────────────────────
            Row {
                width: parent.width
                spacing: 0

                Row {
                    spacing: 4

                    Button {
                        text: "⏮"
                        implicitWidth: 38; implicitHeight: 32
                        enabled: root.vlcConnected && root.filePath !== ""
                        onClicked: root.vlcSeek(0)
                    }
                    Button {
                        text: root.isPlaying ? "⏸" : "▶"
                        implicitWidth: 38; implicitHeight: 32
                        enabled: root.vlcConnected && root.filePath !== ""
                        onClicked: {
                            if (root.vlcState === "stopped") root.vlcPlay()
                            else root.vlcTogglePause()
                        }
                    }
                    Button {
                        text: "⏹"
                        implicitWidth: 38; implicitHeight: 32
                        enabled: root.vlcConnected
                        onClicked: root.vlcStop()
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
            }

            // ── Row 3: status ─────────────────────────────────────────────
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
