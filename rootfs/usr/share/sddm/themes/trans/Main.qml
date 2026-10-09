// SDDM login screen in the trans pride colours of Waybar, Wofi and Mako.
// SDDM provides sddm (login, reboot, power off), userModel, sessionModel,
// keyboard and primaryScreen. Preview it without logging out:
//   sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/trans
import QtQuick
import QtQuick.Controls.Basic

Pane {
    id: root
    width: 1920; height: 1080   // preview size; SDDM stretches it to the screen
    padding: 0
    font { family: "Noto Sans"; pixelSize: 15 }
    background: Rectangle { color: "#1a1621" }

    // Every control below takes its colours from here
    palette {
        window: "#2a2233"            // session list popup
        windowText: "#fdf2f6"
        base: "#1a1621"              // text fields
        text: "#fdf2f6"
        placeholderText: "#8a7f96"
        button: "#2a2233"
        buttonText: "#fdf2f6"
        mid: "#3a3044"               // hovered button
        light: "#f5a9b8"             // highlighted entry in the session list
        midlight: "#f5a9b8"
        dark: "#8a7f96"              // combo box arrow, popup border
        highlight: "#5bcefa"         // focus outline, text selection
        highlightedText: "#1a1621"
    }

    component Field: TextField {
        id: field
        width: parent.width
        leftPadding: 12; rightPadding: 12
        background: Rectangle {
            implicitHeight: 42
            radius: 8
            color: field.palette.base
            border { width: 2; color: field.activeFocus ? field.palette.highlight : field.palette.base }
        }
    }

    component FlatButton: Button {
        id: flat
        background: Rectangle {
            implicitWidth: 110; implicitHeight: 40
            radius: 8
            color: flat.down || flat.hovered ? flat.palette.mid : flat.palette.button
            border { width: flat.visualFocus ? 2 : 0; color: flat.palette.highlight }
        }
    }

    function login() {
        message.text = ""
        sddm.login(user.text, password.text, session.currentIndex)
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            password.text = ""
            message.text = "Wrong user name or password"
            password.forceActiveFocus()
        }
    }

    // Clock (white stripe) and date (pink stripe) above the card
    Column {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: card.top; bottomMargin: 40 }
        Text {
            id: clock
            anchors.horizontalCenter: parent.horizontalCenter
            color: "#ffffff"
            font { family: "Noto Sans"; pixelSize: 96; bold: true }
        }
        Text {
            id: date
            anchors.horizontalCenter: parent.horizontalCenter
            color: "#f5a9b8"
            font { family: "Noto Sans"; pixelSize: 22 }
        }
        Timer {
            interval: 1000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: {
                const now = new Date()
                clock.text = Qt.formatTime(now, "HH:mm")
                date.text = Qt.formatDate(now, "dddd, d MMMM")
            }
        }
    }

    Rectangle {
        id: card
        visible: primaryScreen
        anchors.centerIn: parent
        width: 380
        height: form.implicitHeight + 56
        radius: 12
        color: "#2a2233"
        border { width: 2; color: "#f5a9b8" }

        Column {
            id: form
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 28 }
            spacing: 12

            // A tiny flag, like the active workspace in Waybar
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                bottomPadding: 6
                Repeater {
                    model: ["#5bcefa", "#f5a9b8", "#ffffff", "#f5a9b8", "#5bcefa"]
                    Rectangle { width: 60; height: 7; color: modelData }
                }
            }

            Field {
                id: user
                placeholderText: "User"
                text: userModel.lastUser
                onAccepted: password.forceActiveFocus()
            }
            Field {
                id: password
                placeholderText: "Password"
                echoMode: TextInput.Password
                onAccepted: root.login()
            }

            // Only shown when there is something to choose besides Hyprland
            ComboBox {
                id: session
                visible: count > 1
                width: parent.width
                model: sessionModel
                textRole: "name"
                currentIndex: sessionModel.lastIndex
                background: Rectangle {
                    implicitHeight: 42
                    radius: 8
                    color: session.palette.base
                    border { width: 2; color: session.visualFocus ? session.palette.highlight : session.palette.base }
                }
            }

            Button {
                id: loginButton
                width: parent.width
                text: "Log in"
                onClicked: root.login()
                contentItem: Text {
                    text: loginButton.text
                    color: "#1a1621"
                    font { family: "Noto Sans"; pixelSize: 15; bold: true }
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    implicitHeight: 42
                    radius: 8
                    opacity: loginButton.down ? 0.8 : 1
                    border { width: loginButton.visualFocus ? 2 : 0; color: "#ffffff" }
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "#5bcefa" }
                        GradientStop { position: 1; color: "#f5a9b8" }
                    }
                }
            }

            Text {
                id: message
                visible: text !== ""
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                color: "#ff7aa2"
                font { family: "Noto Sans"; pixelSize: 14 }
            }
            Text {
                visible: keyboard.capsLock
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Caps Lock is on"
                color: "#5bcefa"
                font { family: "Noto Sans"; pixelSize: 14 }
            }
        }
    }

    // Until the first login SDDM has no last user: fill in the first (only) one
    Repeater {
        model: userModel.lastUser ? 0 : userModel
        Item {
            Component.onCompleted: if (index === 0) {
                user.text = model.name
                password.forceActiveFocus()
            }
        }
    }

    Row {
        visible: primaryScreen
        anchors { right: parent.right; bottom: parent.bottom; margins: 24 }
        spacing: 8
        FlatButton { text: "Reboot";    visible: sddm.canReboot;   onClicked: sddm.reboot() }
        FlatButton { text: "Shut down"; visible: sddm.canPowerOff; onClicked: sddm.powerOff() }
    }

    // Last user is filled in, so the cursor waits in the password field
    Component.onCompleted: (user.text ? password : user).forceActiveFocus()
}
