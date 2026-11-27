import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Dialogs
import QtQuick.Layouts
import org.kde.iconthemes as KIconThemes
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_refreshInterval: refreshSpin.value
    property alias cfg_colorizeIcon: colorizeCheck.checked
    property alias cfg_systemUptimeDisplay: uptimeDisplayCombo.currentIndex
    property alias cfg_useCustomInfoColor: customInfoColorCheck.checked
    property alias cfg_uptimeValueColor: uptimeColorRow.colorValue
    property alias cfg_tempColorByThreshold: tempThresholdCheck.checked
    property alias cfg_tempWarmThreshold: warmThresholdSpin.value
    property alias cfg_tempHotThreshold: hotThresholdSpin.value
    property alias cfg_useCustomTempColors: customTempColorsCheck.checked
    property alias cfg_tempCoolColor: coolColorRow.colorValue
    property alias cfg_tempWarmColor: warmColorRow.colorValue
    property alias cfg_tempHotColor: hotColorRow.colorValue
    // cfg_baseIconColor and cfg_iconName are handled manually below since
    // they need custom widgets (icon picker button, color swatch/dialog)
    // that plain aliases can't express.
    property string cfg_baseIconColor: "#c73aa8"
    property string cfg_iconName: "ksysguard"

    component InfoColorRow: RowLayout {
        id: colorRow

        property string colorValue: "#3daee9"
        property string defaultColor: "#3daee9"
        property string dialogTitle: i18n("Choose Color")

        spacing: Kirigami.Units.smallSpacing
        opacity: enabled ? 1 : 0.4

        Rectangle {
            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            radius: 4
            color: colorRow.colorValue
            border.color: Kirigami.Theme.disabledTextColor
            border.width: 1

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: rowColorDialog.open()
            }

        }

        QQC2.Button {
            text: i18n("Choose Color…")
            onClicked: rowColorDialog.open()
        }

        QQC2.ToolButton {
            icon.name: "edit-clear"
            text: i18n("Reset to default")
            display: QQC2.AbstractButton.IconOnly
            onClicked: colorRow.colorValue = colorRow.defaultColor
            QQC2.ToolTip.text: text
            QQC2.ToolTip.visible: hovered
        }

        ColorDialog {
            id: rowColorDialog

            title: colorRow.dialogTitle
            selectedColor: colorRow.colorValue
            onAccepted: colorRow.colorValue = selectedColor.toString()
        }

    }

    RowLayout {
        Kirigami.FormData.label: i18n("Panel icon:")
        spacing: Kirigami.Units.smallSpacing

        QQC2.Button {
            icon.name: page.cfg_iconName.length > 0 ? page.cfg_iconName : "ksysguard"
            text: i18n("Choose Icon…")
            onClicked: iconDialog.open()
        }

        QQC2.ToolButton {
            icon.name: "edit-clear"
            text: i18n("Reset to default")
            display: QQC2.AbstractButton.IconOnly
            onClicked: page.cfg_iconName = "ksysguard"
            QQC2.ToolTip.text: text
            QQC2.ToolTip.visible: hovered
        }

    }

    KIconThemes.IconDialog {
        id: iconDialog

        onIconNameChanged: (iconName) => {
            if (iconName.length > 0)
                page.cfg_iconName = iconName;

        }
    }

    QQC2.CheckBox {
        id: colorizeCheck

        Kirigami.FormData.label: i18n("Colourize icon:")
        text: i18n("Tint icon with a custom colour")
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Icon colour:")
        spacing: Kirigami.Units.smallSpacing
        enabled: colorizeCheck.checked
        opacity: colorizeCheck.checked ? 1 : 0.4

        Rectangle {
            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            radius: 4
            color: page.cfg_baseIconColor
            border.color: Kirigami.Theme.disabledTextColor
            border.width: 1

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: colorDialog.open()
            }

        }

        QQC2.Button {
            text: i18n("Choose Color…")
            onClicked: colorDialog.open()
        }

        QQC2.ToolButton {
            icon.name: "edit-clear"
            text: i18n("Reset to default")
            display: QQC2.AbstractButton.IconOnly
            onClicked: page.cfg_baseIconColor = "#c73aa8"
            QQC2.ToolTip.text: text
            QQC2.ToolTip.visible: hovered
        }

    }

    ColorDialog {
        id: colorDialog

        title: i18n("Choose Panel Icon Color")
        selectedColor: page.cfg_baseIconColor
        onAccepted: page.cfg_baseIconColor = selectedColor.toString()
    }

    QQC2.SpinBox {
        id: refreshSpin

        Kirigami.FormData.label: i18n("Refresh interval (seconds):")
        from: 1
        to: 60
    }

    QQC2.ComboBox {
        id: uptimeDisplayCombo
        Kirigami.FormData.label: i18n("System uptime display:")
        model: [
            i18n("Disabled"),
            i18n("Name Column Header"),
            i18n("Bottom Status Bar")
        ]
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Top Info Bar Colors")
    }

    QQC2.CheckBox {
        id: customInfoColorCheck

        Kirigami.FormData.label: i18n("Uptime value:")
        text: i18n("Use custom color (default: theme accent)")
    }

    InfoColorRow {
        id: uptimeColorRow

        Kirigami.FormData.label: i18n("Uptime color:")
        defaultColor: "#3daee9"
        dialogTitle: i18n("Choose Uptime Value Color")
        enabled: customInfoColorCheck.checked
    }

    QQC2.CheckBox {
        id: tempThresholdCheck

        Kirigami.FormData.label: i18n("Temperature colors:")
        text: i18n("Color by thermal thresholds")
    }

    QQC2.SpinBox {
        id: warmThresholdSpin

        Kirigami.FormData.label: i18n("Warm threshold (°C):")
        from: 30
        to: 110
        enabled: tempThresholdCheck.checked
        onValueModified: {
            if (hotThresholdSpin.value <= value)
                hotThresholdSpin.value = Math.min(hotThresholdSpin.to, value + 1);

        }
    }

    QQC2.SpinBox {
        id: hotThresholdSpin

        Kirigami.FormData.label: i18n("Hot threshold (°C):")
        from: 35
        to: 120
        enabled: tempThresholdCheck.checked
        onValueModified: {
            if (warmThresholdSpin.value >= value)
                warmThresholdSpin.value = Math.max(warmThresholdSpin.from, value - 1);

        }
    }

    QQC2.CheckBox {
        id: customTempColorsCheck

        Kirigami.FormData.label: i18n("Custom temp palette:")
        text: i18n("Use custom cool / warm / hot colors")
        enabled: tempThresholdCheck.checked
    }

    InfoColorRow {
        id: coolColorRow

        Kirigami.FormData.label: i18n("Cool color:")
        defaultColor: "#27ae60"
        dialogTitle: i18n("Choose Cool Temperature Color")
        enabled: tempThresholdCheck.checked && customTempColorsCheck.checked
    }

    InfoColorRow {
        id: warmColorRow

        Kirigami.FormData.label: i18n("Warm color:")
        defaultColor: "#f67400"
        dialogTitle: i18n("Choose Warm Temperature Color")
        enabled: tempThresholdCheck.checked && customTempColorsCheck.checked
    }

    InfoColorRow {
        id: hotColorRow

        Kirigami.FormData.label: i18n("Hot color:")
        defaultColor: "#da4453"
        dialogTitle: i18n("Choose Hot Temperature Color")
        enabled: tempThresholdCheck.checked && customTempColorsCheck.checked
    }

}
