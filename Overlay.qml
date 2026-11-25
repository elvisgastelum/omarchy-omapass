import QtQuick

// Placeholder: the skeleton ticket OPA-8 replaces this file.
Item {
    property bool opened: false

    function open(payloadJson) {
        opened = true
    }

    function close() {
        opened = false
    }

    function toggle() {
        opened = !opened
    }
}
