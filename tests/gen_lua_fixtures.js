const fs = require("fs"), path = require("path"), vm = require("vm");
const src = fs.readFileSync(path.join(__dirname, "../payload/modules/services/AnimationsLogic.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const sb = { module: { exports: {} }, Math, JSON, Object, Array, Number, String, RegExp, isFinite, parseFloat }; vm.createContext(sb); vm.runInContext(src, sb);
const L = sb.module.exports, out = process.argv[2]; fs.mkdirSync(out, { recursive: true });
const names = [];
const emit = (name, cfg, ctx) => {
  names.push(name);
  fs.writeFileSync(`${out}/${name}.lua`, L.buildLuaFile(cfg, ctx));
  fs.writeFileSync(`${out}/${name}.stmts`, L.buildStatements(cfg, ctx).map(s => s.lua).join("\n") + "\n");
};
for (const p of L.PRESETS) { emit(p.id, L.presetConfig(p.id), { barPosition: "top" }); }
emit("preset_left", L.presetConfig("springy"), { barPosition: "left" });
const restoreStmts = L.buildRestoreStatements(L.presetConfig("hyprland"), { barPosition: "left" }).map(s => s.lua).join("\n") + "\n";
names.push("restore"); fs.writeFileSync(`${out}/restore.lua`, restoreStmts); fs.writeFileSync(`${out}/restore.stmts`, restoreStmts);
const basic = L.presetConfig("snappy"); fs.writeFileSync(`${out}/basic.lua`, L.buildLuaFile(basic, {}));
// isolation: one leaf the mock rejects, followed by a valid one
const iso = L.presetConfig("snappy"); iso.animations.unshift({ leaf: "glowangle", enabled: true, speed: 3, curve: "crisp", style: "" });
fs.writeFileSync(`${out}/isolation.lua`, L.buildLuaFile(iso, {}));
fs.writeFileSync(`${out}/loader.lua`, L.buildLoaderBlock());
fs.writeFileSync(`${out}/leaves.txt`, L.LEAVES.filter(l => l.leaf !== "glowangle").map(l => l.leaf).join("\n") + "\n");
fs.writeFileSync(`${out}/files.txt`, names.join("\n") + "\n");
