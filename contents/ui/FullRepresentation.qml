import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Window
import org.kde.kirigami as Kirigami
import org.kde.ksysguard.process as Process
import org.kde.ksysguard.sensors as Sensors
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

Item {
    // exact fit

    id: root

    // row height mirrors the delegate formula
    readonly property int rowH: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing * 4
    readonly property int headerH: Math.ceil(Kirigami.Units.gridUnit * 1.8)
    readonly property int marginsH: Kirigami.Units.largeSpacing * 3 // top + bottom + gap
    // While the model is loading rows is empty; use a tall enough fallback
    // so Plasma never caches a 1-row height.  Once data arrives we snap to
    // the exact count.  minimumHeight == preferredHeight forces Plasma to
    // always respect this value even if it has a stale cached size.
    readonly property int popupHeight: {
        if (rows.length === 0)
            return Kirigami.Units.gridUnit * 20;

        var baseH = marginsH + headerH + rows.length * rowH;
        if ((root.uptimeDisplayMode !== 0 && root.systemUptimeStr !== "") || root.cpuTempStr !== "" || root.gpuTempStr !== "")
            baseH += Kirigami.Units.gridUnit * 1.5;

        return baseH;
    }
    readonly property int colName: 0
    readonly property int colIcon: 1
    readonly property int colCpu: 2
    readonly property int colMem: 3
    property int cpuCoreCount: 16
    property bool coreCountLoaded: false
    readonly property int refreshMs: Math.max(1000, (Plasmoid.configuration.refreshInterval || 3) * 1000)
    // Adjust these widths to your preference
    property int nameWidth: 300
    property int cpuWidth: 80
    property int memWidth: 100 // back to normal (no debug)
    readonly property bool isWindowVisible: root.Window.window ? root.Window.window.visible : false
    property string sortColumn: "cpu"
    property bool sortAscending: false
    property var rows: []
    property var vmRows: []
    property var browserProfileRows: []
    property var cachedDesktopIcons: ({})
    property var prevCpuTicks: ({})
    property real lastCpuPollTime: 0
    property bool firstUpdatePending: false
    property string systemUptimeStr: ""
    property string cpuTempStr: ""
    property string gpuTempStr: ""
    property real cpuTempVal: NaN
    property real gpuTempVal: NaN
    property bool hwmonChecked: false
    property bool hwmonCpuFound: false
    property bool hwmonGpuFound: false
    readonly property int uptimeDisplayMode: {
        var val = Plasmoid.configuration.systemUptimeDisplay;
        return (val === undefined) ? 2 : val;
    }
    readonly property bool useCustomInfoColor: Boolean(Plasmoid.configuration.useCustomInfoColor)
    readonly property color uptimeDataColor: {
        var custom = String(Plasmoid.configuration.uptimeValueColor || "").trim();
        return (useCustomInfoColor && custom.length > 0) ? custom : Kirigami.Theme.highlightColor;
    }
    readonly property bool tempColorByThreshold: {
        var val = Plasmoid.configuration.tempColorByThreshold;
        return (val === undefined) ? true : Boolean(val);
    }
    readonly property int tempWarmThreshold: {
        var val = Number(Plasmoid.configuration.tempWarmThreshold);
        return (!isNaN(val) && val > 0) ? Math.round(val) : 65;
    }
    readonly property int tempHotThreshold: {
        var val = Number(Plasmoid.configuration.tempHotThreshold);
        var hot = (!isNaN(val) && val > 0) ? Math.round(val) : 80;
        return Math.max(tempWarmThreshold + 1, hot);
    }
    readonly property bool useCustomTempColors: Boolean(Plasmoid.configuration.useCustomTempColors)
    readonly property color customCoolColor: {
        var c = String(Plasmoid.configuration.tempCoolColor || "").trim();
        return c.length > 0 ? c : "#27ae60";
    }
    readonly property color customWarmColor: {
        var c = String(Plasmoid.configuration.tempWarmColor || "").trim();
        return c.length > 0 ? c : "#f67400";
    }
    readonly property color customHotColor: {
        var c = String(Plasmoid.configuration.tempHotColor || "").trim();
        return c.length > 0 ? c : "#da4453";
    }

    function tempColorForValue(tempC) {
        if (!root.tempColorByThreshold || isNaN(tempC))
            return root.uptimeDataColor;

        if (tempC >= root.tempHotThreshold)
            return root.useCustomTempColors ? root.customHotColor : Kirigami.Theme.negativeTextColor;

        if (tempC >= root.tempWarmThreshold)
            return root.useCustomTempColors ? root.customWarmColor : Kirigami.Theme.neutralTextColor;

        return root.useCustomTempColors ? root.customCoolColor : Kirigami.Theme.positiveTextColor;
    }

    function resolveBrowserIcon(appTitle, wmClass, profName, fallbackIcon) {
        var desktopIcons = root.cachedDesktopIcons;
        var lookupKey = wmClass ? wmClass.toLowerCase() : (profName ? profName.toLowerCase() : "");
        if (lookupKey && desktopIcons[lookupKey])
            return desktopIcons[lookupKey];
        if (wmClass && desktopIcons["zen-" + lookupKey])
            return desktopIcons["zen-" + lookupKey];
        if (appTitle && desktopIcons[appTitle.toLowerCase()])
            return desktopIcons[appTitle.toLowerCase()];
        return fallbackIcon;
    }

    function parseMemoryBytes(str) {
        if (!str)
            return 0;

        var s = String(str).trim();
        var match = s.match(/^([\d.]+)\s*([A-Za-z]+)?/);
        if (!match)
            return 0;

        var num = parseFloat(match[1]);
        if (isNaN(num))
            return 0;

        var unit = (match[2] || "b").toLowerCase();
        var multiplier = 1;
        if (unit.indexOf("t") >= 0)
            multiplier = 1e+12;
        else if (unit.indexOf("g") >= 0)
            multiplier = 1e+09;
        else if (unit.indexOf("m") >= 0)
            multiplier = 1e+06;
        else if (unit.indexOf("k") >= 0)
            multiplier = 1000;
        return num * multiplier;
    }

    function parseLeadingNumber(str) {
        if (!str)
            return 0;

        var cleaned = String(str).replace(/[^0-9.-]/g, '');
        return parseFloat(cleaned) || 0;
    }

    function formatUptime(seconds) {
        var s = Math.floor(seconds);
        if (s < 60)
            return s + "s";

        var m = Math.floor(s / 60);
        s = s % 60;
        if (m < 60)
            return m + "m " + s + "s";

        var h = Math.floor(m / 60);
        m = m % 60;
        if (h < 24)
            return h + "h " + m + "m";

        var d = Math.floor(h / 24);
        h = h % 24;
        return d + "d " + h + "h";
    }

    function rebuildRows() {
        if (root.uptimeDisplayMode === 0)
            root.systemUptimeStr = "";

        var out = [];
        var handledBrowserTitles = {
        };
        if (root.browserProfileRows && root.browserProfileRows.length > 0) {
            for (var b = 0; b < root.browserProfileRows.length; b++) {
                var bRow = root.browserProfileRows[b];
                bRow.iconName = root.resolveBrowserIcon(bRow.appTitle, bRow.wmClass, bRow.profName, bRow.defaultIcon || bRow.iconName);
                out.push(bRow);
                if (bRow.appTitle) {
                    var tLower = bRow.appTitle.toLowerCase();
                    handledBrowserTitles[tLower] = true;
                    if (tLower.indexOf("zen") !== -1)
                        handledBrowserTitles["zen"] = true;

                    if (tLower.indexOf("firefox") !== -1)
                        handledBrowserTitles["firefox"] = true;

                    if (tLower.indexOf("chrome") !== -1)
                        handledBrowserTitles["chrome"] = true;

                    if (tLower.indexOf("brave") !== -1)
                        handledBrowserTitles["brave"] = true;

                }
            }
        }
        var n = appModel.rowCount();
        for (var i = 0; i < n; i++) {
            var nameIdx = appModel.index(i, root.colName);
            var iconIdx = appModel.index(i, root.colIcon);
            var cpuIdx = appModel.index(i, root.colCpu);
            var memIdx = appModel.index(i, root.colMem);
            var appName = String(appModel.data(nameIdx, Process.ProcessDataModel.Value) || "");
            var appLower = appName.toLowerCase();
            if ((handledBrowserTitles["zen"] && /\bzen\b/.test(appLower)) ||
                (handledBrowserTitles["firefox"] && /\bfirefox\b/.test(appLower)) ||
                (handledBrowserTitles["chrome"] && (/\b(google-)?chrome\b/.test(appLower) || /\bchromium\b/.test(appLower))) ||
                (handledBrowserTitles["brave"] && /\bbrave\b/.test(appLower)))
                continue;

            if (appLower.indexOf("xdg-permission-store") !== -1 || appLower.indexOf("session.slice") !== -1)
                continue;

            var iconName = String(appModel.data(iconIdx, Process.ProcessDataModel.Value) || "application-x-executable");
            var cpuRaw = String(appModel.data(cpuIdx, Process.ProcessDataModel.FormattedValue) || "0.0 %");
            var memFmt = String(appModel.data(memIdx, Process.ProcessDataModel.FormattedValue) || "–");
            var pids = appModel.data(nameIdx, Process.ProcessDataModel.PIDs) || [];
            var rawVal = root.parseLeadingNumber(cpuRaw);
            var scaledVal = rawVal / root.cpuCoreCount;
            if (isNaN(scaledVal) || !isFinite(scaledVal))
                scaledVal = 0;

            out.push({
                "appName": appName,
                "iconName": iconName,
                "cpuFmt": scaledVal.toFixed(1) + "%",
                "cpuRaw": scaledVal,
                "memFmt": memFmt,
                "memVal": root.parseMemoryBytes(memFmt),
                "pids": pids
            });
        }
        for (var j = 0; j < root.vmRows.length; j++) {
            out.push(root.vmRows[j]);
        }
        out.sort(function(a, b) {
            var res = 0;
            if (root.sortColumn === "name")
                res = a.appName.localeCompare(b.appName);
            else if (root.sortColumn === "cpu")
                res = a.cpuRaw - b.cpuRaw;
            else if (root.sortColumn === "mem")
                res = a.memVal - b.memVal;
            return root.sortAscending ? res : -res;
        });
        root.rows = out;
    }

    function parseVMs(stdout) {
        var lines = stdout.trim().split("\n");
        var temp = [];
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line)
                continue;

            var parts = line.split(/\s+/);
            if (parts.length < 4)
                continue;

            var pid = parseInt(parts[0]);
            var cpuRaw = parseFloat(parts[1]);
            var rssKb = parseFloat(parts[2]);
            var cmd = parts.slice(3).join(" ");
            var vmName = "QEMU VM";
            var match = cmd.match(/guest=([^,]+)/);
            if (match) {
                vmName = match[1];
            } else {
                match = cmd.match(/-name\s+([^\s,]+)/);
                if (match)
                    vmName = match[1];

            }
            var scaledCpu = cpuRaw / root.cpuCoreCount;
            if (isNaN(scaledCpu) || !isFinite(scaledCpu))
                scaledCpu = 0;

            var memGb = rssKb / (1024 * 1024);
            var memFmt = memGb >= 1 ? memGb.toFixed(1) + " GiB" : (rssKb / 1024).toFixed(0) + " MiB";
            temp.push({
                "appName": vmName + " (VM)",
                "iconName": "virt-manager",
                "cpuFmt": scaledCpu.toFixed(1) + "%",
                "cpuRaw": scaledCpu,
                "memFmt": memFmt,
                "memVal": rssKb * 1024,
                "pids": [pid]
            });
        }
        root.vmRows = temp;
        root.rebuildRows();
    }

    function parseBrowserProfiles(stdout) {
        if (!stdout) {
            root.browserProfileRows = [];
            root.rebuildRows();
            return ;
        }
        var psOutput = stdout;
        var now = Date.now();
        var dt = root.lastCpuPollTime > 0 ? Math.max(0.1, (now - root.lastCpuPollTime) / 1000) : 1;
        var nextCpuTicks = {
        };
        var lines = psOutput.trim().split("\n");
        var profiles = {
        };
        var pidToProfKey = {
        };
        var children = [];
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line)
                continue;

            var parts = line.split(/\s+/);
            if (parts.length < 5)
                continue;

            var pid = parseInt(parts[0]);
            var ppid = parseInt(parts[1]);
            var times = parseInt(parts[2]) || 0;
            var rssKb = parseFloat(parts[3]) || 0;
            var argStr = parts.slice(4).join(" ");
            // Compute real-time instantaneous CPU utilization for this process
            var prevTicks = (root.prevCpuTicks && root.prevCpuTicks[pid] !== undefined) ? root.prevCpuTicks[pid] : times;
            var tickDelta = Math.max(0, times - prevTicks);
            var cpuInst = (tickDelta / 100) / dt * 100;
            nextCpuTicks[pid] = times;
            if (argStr.indexOf("-contentproc") === -1 && argStr.indexOf("--type=") === -1) {
                var profName = "Default";
                var wmClass = "";
                var m = argStr.match(/--name\s+([^\s]+)/);
                if (m) {
                    profName = m[1];
                    wmClass = m[1];
                } else {
                    m = argStr.match(/-P\s+([^\s]+)/);
                    if (m) {
                        profName = m[1];
                    } else {
                        m = argStr.match(/-profile\s+([^\s]+)/);
                        if (m) {
                            var pPath = m[1].replace(/\/+$/, '');
                            var lastSlash = pPath.lastIndexOf("/");
                            profName = lastSlash >= 0 ? pPath.substring(lastSlash + 1) : pPath;
                        }
                    }
                }
                var appTitle = "Zen";
                var defaultIcon = "zen-browser";
                var exeName = (argStr.split(/\s+/)[0] || "").toLowerCase();
                if (exeName.indexOf("firefox") !== -1) {
                    appTitle = "Firefox";
                    defaultIcon = "firefox";
                } else if (exeName.indexOf("chrome") !== -1 || exeName.indexOf("chromium") !== -1) {
                    appTitle = "Chrome";
                    defaultIcon = "google-chrome";
                } else if (exeName.indexOf("brave") !== -1) {
                    appTitle = "Brave";
                    defaultIcon = "brave-browser";
                }
                var iconName = root.resolveBrowserIcon(appTitle, wmClass, profName, defaultIcon);
                var profKey = (appTitle + ":" + profName).toLowerCase();
                if (!profiles[profKey])
                    profiles[profKey] = {
                    "appName": appTitle + " (" + profName + ")",
                    "iconName": iconName,
                    "defaultIcon": defaultIcon,
                    "wmClass": wmClass,
                    "profName": profName,
                    "cpuRaw": 0,
                    "rssKb": 0,
                    "pids": [],
                    "appTitle": appTitle
                };

                profiles[profKey].cpuRaw += cpuInst;
                profiles[profKey].rssKb += rssKb;
                profiles[profKey].pids.push(pid);
                pidToProfKey[pid] = profKey;
            } else {
                var parentArg = null;
                var pm = argStr.match(/-parentPid\s+(\d+)/);
                if (pm)
                    parentArg = parseInt(pm[1]);

                children.push({
                    "pid": pid,
                    "ppid": ppid,
                    "parentArg": parentArg,
                    "cpu": cpuInst,
                    "rssKb": rssKb
                });
            }
        }
        root.prevCpuTicks = nextCpuTicks;
        root.lastCpuPollTime = now;
        for (var j = 0; j < children.length; j++) {
            var c = children[j];
            var matchedKey = (c.parentArg && pidToProfKey[c.parentArg]) ? pidToProfKey[c.parentArg] : (pidToProfKey[c.ppid] ? pidToProfKey[c.ppid] : null);
            if (matchedKey && profiles[matchedKey]) {
                profiles[matchedKey].cpuRaw += c.cpu;
                profiles[matchedKey].rssKb += c.rssKb;
                profiles[matchedKey].pids.push(c.pid);
            }
        }
        var temp = [];
        var keys = Object.keys(profiles);
        for (var k = 0; k < keys.length; k++) {
            var pObj = profiles[keys[k]];
            var scaledCpu = pObj.cpuRaw / root.cpuCoreCount;
            if (isNaN(scaledCpu) || !isFinite(scaledCpu))
                scaledCpu = 0;

            var memGb = pObj.rssKb / (1024 * 1024);
            var memFmt = memGb >= 1 ? memGb.toFixed(1) + " GiB" : (pObj.rssKb / 1024).toFixed(0) + " MiB";
            temp.push({
                "appName": pObj.appName,
                "iconName": pObj.iconName,
                "defaultIcon": pObj.defaultIcon,
                "wmClass": pObj.wmClass,
                "profName": pObj.profName,
                "cpuFmt": scaledCpu.toFixed(1) + "%",
                "cpuRaw": scaledCpu,
                "memFmt": memFmt,
                "memVal": pObj.rssKb * 1024,
                "pids": pObj.pids,
                "isBrowserProfile": true,
                "appTitle": pObj.appTitle
            });
        }
        root.browserProfileRows = temp;
        root.rebuildRows();
    }

    implicitWidth: Kirigami.Units.gridUnit * 32
    implicitHeight: popupHeight
    Layout.preferredWidth: implicitWidth
    Layout.minimumWidth: Kirigami.Units.gridUnit * 24
    Layout.preferredHeight: popupHeight
    Layout.minimumHeight: popupHeight
    Layout.maximumHeight: popupHeight
    function triggerRefresh() {
        systemInfoSource.fetch();
        vmSource.fetchVMs();
        browserProfileSource.fetchBrowserProfiles();
        root.rebuildRows();
    }

    onUptimeDisplayModeChanged: {
        if (uptimeDisplayMode === 0)
            root.systemUptimeStr = "";
        else
            systemInfoSource.fetch();
    }
    onIsWindowVisibleChanged: {
        if (isWindowVisible) {
            firstUpdatePending = true;
            triggerRefresh();
        } else {
            firstUpdatePending = false;
            dataUpdateTimer.stop();
        }
    }
    Component.onCompleted: {
        desktopIconSource.fetchIcons();
        triggerRefresh();
    }
    onSortColumnChanged: rebuildRows()
    onSortAscendingChanged: rebuildRows()

    Timer {
        id: structuralTimer

        interval: 25
        running: false
        repeat: false
        onTriggered: root.rebuildRows()
    }

    Timer {
        id: dataUpdateTimer

        interval: 250
        running: false
        repeat: false
        onTriggered: root.rebuildRows()
    }

    Process.ApplicationDataModel {
        id: appModel

        enabledAttributes: ["appName", "iconName", "usage", "memory"]
        enabled: true
        cgroupMapping: {
            "session.slice": "services",
            "background.slice": "services",
            "org.a11y.atspi.Registry": "services",
            "org.kde.discover.notifier": "services",
            "geoclue": "services",
            "org.kde.kunifiedpush": "services",
            "dconf.service": "services",
            "flatpak-session-helper.service": "services",
            "gpg-agent.service": "services",
            "org.kde.xwaylandvideobridge": "services",
            "org.kde.kalendarac": "services",
            "xdg-desktop-portal-gtk.service": "services",
            "org.kde.kdeconnect": "services",
            "org.kde.kwalletd6": "services",
            "org.kde.kclockd": "services",
            "ser@1000.service/session.slice/xdg-permission-store.service": "services",
            "xdg-permission-store.service": "services"
        }
        applicationOverrides: {
            "services": {
                "appName": i18nc("@label", "Background Services"),
                "iconName": "preferences-system-services"
            }
        }
        Component.onCompleted: root.rebuildRows()
        onModelReset: structuralTimer.restart()
        onRowsInserted: structuralTimer.restart()
        onRowsRemoved: structuralTimer.restart()
        onDataChanged: {
            if (!root.isWindowVisible)
                return;

            if (root.firstUpdatePending) {
                root.firstUpdatePending = false;
                structuralTimer.restart();
            } else if (!dataUpdateTimer.running) {
                dataUpdateTimer.start();
            }
        }
    }

    Timer {
        interval: root.refreshMs
        running: root.isWindowVisible
        repeat: true
        triggeredOnStart: false
        onTriggered: root.triggerRefresh()
    }

    Process.ProcessController {
        id: processController

        window: root.Window.window
    }

    Sensors.Sensor {
        sensorId: "cpu/all/coreCount"
        enabled: !root.coreCountLoaded
        onValueChanged: {
            if (value !== undefined && Number(value) > 0) {
                root.cpuCoreCount = Math.round(Number(value));
                root.coreCountLoaded = true;
            }
        }
    }

    // Fallback sensors only if /sys/class/hwmon lacks a matching CPU/GPU thermal device (e.g. proprietary NVIDIA)
    Sensors.Sensor {
        sensorId: "cpu/all/averageTemperature"
        updateRateLimit: root.cpuTempStr !== "" ? root.refreshMs : 0
        enabled: root.isWindowVisible && root.hwmonChecked && !root.hwmonCpuFound
        onValueChanged: {
            if (value !== undefined && !isNaN(value) && Number(value) > 0) {
                var c = Math.round(Number(value));
                root.cpuTempVal = c;
                root.cpuTempStr = c + "°C";
            }
        }
    }

    Sensors.Sensor {
        sensorId: "gpu/gpu0/temperature"
        updateRateLimit: root.gpuTempStr !== "" ? root.refreshMs : 0
        enabled: root.isWindowVisible && root.hwmonChecked && !root.hwmonGpuFound
        onValueChanged: {
            if (value !== undefined && !isNaN(value) && Number(value) > 0) {
                var g = Math.round(Number(value));
                root.gpuTempVal = g;
                root.gpuTempStr = g + "°C";
            }
        }
    }

    Plasma5Support.DataSource {
        id: systemInfoSource

        function fetch() {
            connectSource("read up _ < /proc/uptime 2>/dev/null || up=''; cpu_t=''; gpu_t=''; for d in /sys/class/hwmon/hwmon*; do read n < \"$d/name\" 2>/dev/null || continue; case \"$n\" in k10temp|coretemp|zenpower|zenergy) [ -z \"$cpu_t\" ] && { read cpu_t < \"$d/temp1_input\" 2>/dev/null || for tf in \"$d\"/temp*_input; do read cpu_t < \"$tf\" 2>/dev/null && break; done; } ;; amdgpu|radeon|nouveau|xe|i915) [ -z \"$gpu_t\" ] && { read gpu_t < \"$d/temp1_input\" 2>/dev/null || for tf in \"$d\"/temp*_input; do read gpu_t < \"$tf\" 2>/dev/null && break; done; } ;; esac; done; printf '%s|%s|%s\\n' \"$up\" \"$cpu_t\" \"$gpu_t\"");
        }

        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source);
            var stdout = (data["stdout"] || "").trim();
            var parts = stdout.split("|");
            if (parts.length >= 3) {
                if (root.uptimeDisplayMode !== 0) {
                    var upSec = parseFloat(parts[0]);
                    if (!isNaN(upSec) && upSec > 0)
                        root.systemUptimeStr = root.formatUptime(upSec);
                } else {
                    root.systemUptimeStr = "";
                }

                var cpuRaw = parseFloat(parts[1]);
                if (!isNaN(cpuRaw) && cpuRaw > 0) {
                    root.hwmonCpuFound = true;
                    var cpuC = Math.round(cpuRaw / 1000);
                    root.cpuTempVal = cpuC;
                    root.cpuTempStr = cpuC + "°C";
                }

                var gpuRaw = parseFloat(parts[2]);
                if (!isNaN(gpuRaw) && gpuRaw > 0) {
                    root.hwmonGpuFound = true;
                    var gpuC = Math.round(gpuRaw / 1000);
                    root.gpuTempVal = gpuC;
                    root.gpuTempStr = gpuC + "°C";
                }
            }
            root.hwmonChecked = true;
        }
    }

    Plasma5Support.DataSource {
        id: vmSource

        function fetchVMs() {
            connectSource("ps -C qemu-system-x86_64 -o pid,%cpu,rss,cmd --no-headers 2>/dev/null || true");
        }

        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source);
            var stdout = data["stdout"] || "";
            root.parseVMs(stdout);
        }
    }

    Plasma5Support.DataSource {
        id: desktopIconSource

        function fetchIcons() {
            connectSource("python3 -c \"import glob, os, re, json; icons = {}; [icons.update({wm.group(1).strip().lower(): ic.group(1).strip()}) for path in glob.glob(os.path.expanduser('~/.local/share/applications/*.desktop')) + glob.glob('/usr/share/applications/*.desktop') if os.path.exists(path) for content in [open(path, errors='ignore').read()] for wm in [re.search(r'^StartupWMClass=(.*)$', content, re.M)] if wm for ic in [re.search(r'^Icon=(.*)$', content, re.M)] if ic]; print(json.dumps(icons))\" 2>/dev/null || echo '{}'");
        }

        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source);
            try {
                var parsed = JSON.parse((data["stdout"] || "{}").trim() || "{}");
                if (parsed && typeof parsed === "object") {
                    root.cachedDesktopIcons = parsed;
                    if (root.browserProfileRows.length > 0)
                        root.rebuildRows();
                }
            } catch (e) {}
        }
    }

    Plasma5Support.DataSource {
        id: browserProfileSource

        function fetchBrowserProfiles() {
            connectSource("python3 -c \"import os\nnames = {'firefox','firefox-bin','chrome','google-chrome','chromium','brave','brave-browser'}\nprocs = []\nfor e in os.scandir('/proc'):\n    if not e.name.isdigit(): continue\n    pid = e.name\n    try:\n        with open(f'/proc/{pid}/cmdline', 'rb') as f: raw = f.read()\n        if not raw: continue\n        cmd = raw.replace(b'\\x00', b' ').decode('utf-8', 'ignore')\n        exe = cmd.split(None, 1)[0].lower() if cmd.strip() else ''\n        base = exe.rsplit('/', 1)[-1]\n        if not ('/zen/' in exe or base.startswith('zen') or base in names): continue\n        with open(f'/proc/{pid}/stat', 'r') as f: s = f.read()\n        ap = s[s.rfind(')')+2:].split()\n        if len(ap) < 22: continue\n        pss = int(ap[21]) * 4\n        try:\n            with open(f'/proc/{pid}/smaps_rollup', 'r') as f:\n                for line in f:\n                    if line.startswith('Pss:'):\n                        pss = int(line.split()[1]); break\n        except OSError: pass\n        procs.append(f'{pid} {int(ap[1])} {int(ap[11])+int(ap[12])} {pss} {cmd}')\n    except (OSError, ValueError): continue\nprint('\\n'.join(procs))\" 2>/dev/null || true");
        }

        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source);
            var stdout = data["stdout"] || "";
            root.parseBrowserProfiles(stdout);
        }
    }

    // ---------- UI ----------
    ColumnLayout {
        id: mainLayout

        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            id: topInfoRow

            Layout.fillWidth: true
            visible: (root.uptimeDisplayMode !== 0 && root.systemUptimeStr !== "") || root.cpuTempStr !== "" || root.gpuTempStr !== ""
            Layout.leftMargin: Kirigami.Units.smallSpacing * 2
            Layout.rightMargin: Kirigami.Units.smallSpacing * 2 + (Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2) / 2

            InfoMetric {
                id: uptimeLabel

                visible: root.uptimeDisplayMode !== 0 && root.systemUptimeStr !== ""
                nameText: i18n("Uptime:")
                valueText: root.systemUptimeStr
                valueColor: root.uptimeDataColor
            }

            Item {
                Layout.fillWidth: true
            }

            RowLayout {
                id: tempsGroup

                visible: root.cpuTempStr !== "" || root.gpuTempStr !== ""
                spacing: Kirigami.Units.largeSpacing

                InfoMetric {
                    id: cpuTempMetric

                    visible: root.cpuTempStr !== ""
                    nameText: i18n("CPU:")
                    valueText: root.cpuTempStr
                    valueColor: root.tempColorForValue(root.cpuTempVal)
                }

                InfoMetric {
                    id: gpuTempMetric

                    visible: root.gpuTempStr !== ""
                    nameText: i18n("GPU:")
                    valueText: root.gpuTempStr
                    valueColor: root.tempColorForValue(root.gpuTempVal)
                }

            }

        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.leftMargin: Kirigami.Units.smallSpacing * 2
            Layout.rightMargin: Kirigami.Units.smallSpacing * 2

            SortHeader {
                id: nameHeader

                Layout.fillWidth: true
                label: i18n("Process Name")
                col: "name"
                alignment: Qt.AlignLeft
                extraText: ""
                onSortClicked: {
                    if (root.sortColumn === "name") {
                        root.sortAscending = !root.sortAscending;
                    } else {
                        root.sortColumn = "name";
                        root.sortAscending = false;
                    }
                }
            }

            SortHeader {
                Layout.preferredWidth: root.cpuWidth
                label: i18n("CPU")
                col: "cpu"
                alignment: Qt.AlignRight
                onSortClicked: {
                    if (root.sortColumn === "cpu") {
                        root.sortAscending = !root.sortAscending;
                    } else {
                        root.sortColumn = "cpu";
                        root.sortAscending = false;
                    }
                }
            }

            SortHeader {
                Layout.preferredWidth: root.memWidth
                label: i18n("Memory")
                col: "mem"
                alignment: Qt.AlignRight
                onSortClicked: {
                    if (root.sortColumn === "mem") {
                        root.sortAscending = !root.sortAscending;
                    } else {
                        root.sortColumn = "mem";
                        root.sortAscending = false;
                    }
                }
            }

            Item {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }

        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ListView {
                id: listView

                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: root.rows
                spacing: 0

                Kirigami.PlaceholderMessage {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 4
                    visible: root.rows.length === 0
                    icon.name: "application-x-executable"
                    text: i18n("No running applications found")
                }

                delegate: Item {
                    id: delegateRoot

                    width: listView.width
                    height: Math.max(Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing * 4, row.implicitHeight)

                    HoverHandler {
                        id: delegateHover
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: 2
                        anchors.rightMargin: 2
                        color: Kirigami.Theme.highlightColor
                        opacity: delegateHover.hovered ? 0.08 : 0
                        radius: 4

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 100
                            }

                        }

                    }

                    RowLayout {
                        id: row

                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                        anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            source: modelData.iconName
                        }

                        QQC2.Label {
                            Layout.fillWidth: true
                            text: modelData.appName || i18n("Unknown")
                            elide: Text.ElideRight
                            font.weight: Font.Medium
                        }

                        QQC2.Label {
                            Layout.preferredWidth: root.cpuWidth
                            text: modelData.cpuFmt
                            horizontalAlignment: Text.AlignRight
                            font.features: {
                                "tnum": 1
                            }
                        }

                        QQC2.Label {
                            Layout.preferredWidth: root.memWidth
                            text: modelData.memFmt
                            horizontalAlignment: Text.AlignRight
                            font.features: {
                                "tnum": 1
                            }
                        }

                        QQC2.ToolButton {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2
                            icon.width: Kirigami.Units.iconSizes.smallMedium
                            icon.height: Kirigami.Units.iconSizes.smallMedium
                            icon.name: "process-stop"
                            display: QQC2.AbstractButton.IconOnly
                            text: i18n("Kill process")
                            enabled: modelData.pids && modelData.pids.length > 0
                            QQC2.ToolTip.text: i18n("Kill process")
                            QQC2.ToolTip.visible: hovered
                            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                            onClicked: {
                                if (modelData.pids && modelData.pids.length > 0) {
                                    killDialog.pids = modelData.pids;
                                    killDialog.open();
                                }
                            }
                        }

                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Kirigami.Theme.textColor
                        opacity: 0.15
                    }

                }

            }

            QQC2.ScrollBar {
                id: vertScrollBar

                Layout.fillHeight: true
                orientation: Qt.Vertical
                size: listView.visibleArea.heightRatio
                position: listView.visibleArea.yPosition
                active: listView.moving || vertScrollBar.hovered || vertScrollBar.pressed
                policy: QQC2.ScrollBar.AsNeeded
                onPositionChanged: {
                    if (active)
                        listView.contentY = position * listView.contentHeight;

                }
            }

        }

    }

    Kirigami.PromptDialog {
        id: killDialog

        property var pids: []

        title: i18n("Kill Process?")
        subtitle: i18n("Are you sure you want to terminate this process?")
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            if (pids && pids.length > 0)
                processController.sendSignal(pids, 9);

        }
    }

    component InfoMetric: RowLayout {
        id: metricRoot

        property string nameText: ""
        property string valueText: ""
        property color valueColor: Kirigami.Theme.highlightColor

        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            text: metricRoot.nameText
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.9
            font.italic: true
            color: Kirigami.Theme.textColor
            opacity: 0.78
        }

        QQC2.Label {
            text: metricRoot.valueText
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.9
            font.weight: Font.DemiBold
            font.features: {
                "tnum": 1
            }
            color: metricRoot.valueColor
        }

    }

    component SortHeader: Item {
        property string label: ""
        property string col: ""
        property int alignment: Qt.AlignLeft
        property string extraText: ""

        signal sortClicked()

        implicitHeight: Kirigami.Units.gridUnit * 1.8

        Rectangle {
            anchors.fill: parent
            color: Kirigami.Theme.highlightColor
            opacity: mouseArea.containsMouse ? 0.12 : 0
            radius: 4

            Behavior on opacity {
                NumberAnimation {
                    duration: 150
                }

            }

        }

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: alignment === Qt.AlignLeft ? Kirigami.Units.smallSpacing * 2 : 0
            anchors.rightMargin: alignment === Qt.AlignRight ? Kirigami.Units.smallSpacing * 2 : 0
            spacing: Kirigami.Units.smallSpacing

            Item {
                Layout.fillWidth: true
                visible: alignment === Qt.AlignRight
            }

            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Layout.alignment: alignment

                QQC2.Label {
                    text: label
                    color: mouseArea.containsMouse ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.95
                }

                QQC2.Label {
                    text: (root.sortColumn === col) ? (root.sortAscending ? "▲" : "▼") : ""
                    color: (root.sortColumn === col) ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.8
                    visible: root.sortColumn === col
                }

            }

            Item {
                Layout.fillWidth: true
                visible: alignment === Qt.AlignLeft && extraText !== ""
            }

            QQC2.Label {
                text: extraText
                visible: extraText !== ""
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.85
                font.italic: true
                color: Kirigami.Theme.textColor
                opacity: 0.8
            }

        }

        MouseArea {
            id: mouseArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sortClicked()
        }

    }

}
