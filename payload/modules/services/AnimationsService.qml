pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config
import qs.modules.services
import "AnimationsLogic.js" as Logic

/**
 * Animation Studio service.
 *
 * Owns the user's curves/animations, persists them, and pushes them into the
 * running Hyprland through the daemon's `compositor.eval` (one Lua statement
 * per call — the batch pipeline splits on ';').
 *
 * Why it exists as a layer on top of axctl instead of editing axctl.toml:
 * the [appearance.animations] table only carries `enabled` and
 * `workspace_style`; the curve and per-leaf timings in the generated
 * hyprland.lua are hard-coded inside axctl.
 *
 * Reload safety, in order of strength:
 *   1. Optional loader block in ~/.config/hypr/hyprland.lua (installLoader)
 *      makes every config evaluation load animations.lua last.
 *   2. Without it, the service re-applies after axctl.toml / hyprland.lua
 *      change (axctl regenerated + reloaded), after GameMode ends, and on
 *      shell start.
 */
Singleton {
    id: root

    // ---- paths -----------------------------------------------------------
    readonly property string home: Quickshell.env("HOME")
    readonly property string configPath: Config.configDir + "/animations.json"
    readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")) + "/ambxst"
    readonly property string luaPath: dataDir + "/animations.lua"
    readonly property string hyprDir: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/hypr"
    readonly property string hyprLuaPath: hyprDir + "/hyprland.lua"

    // ---- state -----------------------------------------------------------
    property var config: Logic.emptyConfig()
    property bool loaded: false
    property var errors: []                 // Logic.validate() output
    property string luaPreview: ""          // what animations.lua contains
    property bool ready: loaded             // referenced from shell.qml to force init

    // apply pipeline: idle | applying | ok | error | blocked | gamemode
    property string applyState: "idle"
    property string applySummary: ""
    property var applyResults: []           // [{ label, ok, message }]
    property bool unapplied: false          // edits not yet pushed to the compositor

    // hyprland.lua loader: unknown | installed | absent | missing | managed
    property string loaderState: "unknown"
    property string loaderMessage: ""

    readonly property string barPosition: (Config.bar && Config.bar.position) ? Config.bar.position : "top"
    readonly property var context: ({ barPosition: root.barPosition })
    readonly property bool hasErrors: errors.length > 0

    // ---- public API ------------------------------------------------------

    // Mutate a private clone of the config. The mutator edits it in place.
    function update(mutator) {
        const next = Logic.clone(root.config);
        mutator(next);
        root._commit(next, true);
    }

    function replace(next) {
        root._commit(Logic.normalize(next), true);
    }

    function setEnabled(value) {
        if (!value && root.config.enabled) {
            // Turning off: put axctl's animations back right away.
            root.restoreDefaults();
            return;
        }
        root.update(c => { c.enabled = value; });
    }

    function loadPreset(id) {
        const cfg = Logic.presetConfig(id);
        if (cfg) {
            cfg.autoApply = root.config.autoApply;
            root._commit(cfg, true);
        }
    }

    // Parse pasted Lua / hyprlang text and merge it in. Returns the parse result.
    function importFromText(text) {
        const parsed = Logic.importText(text);
        if (parsed.curves.length + parsed.animations.length > 0) {
            const merged = Logic.mergeImport(root.config, parsed);
            merged.enabled = true;
            root._commit(Logic.normalize(merged), true);
        }
        return parsed;
    }

    function applyNow() {
        applyTimer.stop();
        root._runApply(Logic.buildStatements(root.config, root.context), false);
    }

    // Emulates axctl's own animation block live, then switches the mod off.
    function restoreDefaults() {
        const off = Logic.clone(root.config);
        off.enabled = false;
        const stmts = Logic.buildRestoreStatements(root.config, root.context);
        root._commit(off, true);
        applyTimer.stop();
        root._runApply(stmts, true);
    }

    function copyLuaToClipboard() {
        copyProc.environment = ({ AS_TEXT: root.luaPreview });
        copyProc.running = true;
    }

    function refreshLoaderStatus() {
        if (!statusProc.running) statusProc.running = true;
    }

    function installLoader() {
        if (installProc.running) return;
        root.loaderMessage = "";
        installProc.command = ["bash", "-c", root._installScript()];
        installProc.running = true;
    }

    function removeLoader() {
        if (removeProc.running) return;
        root.loaderMessage = "";
        removeProc.running = true;
    }

    // ---- internals -------------------------------------------------------

    property string _lastWritten: ""
    property bool _rerun: false
    property var _queue: []
    property int _queueIndex: 0
    property var _queueResults: []
    property bool _queueIsRestore: false
    property var _pendingRestore: null

    function _commit(next, persist) {
        root.config = next;
        root._refreshDerived();
        if (persist) {
            saveTimer.restart();
            if (next.enabled && next.autoApply && !root.hasErrors) {
                root.unapplied = true;
                applyTimer.restart();
            } else if (next.enabled) {
                root.unapplied = true;
            }
        }
    }

    function _refreshDerived() {
        root.errors = Logic.validate(root.config);
        root.luaPreview = Logic.buildLuaFile(root.config, root.context);
    }

    function _flush() {
        const json = JSON.stringify(root.config, null, 2) + "\n";
        root._lastWritten = json;
        cfgFile.setText(json);
        // Keep animations.lua in step so the optional loader (and any
        // manual `hyprctl reload`) always sees the latest state.
        luaFile.setText(root.luaPreview);
    }

    function _applyIfEnabled() {
        if (root.config.enabled && root.applyState !== "applying") root.applyNow();
    }

    function _scheduleStartupApply() {
        if (!root.config.enabled) return;
        startupEarly.restart();
        startupLate.restart();
    }

    function _onConfigText(text) {
        if (text === root._lastWritten) return;      // echo of our own write
        let parsed = null;
        try {
            parsed = JSON.parse(text);
        } catch (e) {
            console.warn("AnimationsService: animations.json is not valid JSON, ignoring:", e);
            return;
        }
        root.config = Logic.normalize(parsed);
        root._refreshDerived();
        luaFile.setText(root.luaPreview);
        root._scheduleStartupApply();
    }

    function _runApply(statements, isRestore) {
        if (GameModeClient.toggled && !isRestore) {
            root.applyState = "gamemode";
            root.applySummary = "GameMode is on; animations will be applied when it ends.";
            return;
        }
        if (!isRestore) {
            if (!root.config.enabled) return;
            if (root.hasErrors) {
                root.applyState = "blocked";
                root.applySummary = root.errors.length + " problem" + (root.errors.length === 1 ? "" : "s") + " to fix before applying.";
                return;
            }
        }
        if (root.applyState === "applying") {
            if (isRestore) root._pendingRestore = statements;   // must not be dropped
            else root._rerun = true;                             // coalesce: run again with fresh state
            return;
        }
        if (statements.length === 0) {
            root.applyState = "ok";
            root.applySummary = "Nothing to apply.";
            root.unapplied = false;
            return;
        }
        root._queue = statements;
        root._queueIndex = 0;
        root._queueResults = [];
        root._queueIsRestore = isRestore;
        root.applyState = "applying";
        root.applySummary = "Applying " + statements.length + " statements…";
        root._sendNext();
    }

    // Statements go out strictly one at a time: the daemon may service
    // requests concurrently and curves must exist before animations use them.
    function _sendNext() {
        if (root._queueIndex >= root._queue.length) {
            root._finishApply();
            return;
        }
        const st = root._queue[root._queueIndex];
        BackendService.call("compositor.eval", { expression: st.lua }, (result, error) => {
            let ok = true, message = "";
            if (error) {
                ok = false;
                message = String(error.message || error);
            } else if (!result) {
                ok = false;
                message = "No response from the daemon.";
            } else if (result.error) {
                ok = false;
                message = String(result.error);
            } else if (result.exit_code !== undefined && result.exit_code !== 0) {
                ok = false;
                message = (result.stdout || "exit code " + result.exit_code).toString().trim();
            } else if (typeof result.stdout === "string" && result.stdout.trim().indexOf("error") === 0) {
                ok = false;
                message = result.stdout.trim();
            }
            root._queueResults.push({ label: st.label, ok: ok, message: message });
            root._queueIndex++;
            root._sendNext();
        });
    }

    function _finishApply() {
        const results = root._queueResults;
        const bad = results.filter(r => !r.ok);
        root.applyResults = results;
        if (bad.length === 0) {
            root.applyState = "ok";
            root.applySummary = root._queueIsRestore
                ? "Restored axctl's animations (a Hyprland reload restores them exactly)."
                : "Applied " + results.length + " statements.";
            root.unapplied = false;
        } else {
            root.applyState = "error";
            root.applySummary = bad.length + " of " + results.length + " statements were rejected by Hyprland.";
            root.unapplied = true;
        }
        if (root._pendingRestore) {
            const stmts = root._pendingRestore;
            root._pendingRestore = null;
            root._rerun = false;                      // config is off now; nothing to re-apply
            root._runApply(stmts, true);
        } else if (root._rerun) {
            root._rerun = false;
            root.applyNow();
        }
    }

    function _installScript() {
        const block = Logic.buildLoaderBlock();
        return [
            "set -e",
            "f=\"${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua\"",
            "if [ -L \"$f\" ] && readlink \"$f\" | grep -q '^/nix/store/'; then echo managed; exit 0; fi",
            "[ -f \"$f\" ] || { echo missing; exit 0; }",
            "grep -qF -- '" + Logic.LOADER_MARKER + "' \"$f\" && { echo installed; exit 0; }",
            "cp -p \"$f\" \"$f.animation-studio.bak\"",
            "printf '\\n' >> \"$f\"",
            "cat >> \"$f\" <<'AS_EOF'",
            block.replace(/\n$/, ""),
            "AS_EOF",
            "echo installed"
        ].join("\n");
    }

    // ---- processes -------------------------------------------------------
    property Process copyProc: Process {
        command: ["bash", "-c", "printf %s \"$AS_TEXT\" | wl-copy --type text/plain"]
    }

    property Process ensureDirs: Process {
        command: ["mkdir", "-p", root.dataDir, Config.configDir]
    }

    property Process statusProc: Process {
        command: ["bash", "-c", [
            "f=\"${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua\"",
            "if [ -L \"$f\" ] && readlink \"$f\" | grep -q '^/nix/store/'; then echo managed",
            "elif [ ! -f \"$f\" ]; then echo missing",
            "elif grep -qF -- '" + Logic.LOADER_MARKER + "' \"$f\"; then echo installed",
            "else echo absent; fi"
        ].join("\n")]
        stdout: StdioCollector {
            onStreamFinished: root.loaderState = text.trim() || "unknown"
        }
    }

    property Process installProc: Process {
        stdout: StdioCollector {
            onStreamFinished: {
                root.loaderState = text.trim() || "unknown";
                if (root.loaderState === "installed") root.loaderMessage = "Loader added. Hyprland re-reads its config on its own.";
                else if (root.loaderState === "managed") root.loaderMessage = "hyprland.lua is managed by Nix; add the snippet by hand.";
                else if (root.loaderState === "missing") root.loaderMessage = "No ~/.config/hypr/hyprland.lua found (Lua config required).";
            }
        }
        onExited: code => {
            if (code !== 0) root.loaderMessage = "Could not modify hyprland.lua (exit " + code + ").";
        }
    }

    property Process removeProc: Process {
        command: ["bash", "-c", [
            "set -e",
            "f=\"${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua\"",
            "[ -f \"$f\" ] || exit 0",
            "cp -p \"$f\" \"$f.animation-studio.bak\"",
            "t=\"$(mktemp)\"",
            "awk -v m='" + Logic.LOADER_MARKER + "' 'skip { if ($0 == \"end)\") skip = 0; next } $0 == m { skip = 1; next } { print }' \"$f\" > \"$t\"",
            "cat \"$t\" > \"$f\"; rm -f \"$t\"",
            "echo absent"
        ].join("\n")]
        stdout: StdioCollector {
            onStreamFinished: {
                root.loaderState = text.trim() || "unknown";
                if (root.loaderState === "absent") root.loaderMessage = "Loader removed.";
            }
        }
        onExited: code => {
            if (code !== 0) root.loaderMessage = "Could not modify hyprland.lua (exit " + code + ").";
        }
    }

    // ---- files -----------------------------------------------------------
    FileView {
        id: cfgFile
        path: root.configPath
        atomicWrites: true
        watchChanges: true
        onLoaded: {
            root.loaded = true;
            root._onConfigText(text());
        }
        onLoadFailed: error => {
            // First run: no file yet. Start from an empty, switched-off config.
            root.loaded = true;
            root._refreshDerived();
        }
        onFileChanged: reload()
    }

    FileView {
        id: luaFile
        path: root.luaPath
        atomicWrites: true
    }

    // axctl regenerates hyprland.lua and reloads Hyprland after each
    // axctl.toml write; that reload discards live-applied curves.
    FileView {
        path: root.dataDir + "/axctl.toml"
        watchChanges: true
        onFileChanged: reapplyTimer.restart()
    }

    FileView {
        path: root.dataDir + "/hyprland.lua"
        watchChanges: true
        onFileChanged: reapplyTimer.restart()
    }

    // ---- timers ----------------------------------------------------------
    Timer { id: saveTimer; interval: 400; onTriggered: root._flush() }
    Timer { id: applyTimer; interval: 700; onTriggered: root.applyNow() }
    Timer {
        id: reapplyTimer
        interval: 1500
        onTriggered: root._applyIfEnabled()
    }
    // Ambxst's own startup writes axctl.toml, which makes axctl regenerate
    // and reload Hyprland (discarding live curves). Apply once early and once
    // after that has settled.
    Timer { id: startupEarly; interval: 2500; onTriggered: root._applyIfEnabled() }
    Timer { id: startupLate; interval: 9000; onTriggered: root._applyIfEnabled() }

    Connections {
        target: GameModeClient
        function onToggledChanged() {
            if (!GameModeClient.toggled && root.config.enabled) reapplyTimer.restart();
        }
    }

    Connections {
        target: Config.bar
        function onPositionChanged() {
            root._refreshDerived();
            saveTimer.restart();                 // animations.lua embeds the resolved "auto" style
            if (root.config.enabled) applyTimer.restart();
        }
    }

    Component.onCompleted: {
        ensureDirs.running = true;
        root._refreshDerived();
        root.refreshLoaderStatus();
    }
}
