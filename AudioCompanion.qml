import MuseScore
import QtQuick
import QtQuick.Controls

// v1.3.0
MuseScore {
    id: root
    title: "Audio Companion"
    description: "Plays an audio file in sync with score playback"
    version: "1.3.0"
    pluginType: "dialog"
    width: 520
    // MU4 plugin dialogs are fixed-size: the window ignores later width/height
    // changes and can't be resized, and "dock" plugins open as the same dialog.
    // Sized for the tallest case (VLC offline banner showing, panels expanded).
    height: 430

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
            'property string scoreSettings: "{}"\n' +
            'property string recentFiles: "[]"\n' +
            'property string lastFilePath: ""\n' +
            'property real   volume: 1.0\n' +
            'property int    delayMs: 0\n' +
            'property int    showPanels: 1\n'

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

    function _jsonGet(key, def) {
        try { return JSON.parse(_cfgGet(key, "")) } catch (e) { return def }
    }

    // ── VLC HTTP bridge ───────────────────────────────────────────────────
    property string _vlcBase: "http://127.0.0.1:9091"
    property string _vlcPass: "musescore"
    property bool   vlcConnected: false
    property string vlcState: "stopped"    // "stopped" | "playing" | "paused"
    property int    vlcHttp: 0
    property bool   _vlcEverPolled: false
    property bool   _vlcSynced: false      // volume/rate pushed since last (re)connect

    function _vlcGet(query, cb) {
        var xhr = new XMLHttpRequest()
        var url = _vlcBase + "/requests/status.xml" + (query ? "?" + query : "")
        xhr.open("GET", url, true)
        xhr.timeout = 1500
        var encoded = (typeof btoa === "function")
            ? btoa(":" + _vlcPass)
            : "Om11c2VzY29yZQ=="
        xhr.setRequestHeader("Authorization", "Basic " + encoded)
        // A hung connection (no RST, no Qt-level timeout event) must still
        // resolve the callback, or the UI freezes on stale status text.
        var done = false
        function finish(ok, text, status) {
            if (done) return
            done = true
            if (cb) cb(ok, text, status)
        }
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return
            finish(xhr.status === 200, xhr.responseText, xhr.status)
        }
        xhr.ontimeout = function () { finish(false, "", -1) }
        xhr.onerror   = function () { finish(false, "", -1) }
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
            if (ok) { _parseVlc(xml); applyRate() }
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

    function vlcRate(r) {
        _vlcGet("command=rate&val=" + r,
                function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    function applyVolume() {
        vlcVolume(root.muted ? 0 : root.audioVolume)
    }

    // Speed only applies in Audio mode: the score can't follow a rate change.
    function applyRate() {
        vlcRate(root.playMode === "audio" ? root.speed : 1)
    }

    function pollVlc() {
        var prevVlcState = root.vlcState
        root._vlcGet("", function (ok, xml, httpStatus) {
            root._vlcEverPolled = true
            root.vlcHttp = httpStatus
            if (ok) {
                root._vlcLaunched = false
                root._vlcPollFail = 0
                root._parseVlc(xml)
                if (!root._vlcSynced) {
                    root._vlcSynced = true
                    root.applyVolume()
                    root.applyRate()
                }
                // VLC finished naturally while score was running → stop score.
                if (prevVlcState === "playing" && root.vlcState === "stopped"
                        && root._scoreIsPlaying && root.playMode !== "score") {
                    cmd("stop")
                    root._scoreIsPlaying = false
                }
                // A–B loop (Audio mode only; second-level accuracy).
                if (root.loopOn && root.playMode === "audio" && root.loopA >= 0
                        && root.loopB > root.loopA && root.vlcState === "playing"
                        && root.vlcPosition >= root.loopB) {
                    root.vlcSeek(root.loopA * 1000)
                }
            } else {
                root.vlcConnected = false
                root._vlcSynced   = false
                root.vlcState     = "stopped"
                root.isPlaying    = false
                if (root._vlcLaunched && root._vlcPollFail < 5)
                    root._vlcPollFail++
                else
                    root._vlcLaunched = false
            }
        })
    }

    // ── Play mode ─────────────────────────────────────────────────────────
    // "both" | "audio" | "score"
    property string playMode: "both"
    onPlayModeChanged: {
        if (vlcConnected) applyRate()
        saveScoreSettings()
    }

    // ── Sync / mix state ──────────────────────────────────────────────────
    property int    offsetMs: 0
    property real   audioVolume: 1.0
    property bool   muted: false
    property real   speed: 1.0
    property int    loopA: -1      // seconds, -1 = unset
    property int    loopB: -1
    property bool   loopOn: false
    property bool   _loading: false
    property bool   showPanels: true

    function setOffset(v) {
        root.offsetMs = Math.max(-10000, Math.min(10000, Math.round(v)))
        saveScoreSettings()
    }
    function nudgeOffset(d) { setOffset(root.offsetMs + d) }

    function setVolume(v) {
        root.audioVolume = v
        if (v > 0) root.muted = false
        applyVolume()
        saveScoreSettings()
    }
    function toggleMute() {
        root.muted = !root.muted
        applyVolume()
    }

    function setSpeed(r) {
        root.speed = r
        if (vlcConnected) applyRate()
    }

    function markLoopA() {
        root.loopA = root.vlcPosition
        if (root.loopB <= root.loopA) { root.loopB = -1; root.loopOn = false }
    }
    function markLoopB() {
        if (root.loopA < 0 || root.vlcPosition <= root.loopA) {
            root.statusText = "Set loop B after loop A"
            return
        }
        root.loopB = root.vlcPosition
    }
    function clearLoop() {
        root.loopA = -1
        root.loopB = -1
        root.loopOn = false
    }

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

        var delay = root.offsetMs
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

    function togglePlayPause() {
        if (!canPlay) return
        var active = root._scoreIsPlaying || root.isPlaying || root.vlcState === "paused"
        if (!active) transportPlay()
        else transportPause()
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
    property var    recentList: []

    readonly property bool vlcStarting: _vlcLaunched && _vlcPollFail < 5
    readonly property bool canSeek: vlcConnected && filePath !== ""
    readonly property bool canPlay: playMode === "score" || (vlcConnected && filePath !== "")
    readonly property bool audioMode: playMode === "audio"

    function _fmtTime(s) {
        var m = Math.floor(s / 60)
        var sec = Math.floor(s % 60)
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    function _fmtOffset(v) {
        return (v >= 0 ? "+" : "") + v + " ms"
    }

    function _baseName(p) {
        var n = p.split("/").pop()
        try { return decodeURIComponent(n) } catch (e) { return n }
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

    function setFile(path, remember) {
        root.filePath = path
        root.fileName = _baseName(path)
        root.statusText = "v" + version + " — " + root.fileName
        clearLoop()
        if (remember) {
            addRecent(path)
            saveFileForScore()
        }
    }

    function refreshRecent() {
        var list = _jsonGet("recentFiles", [])
        var out = []
        for (var i = 0; i < list.length; i++)
            out.push({ name: _baseName(list[i]), path: list[i] })
        root.recentList = out
    }

    function addRecent(path) {
        var list = _jsonGet("recentFiles", [])
        var next = [path]
        for (var i = 0; i < list.length; i++)
            if (list[i] !== path) next.push(list[i])
        _cfgSet("recentFiles", JSON.stringify(next.slice(0, 8)))
        refreshRecent()
    }

    function loadForScore() {
        _loading = true
        var key = scoreKey()
        currentScoreKey = key
        var path = ""
        var s = null
        if (key !== "") {
            try {
                path = JSON.parse(_cfgGet("scoreFileMap", "{}"))[key] || ""
            } catch (e) {}
            s = _jsonGet("scoreSettings", {})[key] || null
        }
        path = path || _cfgGet("lastFilePath", "")
        if (path !== "") setFile(path, false)

        root.offsetMs    = s && s.delayMs !== undefined ? s.delayMs : _cfgGet("delayMs", 0)
        root.audioVolume = s && s.volume !== undefined ? s.volume : _cfgGet("volume", 1.0)
        root.playMode    = s && s.mode ? s.mode : "both"
        _loading = false

        if (vlcConnected) { applyVolume(); applyRate() }
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

    function saveScoreSettings() {
        if (_loading) return
        _cfgSet("delayMs", root.offsetMs)
        _cfgSet("volume", root.audioVolume)
        var key = scoreKey()
        if (key === "") return
        var map = _jsonGet("scoreSettings", {})
        map[key] = { delayMs: root.offsetMs, volume: root.audioVolume, mode: root.playMode }
        _cfgSet("scoreSettings", JSON.stringify(map))
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    onRun: {
        _initSettings()
        root.showPanels = _cfgGet("showPanels", 1) !== 0
        refreshRecent()

        try {
            var dlg = Qt.createQmlObject(
                'import Qt.labs.platform; FileDialog {' +
                '  title: "Select Audio File";' +
                '  nameFilters: ["Audio files (*.mp3 *.wav *.ogg *.flac)", "All files (*)"];' +
                '}',
                root, "fileDialog"
            )
            dlg.accepted.connect(function () {
                root.setFile(dlg.file.toString().replace(/^file:\/\//, ""), true)
            })
            root.fileDialog = dlg
        } catch (e) {
            console.log("[AudioCompanion] FileDialog unavailable, using text input: " + e)
            root.statusText = "Paste a file path and press Enter"
            fallbackRow.visible = true
        }

        loadForScore()
        _vlcGet("", function(ok, xml) {
            root._vlcEverPolled = true
            if (ok) { _parseVlc(xml) } else { _tryLaunchVlc() }
        })
    }

    Component.onDestruction: {
        root.vlcRate(1)
        root.vlcStop()
    }

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

    // ── Timers ────────────────────────────────────────────────────────────

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
        interval: (root.loopOn && root.audioMode) ? 500 : 1000
        repeat: true
        running: true
        onTriggered: root.pollVlc()
    }

    // ── Keyboard shortcuts (active while this dialog has focus) ───────────

    Shortcut { sequence: "Space";       onActivated: root.togglePlayPause() }
    Shortcut { sequence: "Left";        onActivated: if (root.canSeek) root.vlcSkip(-3) }
    Shortcut { sequence: "Right";       onActivated: if (root.canSeek) root.vlcSkip(3) }
    Shortcut { sequence: "Shift+Left";  onActivated: if (root.canSeek) root.vlcSkip(-10) }
    Shortcut { sequence: "Shift+Right"; onActivated: if (root.canSeek) root.vlcSkip(10) }
    Shortcut { sequence: "[";           onActivated: root.nudgeOffset(-10) }
    Shortcut { sequence: "]";           onActivated: root.nudgeOffset(10) }

    // ── UI ────────────────────────────────────────────────────────────────

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    // Foreground colour at a given opacity — neutral washes that work in light and dark.
    function _tx(a) { return Qt.rgba(pal.text.r, pal.text.g, pal.text.b, a) }

    // ── Styled controls ───────────────────────────────────────────────────

    component PBtn: Button {
        id: b
        property bool primary: false
        readonly property bool accented: primary || highlighted
        implicitHeight: 24
        padding: 0
        leftPadding: 10
        rightPadding: 10
        font.pixelSize: 12
        SystemPalette { id: bp }

        contentItem: Text {
            text: b.text
            font: b.font
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: !b.enabled ? Qt.rgba(bp.text.r, bp.text.g, bp.text.b, 0.3)
                 : b.accented ? bp.highlightedText : bp.text
        }
        background: Rectangle {
            radius: b.primary ? height / 2 : 7
            border.width: b.accented ? 0 : 1
            border.color: Qt.rgba(bp.text.r, bp.text.g, bp.text.b, 0.12)
            color: !b.enabled ? Qt.rgba(bp.text.r, bp.text.g, bp.text.b, 0.04)
                 : b.accented ? (b.down ? Qt.darker(bp.highlight, 1.2)
                                        : (b.hovered ? Qt.lighter(bp.highlight, 1.12) : bp.highlight))
                 : Qt.rgba(bp.text.r, bp.text.g, bp.text.b, b.down ? 0.22 : (b.hovered ? 0.14 : 0.08))
        }
    }

    component PSlider: Slider {
        id: s
        implicitHeight: 24
        SystemPalette { id: sp }

        background: Rectangle {
            x: s.leftPadding
            y: s.topPadding + s.availableHeight / 2 - height / 2
            width: s.availableWidth
            height: 4
            radius: 2
            color: Qt.rgba(sp.text.r, sp.text.g, sp.text.b, 0.18)

            Rectangle {
                width: s.visualPosition * parent.width
                height: parent.height
                radius: 2
                color: s.enabled ? sp.highlight : Qt.rgba(sp.text.r, sp.text.g, sp.text.b, 0.3)
            }
        }
        handle: Rectangle {
            x: s.leftPadding + s.visualPosition * (s.availableWidth - width)
            y: s.topPadding + s.availableHeight / 2 - height / 2
            width: 14
            height: 14
            radius: 7
            border.width: 2
            border.color: sp.window
            color: !s.enabled ? Qt.rgba(sp.text.r, sp.text.g, sp.text.b, 0.35)
                 : s.pressed ? Qt.lighter(sp.highlight, 1.2) : sp.highlight
        }
    }

    Rectangle {
        anchors.fill: parent
        color: pal.window

        Column {
            id: content
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 14 }
            spacing: 8

            // ── File header ───────────────────────────────────────────────
            Row {
                id: fileRow
                width: parent.width
                spacing: 8

                Rectangle {
                    width: fileRow.width - loadBtn.width - recentWrap.width - 16
                    height: 28
                    radius: 8
                    color: root._tx(0.06)
                    border.width: 1
                    border.color: root._tx(0.1)

                    Text {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        verticalAlignment: Text.AlignVCenter
                        text: root.fileName !== "" ? "♪  " + root.fileName : "No file loaded"
                        color: root.fileName !== "" ? pal.text : pal.mid
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                }

                PBtn {
                    id: loadBtn
                    text: root.fileName !== "" ? "Change…" : "Load audio…"
                    implicitHeight: 26
                    onClicked: {
                        if (root.fileDialog) {
                            root.fileDialog.open()
                        } else {
                            fallbackRow.visible = !fallbackRow.visible
                        }
                    }
                }

                Item {
                    id: recentWrap
                    width: recentBtn.implicitWidth
                    height: 28

                    PBtn {
                        id: recentBtn
                        text: "Recent ▾"
                        implicitHeight: 26
                        enabled: root.recentList.length > 0
                        onClicked: recentPopup.opened ? recentPopup.close() : recentPopup.open()
                    }

                    Popup {
                        id: recentPopup
                        x: recentWrap.width - width
                        y: recentWrap.height + 4
                        width: 320
                        padding: 6
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                        background: Rectangle {
                            radius: 10
                            color: pal.window
                            border.width: 1
                            border.color: root._tx(0.2)
                        }
                        contentItem: Column {
                            spacing: 2
                            Repeater {
                                model: root.recentList
                                PBtn {
                                    width: parent.width
                                    text: modelData.name
                                    onClicked: {
                                        root.setFile(modelData.path, true)
                                        recentPopup.close()
                                    }
                                }
                            }
                        }
                    }
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
                    implicitHeight: 30
                    onAccepted: okBtn.clicked()
                }
                PBtn {
                    id: okBtn
                    text: "OK"
                    onClicked: {
                        var p = pathField.text.trim()
                        if (p === "") return
                        root.setFile(p, true)
                        fallbackRow.visible = false
                        pathField.text = ""
                    }
                }
            }

            // ── Status pill + play mode ───────────────────────────────────
            Item {
                width: parent.width
                height: 26

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    height: 22
                    width: pillRow.implicitWidth + 22
                    radius: 12
                    color: root.vlcConnected ? Qt.rgba(0.18, 0.62, 0.31, 0.16)
                         : root.vlcStarting  ? Qt.rgba(0.75, 0.44, 0.0, 0.16)
                                             : Qt.rgba(0.85, 0.33, 0.31, 0.16)
                    border.width: 1
                    border.color: root.vlcConnected ? Qt.rgba(0.18, 0.62, 0.31, 0.45)
                                : root.vlcStarting  ? Qt.rgba(0.75, 0.44, 0.0, 0.45)
                                                    : Qt.rgba(0.85, 0.33, 0.31, 0.45)

                    Row {
                        id: pillRow
                        anchors.centerIn: parent
                        spacing: 7

                        Rectangle {
                            width: 8; height: 8; radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.vlcConnected ? "#2f9e50" : (root.vlcStarting ? "#c07000" : "#d9534f")
                        }
                        Text {
                            font.pixelSize: 12
                            text: root.vlcConnected ? "VLC connected"
                                : root.vlcStarting  ? "Starting VLC…"
                                                    : "VLC offline"
                            color: root.vlcConnected ? "#2f9e50"
                                 : root.vlcStarting  ? "#c07000"
                                                     : "#d9534f"
                        }
                    }
                }

                // Segmented play-mode control
                Rectangle {
                    id: seg
                    readonly property int idx: root.playMode === "score" ? 0 : (root.playMode === "both" ? 1 : 2)
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    width: 230
                    height: 26
                    radius: 9
                    color: root._tx(0.08)
                    border.width: 1
                    border.color: root._tx(0.12)

                    Rectangle {
                        y: 2
                        x: 4 + seg.idx * 74
                        width: 74
                        height: 22
                        radius: 7
                        color: pal.highlight
                        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    Row {
                        x: 4
                        y: 2
                        Repeater {
                            model: [{ k: "score", t: "Score" }, { k: "both", t: "Both" }, { k: "audio", t: "Audio" }]
                            Item {
                                width: 74
                                height: 22
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.t
                                    font.pixelSize: 12
                                    color: root.playMode === modelData.k ? pal.highlightedText : pal.text
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.playMode = modelData.k
                                }
                            }
                        }
                    }
                }
            }

            // ── Offline banner ────────────────────────────────────────────
            Rectangle {
                width: parent.width
                height: 48
                radius: 10
                visible: root._vlcEverPolled && !root.vlcConnected && !root.vlcStarting
                color: Qt.rgba(0.85, 0.33, 0.31, 0.12)
                border.width: 1
                border.color: Qt.rgba(0.85, 0.33, 0.31, 0.4)

                Column {
                    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    spacing: 2
                    Text {
                        text: "VLC isn't reachable"
                        color: "#d9534f"
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Text {
                        text: "HTTP " + root.vlcHttp + " on port 9091. Start the VLC server, then retry."
                        color: pal.text
                        font.pixelSize: 11
                    }
                }
                PBtn {
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "Retry"
                    onClicked: root.pollVlc()
                }
            }

            // ── Timeline ──────────────────────────────────────────────────
            Row {
                width: parent.width
                spacing: 6

                Text {
                    width: 40
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._fmtTime(root.vlcPosition)
                    color: pal.text
                    font.pixelSize: 11
                }

                Item {
                    width: parent.width - 92
                    height: 26

                    PSlider {
                        id: progressSlider
                        anchors.fill: parent
                        from: 0; to: Math.max(1, root.vlcLength)
                        value: progressSlider.pressed ? progressSlider.value : root.vlcPosition
                        enabled: root.vlcConnected && root.vlcLength > 0
                        onMoved: root.vlcSeek(progressSlider.value * 1000)
                    }

                    // Loop A / B markers
                    Rectangle {
                        visible: root.loopA >= 0 && root.vlcLength > 0
                        width: 3; height: 12; radius: 1
                        y: (parent.height - height) / 2
                        x: progressSlider.leftPadding + 7
                           + (progressSlider.availableWidth - 14) * (root.loopA / Math.max(1, root.vlcLength)) - 1
                        color: "#e0a030"
                    }
                    Rectangle {
                        visible: root.loopB >= 0 && root.vlcLength > 0
                        width: 3; height: 12; radius: 1
                        y: (parent.height - height) / 2
                        x: progressSlider.leftPadding + 7
                           + (progressSlider.availableWidth - 14) * (root.loopB / Math.max(1, root.vlcLength)) - 1
                        color: "#e0a030"
                    }
                }

                Text {
                    width: 40
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: root._fmtTime(root.vlcLength)
                    color: pal.text
                    font.pixelSize: 11
                }
            }

            Text {
                width: parent.width
                color: pal.mid
                font.pixelSize: 11
                text: (root.loopA < 0 && root.loopB < 0)
                      ? "Loop: set A and B (Audio mode)"
                      : "Loop  A " + (root.loopA >= 0 ? root._fmtTime(root.loopA) : "–")
                        + "  B " + (root.loopB >= 0 ? root._fmtTime(root.loopB) : "–")
                        + (root.loopOn ? (root.audioMode ? "  ● on" : "  ● on (Audio mode only)") : "")
            }

            // ── Transport ─────────────────────────────────────────────────
            Item {
                width: parent.width
                height: 32

                Row {
                    anchors.centerIn: parent
                    spacing: 5

                    PBtn {
                        text: "⏮"
                        implicitWidth: 36; implicitHeight: 28
                        enabled: root.playMode !== "audio" || root.canSeek
                        onClicked: root.transportRewind()
                    }
                    PBtn {
                        text: "−10"
                        implicitWidth: 42; implicitHeight: 28
                        enabled: root.canSeek
                        onClicked: root.vlcSkip(-10)
                    }
                    PBtn {
                        text: "−3"
                        implicitWidth: 38; implicitHeight: 28
                        enabled: root.canSeek
                        onClicked: root.vlcSkip(-3)
                    }
                    PBtn {
                        primary: true
                        text: (root._scoreIsPlaying || root.isPlaying) ? "⏸" : "▶"
                        font.pixelSize: 17
                        implicitWidth: 70; implicitHeight: 32
                        enabled: root.canPlay
                        onClicked: root.togglePlayPause()
                    }
                    PBtn {
                        text: "+3"
                        implicitWidth: 38; implicitHeight: 28
                        enabled: root.canSeek
                        onClicked: root.vlcSkip(3)
                    }
                    PBtn {
                        text: "+10"
                        implicitWidth: 42; implicitHeight: 28
                        enabled: root.canSeek
                        onClicked: root.vlcSkip(10)
                    }

                    Item { width: 12; height: 1 }

                    PBtn {
                        text: "A"
                        implicitWidth: 32; implicitHeight: 28
                        enabled: root.canSeek && root.audioMode
                        ToolTip.visible: hovered
                        ToolTip.text: "Set loop start at the current position (Audio mode)"
                        onClicked: root.markLoopA()
                    }
                    PBtn {
                        text: "B"
                        implicitWidth: 32; implicitHeight: 28
                        enabled: root.canSeek && root.audioMode
                        ToolTip.visible: hovered
                        ToolTip.text: "Set loop end at the current position (Audio mode)"
                        onClicked: root.markLoopB()
                    }
                    PBtn {
                        text: "Loop"
                        implicitWidth: 48; implicitHeight: 28
                        enabled: root.audioMode && root.loopA >= 0 && root.loopB > root.loopA
                        highlighted: root.loopOn
                        onClicked: root.loopOn = !root.loopOn
                    }
                    PBtn {
                        text: "✕"
                        implicitWidth: 30; implicitHeight: 28
                        visible: root.loopA >= 0 || root.loopB >= 0
                        ToolTip.visible: hovered
                        ToolTip.text: "Clear loop"
                        onClicked: root.clearLoop()
                    }
                }
            }

            // ── Collapsible: sync & mix ───────────────────────────────────
            Item {
                width: parent.width
                height: 22

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (root.showPanels ? "▾" : "▸") + "  Sync and mix"
                    color: pal.text
                    font.pixelSize: 12
                    font.bold: true
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.showPanels = !root.showPanels
                        root._cfgSet("showPanels", root.showPanels ? 1 : 0)
                    }
                }
            }

            Row {
                id: panelRow
                width: parent.width
                spacing: 10
                visible: root.showPanels

                // Sync offset card
                Rectangle {
                    id: syncCard
                    width: Math.floor((panelRow.width - 10) * 0.56)
                    height: syncCol.implicitHeight + 24
                    radius: 10
                    color: root._tx(0.05)
                    border.width: 1
                    border.color: root._tx(0.1)

                    Column {
                        id: syncCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                        spacing: 10

                        Item {
                            width: parent.width
                            height: 18
                            Text {
                                text: "Sync offset"
                                color: pal.text
                                font.pixelSize: 12
                                font.bold: true
                            }
                            Text {
                                anchors.right: parent.right
                                text: root._fmtOffset(root.offsetMs)
                                color: pal.highlight
                                font.pixelSize: 13
                                font.bold: true
                            }
                        }

                        Row {
                            spacing: 4
                            Repeater {
                                model: [-100, -10, -1, 1, 10, 100]
                                PBtn {
                                    text: (modelData > 0 ? "+" : "−") + Math.abs(modelData)
                                    implicitWidth: Math.floor((syncCol.width - 20) / 6)
                                    implicitHeight: 24
                                    leftPadding: 0
                                    rightPadding: 0
                                    font.pixelSize: 11
                                    onClicked: root.nudgeOffset(modelData)
                                }
                            }
                        }

                        PBtn {
                            text: "Reset"
                            implicitHeight: 24
                            font.pixelSize: 11
                            enabled: root.offsetMs !== 0
                            onClicked: root.setOffset(0)
                        }
                    }
                }

                // Audio mix card
                Rectangle {
                    id: mixCard
                    width: panelRow.width - syncCard.width - 10
                    height: Math.max(syncCard.height, mixCol.implicitHeight + 24)
                    radius: 10
                    color: root._tx(0.05)
                    border.width: 1
                    border.color: root._tx(0.1)

                    Column {
                        id: mixCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                        spacing: 10

                        Text {
                            text: "Audio mix"
                            color: pal.text
                            font.pixelSize: 12
                            font.bold: true
                        }

                        Row {
                            spacing: 4
                            PBtn {
                                text: root.muted ? "Muted" : "Mute"
                                implicitWidth: 54; implicitHeight: 24
                                leftPadding: 0
                                rightPadding: 0
                                font.pixelSize: 11
                                highlighted: root.muted
                                onClicked: root.toggleMute()
                            }
                            PSlider {
                                id: volSlider
                                from: 0.0; to: 1.0
                                value: root.audioVolume
                                implicitWidth: mixCol.width - 54 - 34 - 8
                                implicitHeight: 24
                                onMoved: root.setVolume(value)
                            }
                            Text {
                                width: 30
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                text: Math.round(root.audioVolume * 100) + "%"
                                color: pal.text
                                font.pixelSize: 11
                            }
                        }

                        Row {
                            spacing: 4
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Speed"
                                color: root.audioMode ? pal.text : pal.mid
                                font.pixelSize: 11
                                width: 40
                            }
                            Repeater {
                                model: [0.75, 1.0, 1.25]
                                PBtn {
                                    text: modelData === 1.0 ? "1×" : modelData.toString()
                                    implicitWidth: 38; implicitHeight: 24
                                    leftPadding: 0
                                    rightPadding: 0
                                    font.pixelSize: 11
                                    enabled: root.vlcConnected && root.audioMode
                                    highlighted: root.speed === modelData
                                    ToolTip.visible: hovered
                                    ToolTip.text: "Audio mode only — the score can't follow a speed change"
                                    onClicked: root.setSpeed(modelData)
                                }
                            }
                        }
                    }
                }
            }

        }

        // ── Footer (pinned to the bottom so the window's fixed height never clips it) ──
        Item {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 14 }
            height: 26

            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 1
                color: root._tx(0.12)
            }
            Text {
                anchors { left: parent.left; bottom: parent.bottom }
                width: parent.width * 0.5
                text: root.vlcConnected ? root.statusText : ""
                color: pal.mid
                font.pixelSize: 11
                elide: Text.ElideRight
            }
            Text {
                anchors { right: parent.right; bottom: parent.bottom }
                text: "Space play · ←/→ 3 s · [ ] offset"
                color: pal.mid
                font.pixelSize: 11
            }
        }
    }
}
