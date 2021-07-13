-- fairly sophisticated objects --

local function newClassInstance()
  local classes = {}

  -- inherit "base" "new" {...}
  local function inherit(name)
    checkArg(1, name, "string")
    return function(newname)
      checkArg(1, newname, "string")
      return function(funcs)
        checkArg(1, funcs, "table")
        local nfuncs = setmetatable(funcs, {__index = classes[name]})
        return class(newname)(funcs)
      end
    end
  end

  -- new "base" ...
  local function new(name, ...)
    checkArg(1, name, "string")
    local funcs = setmetatable({}, {__index = classes[name]})
    if funcs.init then funcs:init(...) end
    return funcs
  end

  -- class "new" {...}
  local function class(name)
    checkArg(1, name, "string")
    return function(funcs)
      if not funcs then
        if not classes[name] then
          error("class '" .. name .. "' is nonexistent")
        end
      else
        if classes[name] then
          error("cannot create already existent class '" .. name .. "'")
        end
        setmetatable(funcs, {__call = function(_, ...) return inherit(name, ...) end})
        classes[name] = funcs
      end
    end
  end

  return class, inherit, new
end

return newClassInstance
