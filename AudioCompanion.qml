import MuseScore
import QtQuick
import QtQuick.Controls

MuseScore {
    id: root
    title: "QtMultimedia Probe"
    description: "Tests whether QtMultimedia is available in the MuseScore snap sandbox"
    pluginType: "dialog"
    width: 480
    height: 280

    // Results populated during onRun
    property string overallStatus: "Waiting..."
    property string volumeStatus: ""
    property string seekStatus: ""

    onRun: {
        var player = null

        // Attempt 1: instantiate MediaPlayer
        try {
            player = Qt.createQmlObject(
                'import QtMultimedia; MediaPlayer { autoPlay: false }',
                root,
                "probePlayer"
            )
        } catch (e) {
            var msg = "QtMultimedia: FAILED — " + e.toString()
            overallStatus = msg
            console.log("[AudioCompanion Probe] " + msg)
            return
        }

        if (!player) {
            var msg2 = "QtMultimedia: FAILED — Qt.createQmlObject returned null"
            overallStatus = msg2
            console.log("[AudioCompanion Probe] " + msg2)
            return
        }

        console.log("[AudioCompanion Probe] MediaPlayer instantiated successfully")
        overallStatus = "QtMultimedia: OK — MediaPlayer created successfully"

        var issues = []

        // Attempt 2: set volume (Qt 6 uses AudioOutput, but MediaPlayer.audioOutput
        // may still expose a volume shorthand depending on the Qt build)
        try {
            var ao = Qt.createQmlObject(
                'import QtMultimedia; AudioOutput { volume: 0.5 }',
                root,
                "probeAudioOutput"
            )
            if (ao) {
                player.audioOutput = ao
                volumeStatus = "volume (AudioOutput): OK"
                console.log("[AudioCompanion Probe] AudioOutput created and assigned")
            } else {
                volumeStatus = "volume (AudioOutput): null object"
                issues.push("AudioOutput null")
                console.log("[AudioCompanion Probe] AudioOutput: null object returned")
            }
        } catch (e) {
            volumeStatus = "volume (AudioOutput): FAILED — " + e.toString()
            issues.push("AudioOutput failed")
            console.log("[AudioCompanion Probe] AudioOutput error: " + e.toString())
        }

        // Attempt 3: seek (position is read/write when source is set; without a
        // source the call should still not throw if the API is present)
        try {
            player.position = 0
            seekStatus = "seek (.position = 0): OK"
            console.log("[AudioCompanion Probe] seek OK")
        } catch (e) {
            seekStatus = "seek (.position = 0): FAILED — " + e.toString()
            issues.push("seek failed")
            console.log("[AudioCompanion Probe] seek error: " + e.toString())
        }

        if (issues.length > 0) {
            overallStatus = "QtMultimedia: PARTIAL — loaded but " + issues.join(", ")
            console.log("[AudioCompanion Probe] PARTIAL: " + issues.join(", "))
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#f5f5f5"

        Column {
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                margins: 20
            }
            spacing: 12

            Text {
                text: "QtMultimedia Sandbox Probe"
                font.pixelSize: 16
                font.bold: true
                color: "#222"
            }

            Rectangle {
                width: parent.width
                height: 1
                color: "#ccc"
            }

            Text {
                id: overallLabel
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.overallStatus
                font.pixelSize: 13
                color: root.overallStatus.indexOf("OK") !== -1 ? "#1a7a1a"
                     : root.overallStatus.indexOf("PARTIAL") !== -1 ? "#a06000"
                     : root.overallStatus.indexOf("FAILED") !== -1 ? "#c00000"
                     : "#555"
            }

            Text {
                id: volumeLabel
                width: parent.width
                wrapMode: Text.WordWrap
                visible: root.volumeStatus !== ""
                text: root.volumeStatus
                font.pixelSize: 12
                color: root.volumeStatus.indexOf("OK") !== -1 ? "#1a7a1a" : "#c00000"
            }

            Text {
                id: seekLabel
                width: parent.width
                wrapMode: Text.WordWrap
                visible: root.seekStatus !== ""
                text: root.seekStatus
                font.pixelSize: 12
                color: root.seekStatus.indexOf("OK") !== -1 ? "#1a7a1a" : "#c00000"
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "See MuseScore log for full details:\n~/snap/musescore/current/.local/share/MuseScore/MuseScore4/logs/"
                font.pixelSize: 11
                color: "#777"
            }
        }

        Button {
            anchors {
                bottom: parent.bottom
                horizontalCenter: parent.horizontalCenter
                bottomMargin: 16
            }
            text: "Close"
            onClicked: quit()
        }
    }
}
