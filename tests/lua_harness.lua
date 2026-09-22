-- Strict mock of Hyprland's Lua API (schema from wiki.hypr.land Animations page).
local M = {}
function M.new(known_leaves)
  local hl, log, curves = {}, {}, { default = "bezier" }
  local function isnum(v) return type(v) == "number" end
  function hl.curve(name, t)
    assert(type(name) == "string" and name ~= "", "curve name must be a non-empty string")
    assert(type(t) == "table", "curve spec must be a table")
    if t.type == "bezier" then
      assert(type(t.points) == "table" and #t.points == 2, "bezier needs 2 points")
      for i = 1, 2 do assert(isnum(t.points[i][1]) and isnum(t.points[i][2]), "point must be {x, y}") end
      for k in pairs(t) do assert(k == "type" or k == "points", "unknown bezier key " .. k) end
    elseif t.type == "spring" then
      assert(isnum(t.mass) and isnum(t.stiffness) and isnum(t.dampening), "spring needs mass, stiffness, dampening")
      for k in pairs(t) do assert(k == "type" or k == "mass" or k == "stiffness" or k == "dampening", "unknown spring key " .. k) end
    else error("curve type must be bezier or spring") end
    curves[name] = t.type
    log[#log + 1] = { "curve", name, t }
  end
  function hl.animation(t)
    assert(type(t) == "table" and type(t.leaf) == "string", "leaf required")
    if known_leaves then assert(known_leaves[t.leaf], "no such animation leaf: " .. t.leaf) end
    assert(type(t.enabled) == "boolean", "enabled must be boolean")
    if t.enabled then
      assert(isnum(t.speed) and t.speed > 0, "speed must be > 0")
      assert((t.bezier ~= nil) ~= (t.spring ~= nil), "exactly one of bezier/spring")
      local ref = t.bezier or t.spring
      assert(curves[ref], "undefined curve " .. tostring(ref))
      assert(curves[ref] == (t.bezier and "bezier" or "spring"), "curve kind mismatch for " .. ref)
      assert(t.style == nil or type(t.style) == "string", "style must be string")
    end
    log[#log + 1] = { "animation", t.leaf, t }
  end
  return hl, log, curves
end
return M
