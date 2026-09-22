package.path = arg[1] .. "/?.lua;" .. package.path
local mock = require("lua_harness")
local dir, failures = arg[2], 0
local function check(c, msg) if not c then failures = failures + 1; print("FAIL: " .. msg) end end
local leaves = {}
for l in io.lines(dir .. "/leaves.txt") do leaves[l] = true end

for name in io.lines(dir .. "/files.txt") do
  -- 1) whole generated file, as Hyprland's loader runs it
  local hl, log = mock.new(leaves)
  _G.hl = hl
  local f = assert(loadfile(dir .. "/" .. name .. ".lua"))
  local ok, err = pcall(f)
  check(ok, name .. ": file run: " .. tostring(err))
  check(#log > 0 or name:match("^empty"), name .. ": applied something")
  -- 2) each statement standalone, exactly as compositor.eval evaluates one
  local hl2 = mock.new(leaves); _G.hl = hl2
  local n = 0
  for line in io.lines(dir .. "/" .. name .. ".stmts") do
    n = n + 1
    local chunk, cerr = load(line, "stmt" .. n)
    check(chunk ~= nil, name .. ": statement " .. n .. " does not compile: " .. tostring(cerr))
    if chunk then local ok2, e2 = pcall(chunk); check(ok2, name .. ": stmt " .. n .. ": " .. tostring(e2) .. "\n   " .. line) end
  end
  print(string.format("%-14s file ok, %d statements ok", name, n))
end

-- 3) _try isolates a rejected leaf
do
  local hl, ilog = mock.new(leaves); _G.hl = hl
  local f = assert(loadfile(dir .. "/isolation.lua"))
  local printed = {}
  local oldprint = print; print = function(s) printed[#printed+1] = s end
  local ok = pcall(f); print = oldprint
  check(ok, "isolation: file must not raise")
  check(#printed == 1 and printed[1]:find("no such animation leaf: glowangle"), "isolation: reported bad leaf once")
  check(#ilog == 7, "isolation: the 7 valid statements still applied, got " .. #ilog)
  print("isolation      bad leaf reported, rest applied")
end

-- 4) loader block: works with file present, absent, and XDG override
do
  local tmp = dir .. "/xdg"
  os.execute("mkdir -p " .. tmp .. "/ambxst && cp " .. dir .. "/basic.lua " .. tmp .. "/ambxst/animations.lua")
  local loader = io.open(dir .. "/loader.lua"):read("*a")
  local hl, log = mock.new(leaves); _G.hl = hl
  local getenv = os.getenv
  os.getenv = function(k) if k == "XDG_DATA_HOME" then return tmp end return getenv(k) end
  local ok, err = pcall(assert(load(loader, "loader")))
  check(ok, "loader with file: " .. tostring(err)); check(#log > 0, "loader applied animations")
  os.getenv = function(k) if k == "XDG_DATA_HOME" then return tmp .. "/nope" end return getenv(k) end
  hl, log = mock.new(leaves); _G.hl = hl
  ok, err = pcall(assert(load(loader, "loader")))
  check(ok, "loader with missing file must not raise: " .. tostring(err)); check(#log == 0, "nothing applied when file absent")
  os.getenv = function(k) if k == "XDG_DATA_HOME" then return nil end if k == "HOME" then return tmp .. "/home" end return getenv(k) end
  ok, err = pcall(assert(load(loader, "loader")))
  check(ok, "loader falls back to $HOME/.local/share: " .. tostring(err))
  os.getenv = getenv
  print("loader         present / missing / HOME fallback ok")
end
os.exit(failures == 0 and 0 or 1)
