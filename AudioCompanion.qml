import MuseScore
import QtQuick
import QtQuick.Controls

// v1.4.0
MuseScore {
    id: root
    title: "Audio Companion"
    description: "Plays an audio file in sync with score playback"
    version: "1.4.0"
    pluginType: "dialog"
    width: 520
    // MU4 plugin dialogs are fixed-size: the window ignores later width/height
    // changes and can't be resized, and "dock" plugins open as the same dialog.
    // Sized for the tallest case (VLC offline banner showing, panels expanded).
    height: 452

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

    // ── Qt Multimedia engine (default); VLC bridge below is the fallback ──
    // The vlc* functions are the engine-neutral audio API: each one dispatches
    // to the Qt MediaPlayer when useQt is set, else to VLC over HTTP.
    // Created dynamically so the plugin still loads without QtMultimedia.
    property bool useQt: false
    property var  qp: null     // MediaPlayer
    property var  qao: null    // AudioOutput

    function _initQtPlayer() {
        try {
            root.qao = Qt.createQmlObject('import QtMultimedia; AudioOutput {}', root, "qao")
            root.qp  = Qt.createQmlObject('import QtMultimedia; MediaPlayer {}', root, "qp")
            root.qp.audioOutput = root.qao
        } catch (e) {
            console.log("[AudioCompanion] QtMultimedia unavailable: " + e)
            root.qp = null
            return false
        }
        root.qp.errorOccurred.connect(function (err, msg) { root._qtFailed(msg) })
        root.qp.positionChanged.connect(function () {
            if (!root.useQt) return
            root.vlcPosition = Math.floor(root.qp.position / 1000)
            root._syncChecks(root.vlcState)
        })
        root.qp.mediaStatusChanged.connect(function () {
            if (root.useQt && root._pendingSeekMs >= 0 && root._qtReady()) {
                root.qp.position = root._pendingSeekMs
                root._pendingSeekMs = -1
            }
        })
        root.qp.durationChanged.connect(function () {
            if (root.useQt) root.vlcLength = Math.floor(root.qp.duration / 1000)
        })
        root.qp.playbackStateChanged.connect(function () {
            if (!root.useQt) return
            var prev = root.vlcState
            var st = root.qp.playbackState   // 0 stopped, 1 playing, 2 paused
            root.vlcState  = st === 1 ? "playing" : (st === 2 ? "paused" : "stopped")
            root.isPlaying = (st === 1)
            if (st === 0) root.vlcPosition = 0
            root._setQtStatus()
            root._syncChecks(prev)
        })
        root.useQt = true
        root.vlcConnected = true
        root._vlcEverPolled = true
        root._vlcSynced = true
        root._setQtStatus()
        return true
    }

    function _setQtStatus() {
        if (root.vlcState === "playing")      root.statusText = "▶  " + root.fileName
        else if (root.vlcState === "paused")  root.statusText = "⏸  " + root.fileName
        else root.statusText = "v" + version + " — " + (root.fileName || "Ready")
    }

    // Any Qt Multimedia error (no backend, unsupported codec…) → switch to VLC.
    function _qtFailed(msg) {
        if (!root.useQt) return
        console.log("[AudioCompanion] QtMultimedia error, falling back to VLC: " + msg)
        root.useQt = false
        if (root.qp) root.qp.stop()
        root.vlcConnected = false
        root.vlcState = "stopped"
        root.isPlaying = false
        root._vlcEverPolled = false
        root.statusText = "Audio engine error (" + msg + ") — using VLC"
        root._vlcGet("", function (ok, xml) {
            root._vlcEverPolled = true
            if (ok) root._parseVlc(xml); else root._tryLaunchVlc()
        })
    }

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
        if (useQt) {
            var src = "file://" + filePath
            if (qp.source.toString() !== src) qp.source = src
            qp.play()
            applyRate()
            return
        }
        var input = encodeURIComponent("file://" + filePath)
        _vlcGet("command=in_play&input=" + input, function (ok, xml) {
            if (ok) {
                _parseVlc(xml); applyRate()
                if (root._pendingSeekMs >= 0) { var ms = root._pendingSeekMs; root._pendingSeekMs = -1; vlcSeek(ms) }
            }
            else root.statusText = "VLC not responding"
        })
    }

    function vlcTogglePause() {
        if (useQt) {
            if (qp.playbackState === 1) qp.pause()
            else if (qp.playbackState === 2) qp.play()
            return
        }
        _vlcGet("command=pl_pause", function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    function vlcStop() {
        if (useQt) { qp.stop(); return }
        _vlcGet("command=pl_stop", function (ok, xml) {
            if (ok) _parseVlc(xml)
            root.isPlaying = false
        })
    }

    // Qt can only seek once media is loaded (2 Loaded .. 6 EndOfMedia); earlier
    // seeks are parked in _pendingSeekMs and applied by mediaStatusChanged.
    property real _pendingSeekMs: -1
    function _qtReady() {
        var st = qp.mediaStatus
        return st >= 2 && st <= 6
    }

    function vlcSeek(ms) {
        ms = Math.max(0, Math.round(ms))
        if (useQt) {
            var src = "file://" + filePath
            if (filePath !== "" && qp.source.toString() !== src) qp.source = src
            if (_qtReady()) qp.position = ms
            else _pendingSeekMs = ms
            root.vlcPosition = Math.floor(ms / 1000)
            return
        }
        // VLC can't seek an input that isn't playing: apply it right after the next play.
        if (root.vlcState === "stopped") { _pendingSeekMs = ms; return }
        _vlcGet("command=seek&val=" + Math.round(ms / 1000) + "s",
                function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    function vlcVolume(v) {
        if (useQt) { qao.volume = v; return }
        _vlcGet("command=volume&val=" + Math.round(v * 256),
                function (ok, xml) { if (ok) _parseVlc(xml) })
    }

    function vlcRate(r) {
        if (useQt) { qp.playbackRate = r; return }
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

    // Engine-neutral checks run after every status update.
    function _syncChecks(prevVlcState) {
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
    }

    function pollVlc() {
        if (useQt) return
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
                root._syncChecks(prevVlcState)
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

    // ── Cursor sync ───────────────────────────────────────────────────────
    // Verified on 4.7.4 (see CLAUDE.md): the plugin can read the selected tick and
    // move the selection, but there is no live playback position. So the audio is
    // aligned to the cursor at rest and at Play time only; there is no drift correction.
    // Alignment: audio time = score time − offsetMs (same convention as transportPlay).
    property bool syncCursor: true     // follow the score cursor (Both mode)
    property var  _tempoMap: [{ tick: 0, ms: 0, bps: 2 }]
    property int  _selTick: -1
    property string syncInfo: ""
    property bool tempoMismatch: false
    readonly property int ticksPerQuarter: 480

    onSyncCursorChanged: { root._selTick = -1; saveScoreSettings() }

    // Tempo map from the score's tempo texts (TEMPO_TEXT.tempo is quarter notes per
    // second). Gradual changes (rit./accel.) and repeats are not modelled; the result is
    // compared with curScore.duration and flagged when it disagrees.
    function _buildTempoMap() {
        var found = []
        var endTick = 0
        try {
            var c = curScore.newCursor()
            c.rewind(Cursor.SCORE_START)
            var n = 0
            while (c.segment && n < 50000) {
                var anns = c.segment.annotations
                for (var i = 0; anns && i < anns.length; i++) {
                    if (anns[i].type === Element.TEMPO_TEXT && anns[i].tempo > 0)
                        found.push({ tick: c.tick, bps: anns[i].tempo })
                }
                if (!c.next()) break
                n++
            }
            endTick = curScore.lastSegment ? curScore.lastSegment.tick : 0
        } catch (e) {
            console.log("[AudioCompanion] tempo map failed: " + e)
        }
        var pts = [{ tick: 0, ms: 0, bps: 2 }]      // MuseScore's default is 120 bpm
        for (var j = 0; j < found.length; j++) {
            var last = pts[pts.length - 1]
            if (found[j].tick === last.tick) { last.bps = found[j].bps; continue }
            pts.push({ tick: found[j].tick, bps: found[j].bps,
                       ms: last.ms + (found[j].tick - last.tick) / ticksPerQuarter / last.bps * 1000 })
        }
        root._tempoMap = pts
        var dur = 0
        try { dur = curScore.duration } catch (e2) {}
        var est = _tickToMs(endTick) / 1000
        root.tempoMismatch = dur > 0 && endTick > 0 && Math.abs(est - dur) > Math.max(1, dur * 0.01)
    }

    function _tickToMs(tick) {
        var pts = root._tempoMap
        var i = pts.length - 1
        while (i > 0 && pts[i].tick > tick) i--
        return pts[i].ms + (tick - pts[i].tick) / ticksPerQuarter / pts[i].bps * 1000
    }

    function _msToTick(ms) {
        var pts = root._tempoMap
        var i = pts.length - 1
        while (i > 0 && pts[i].ms > ms) i--
        return pts[i].tick + (ms - pts[i].ms) / 1000 * pts[i].bps * ticksPerQuarter
    }

    // Tick of the selected note/range start, or -1 when nothing usable is selected.
    function _selectionTick() {
        try {
            if (!curScore) return -1
            var sel = curScore.selection
            if (sel.isRange) return sel.startSegment ? sel.startSegment.tick : -1
            var els = sel.elements
            if (!els || els.length === 0) return -1
            var e = els[0]
            for (var i = 0; e && i < 6; i++) {
                if (e.name === "Segment") return e.tick
                e = e.parent
            }
        } catch (ex) {}
        return -1
    }

    function _fmtMs(ms) {
        var t = Math.max(0, Math.round(ms / 100))
        var m = Math.floor(t / 600)
        var sec = (t % 600) / 10
        return m + ":" + (sec < 10 ? "0" : "") + sec.toFixed(1)
    }

    function _seekAudioToTick(tick) {
        var scoreMs = _tickToMs(tick)
        // Tick 0 keeps the normal start (a negative offset lets the audio lead in).
        var audioMs = tick === 0 ? 0 : Math.max(0, scoreMs - root.offsetMs)
        vlcSeek(audioMs)
        root.syncInfo = "Cursor " + _fmtMs(scoreMs) + " → audio " + _fmtMs(audioMs)
    }

    function pollCursor() {
        if (!root.syncCursor || root.playMode !== "both" || !root.canSeek) return
        if (root._scoreIsPlaying || root.vlcState === "playing") return
        var t = _selectionTick()
        if (t < 0 || t === root._selTick) return
        root._selTick = t
        if (root._scorePaused) root._cursorMovedWhilePaused = true
        _buildTempoMap()
        _seekAudioToTick(t)
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
        root._scorePaused = false
        root._cursorMovedWhilePaused = false

        var delay = root.offsetMs

        // Cursor sync: MuseScore plays from the selected note, so start the audio at the
        // matching point. Read the selection fresh rather than trusting an earlier seek.
        if (scoreEnabled && audioEnabled && root.syncCursor) {
            var startTick = _selectionTick()
            if (startTick > 0) {
                _buildTempoMap()
                var p = _tickToMs(startTick) - delay
                if (p >= 0) {
                    vlcSeek(p)
                    cmd("play")
                    vlcPlay()
                } else {
                    // Audio hasn't started yet at this score position: wait out the gap.
                    vlcSeek(0)
                    cmd("play")
                    _delayTarget = "vlc"
                    delayTimer.interval = -p
                    delayTimer.restart()
                }
                return
            }
            if (startTick === 0) vlcSeek(0)
        }
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
        // Resuming after the cursor was moved while paused: MuseScore would carry on from
        // the pause point, so restart both from the new cursor instead.
        if (root._scorePaused && root._cursorMovedWhilePaused && playMode === "both") {
            root._cursorMovedWhilePaused = false
            cmd("stop")
            vlcStop()
            root._scorePaused = false
            transportPlay()
            return
        }
        // Guard: cmd("play") in MU4 is a toggle — calling it on a stopped score
        // would restart it. Only send it if we know the score is currently playing.
        // _scorePaused remembers that we paused it, so the same call resumes it and the
        // button flips back to play.
        if (playMode !== "audio") {
            if (root._scoreIsPlaying) {
                cmd("play")
                root._scoreIsPlaying = false
                root._scorePaused = true
            } else if (root._scorePaused) {
                cmd("play")
                root._scoreIsPlaying = true
                root._scorePaused = false
            }
        }
        if (playMode !== "score") vlcTogglePause()
        delayTimer.stop()
    }

    function transportStop() {
        if (playMode !== "audio") cmd("stop")
        if (playMode !== "score") vlcStop()
        delayTimer.stop()
        root._scoreIsPlaying = false
        root._scorePaused = false
        root._cursorMovedWhilePaused = false
    }

    function transportRewind() {
        if (playMode !== "audio") {
            cmd("rewind")
            // Drop the selection so Play isn't taken from a stale cursor position.
            try { if (curScore) curScore.selection.clear() } catch (e) {}
            root._selTick = -1
        }
        if (playMode !== "score") vlcSeek(0)
    }

    function togglePlayPause() {
        if (!canPlay) return
        var active = root._scoreIsPlaying || root._scorePaused || root.isPlaying || root.vlcState === "paused"
        if (!active) transportPlay()
        else transportPause()
    }

    // ── Runtime state ─────────────────────────────────────────────────────
    property string filePath: ""
    property string fileName: ""
    property bool   isPlaying: false
    property bool   _scoreIsPlaying: false   // tracks whether we started score playback
    property bool   _scorePaused: false      // we paused score playback and can resume it
    property bool   _cursorMovedWhilePaused: false
    property string statusText: "v" + version + " — Ready"
    property string currentScoreKey: ""
    property var    fileDialog: null
    property string _delayTarget: ""
    property int    vlcPosition: 0
    property int    vlcLength: 0
    property bool   _vlcLaunched: false
    property bool   _vlcWeStarted: false   // only stop a VLC we launched
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
        // Handled by the audiocompanion:// scheme handler from install/.
        Qt.openUrlExternally("audiocompanion://start")
        _vlcWeStarted = true
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
        root.syncCursor  = s && s.follow !== undefined ? s.follow : true
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
        map[key] = { delayMs: root.offsetMs, volume: root.audioVolume, mode: root.playMode, follow: root.syncCursor }
        _cfgSet("scoreSettings", JSON.stringify(map))
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    onRun: {
        _initSettings()
        root.showPanels = _cfgGet("showPanels", 1) !== 0
        refreshRecent()
        pollTheme()

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
        if (curScore) _buildTempoMap()
        root._selTick = -1
        if (_initQtPlayer()) return
        // QtMultimedia missing: fall back to VLC.
        _vlcGet("", function(ok, xml) {
            root._vlcEverPolled = true
            if (ok) { _parseVlc(xml) } else { _tryLaunchVlc() }
        })
    }

    Component.onDestruction: {
        root.vlcRate(1)
        root.vlcStop()
        if (root._vlcWeStarted) Qt.openUrlExternally("audiocompanion://stop")
    }

    onScoreStateChanged: {
        var key = scoreKey()
        if (key !== currentScoreKey) {
            transportStop()
            loadForScore()
            _buildTempoMap()
            root._selTick = -1
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
        interval: 200
        repeat: true
        running: root.syncCursor && root.playMode === "both"
        onTriggered: root.pollCursor()
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

    SystemPalette { id: sys; colorGroup: SystemPalette.Active }

    // ── MuseScore theme ───────────────────────────────────────────────────
    // The plugin API doesn't expose the app theme, so read the theme code
    // (ui/application/currentThemeCode) from MuseScore's own settings file.
    // That file is shared in-process with MuseScore's settings, so changes are
    // seen live. If it can't be read, fall back to the system palette.
    property string themeCode: ""
    property string _themeIni: ""

    // [background, text, accent, surface] from MuseScore's src/app/configs/*.cfg
    function _themeColors(code) {
        var defs = {
            "light":               ["#F5F5F6", "#111132", "#62B1FA", "#E6E9ED"],
            "dark":                ["#2D2D30", "#EBEBEB", "#2082DD", "#363638"],
            "high_contrast_black": ["#000000", "#FFFD38", "#0071DA", "#000000"],
            "high_contrast_white": ["#FFFFFF", "#1E0073", "#00D87D", "#FFFFFF"]
        }
        var d = defs[code]
        if (!d) return null
        var text = Qt.color(d[1])
        var accent = Qt.color(d[2])
        var lum = 0.299 * accent.r + 0.587 * accent.g + 0.114 * accent.b
        return {
            bg: Qt.color(d[0]),
            text: text,
            accent: accent,
            surface: Qt.color(d[3]),
            muted: Qt.rgba(text.r, text.g, text.b, 0.6),
            onAccent: lum > 0.55 ? Qt.color("#111132") : Qt.color("#FFFFFF")
        }
    }

    function _homeDir() {
        var m = Qt.resolvedUrl(".").toString().match(/^file:\/\/(.*)\/Documents\/MuseScore4\/Plugins\//)
        return m ? decodeURIComponent(m[1]) : ""
    }

    function _readThemeCodeFrom(path) {
        var heads = ['import QtCore\n', 'import Qt.labs.settings\n']
        for (var i = 0; i < heads.length; i++) {
            try {
                var s = Qt.createQmlObject(heads[i] + 'Settings { category: "ui"; fileName: "' + path + '" }',
                                           root, "themeProbe")
                var v = s.value("application/currentThemeCode", "")
                s.destroy()
                if (v) return String(v)
                return ""
            } catch (e) {}
        }
        return ""
    }

    function pollTheme() {
        var home = _homeDir()
        if (home === "") return
        var paths = _themeIni !== "" ? [_themeIni] : [
            home + "/.var/app/org.musescore.MuseScore/config/MuseScore/MuseScore4.ini",   // Flatpak
            home + "/snap/musescore/current/.config/MuseScore/MuseScore4.ini",            // Snap (unverified)
            home + "/.config/MuseScore/MuseScore4.ini"                                    // native
        ]
        for (var i = 0; i < paths.length; i++) {
            var code = _readThemeCodeFrom(paths[i])
            if (code !== "") {
                _themeIni = paths[i]
                if (code !== themeCode) themeCode = code
                return
            }
        }
        if (themeCode !== "") themeCode = ""
    }

    Timer {
        interval: 2000
        repeat: true
        running: true
        onTriggered: root.pollTheme()
    }

    // Colour set the UI binds to. Same property names as SystemPalette so the
    // controls read the same either way.
    QtObject {
        id: pal
        readonly property var t: root._themeColors(root.themeCode)
        readonly property color window:          t ? t.bg      : sys.window
        readonly property color text:            t ? t.text    : sys.text
        readonly property color mid:             t ? t.muted   : sys.mid
        readonly property color highlight:       t ? t.accent  : sys.highlight
        readonly property color highlightedText: t ? t.onAccent : sys.highlightedText
        readonly property color alternateBase:   t ? t.surface : sys.alternateBase
    }

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
        SystemPalette { id: bsys }

        // Theme colours come from the nearest ancestor exposing `themeHolder`; popups
        // aren't in the content tree, so they set `th` explicitly.
        property var th: null
        readonly property var bp: th ? th : _find()
        function _find() {
            var p = b.parent
            while (p && p.themeHolder === undefined) p = p.parent
            return p ? p.themeHolder : bsys
        }

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
        SystemPalette { id: ssys }

        readonly property var sp: _find()
        function _find() {
            var p = s.parent
            while (p && p.themeHolder === undefined) p = p.parent
            return p ? p.themeHolder : ssys
        }

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
        property var themeHolder: pal

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
                                    th: pal
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
                            text: root.useQt ? "Audio ready"
                                : root.vlcConnected ? "VLC connected"
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
                        text: "HTTP " + root.vlcHttp + " on port 9091. Run the installer in the plugin's install/ folder, then retry."
                        color: pal.text
                        font.pixelSize: 11
                    }
                }
                PBtn {
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "Retry"
                    onClicked: root._tryLaunchVlc()
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

            Text {
                width: parent.width
                color: root.tempoMismatch ? "#c07000" : pal.mid
                font.pixelSize: 11
                elide: Text.ElideRight
                text: (root.syncInfo !== "" ? root.syncInfo : "Cursor sync: select a note to align the audio")
                      + (root.tempoMismatch ? "  ·  tempo map ≠ score length (repeats / rit.?)" : "")
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

                        Row {
                            spacing: 4
                            PBtn {
                                text: "Reset"
                                implicitHeight: 24
                                font.pixelSize: 11
                                enabled: root.offsetMs !== 0
                                onClicked: root.setOffset(0)
                            }
                            PBtn {
                                text: "Follow"
                                implicitHeight: 24
                                font.pixelSize: 11
                                highlighted: root.syncCursor
                                ToolTip.visible: hovered
                                ToolTip.text: "Both mode: seek the audio when you move the score cursor"
                                onClicked: root.syncCursor = !root.syncCursor
                            }
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
