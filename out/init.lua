-- Cynosure kernel.  Should (TM) be mostly drop-in compatible with Paragon. --
-- Might even be better.  Famous last words!
-- Copyright (c) 2021 i develop things under the GNU GPLv3.

_G.k = { cmdline = table.pack(...), modules = {} }
do
  local start = computer.uptime()
  function k.uptime()
    return computer.uptime() - start
  end
end

-- kernel arguments

do
  local arg_pattern = "^(.-)=(.+)$"
  local orig_args = k.cmdline
  k.cmdline = {}

  for i=1, orig_args.n, 1 do
    local arg = orig_args[i]
    
    if arg:match(arg_pattern) then
      local k, v = arg:match(arg_pattern)
    
      if k and v then
        k.cmdline[k] = tonumber(v) or v
      end
    else
      k.cmdline[arg] = true
    end
  end
end


-- kernel version info --

do
  k._NAME = "Cynosure"
  k._RELEASE = "0" -- not released yet
  k._VERSION = "2021.04.18"
  _G._OSVERSION = string.format("%s r%s-%s", k._NAME, k._RELEASE, k._VERSION)
end


-- object-based tty streams --

do
  local colors = {
    0x000000,
    0xaa0000,
    0x00aa00,
    0xaa5500,
    0x0000aa,
    0xaa00aa,
    0x0055aa,
    0xaaaaaa,
    0x555555,
    0xff5555,
    0x55ff55,
    0xffff55,
    0x5555ff,
    0xff55ff,
    0x55ffff,
    0xffffff
  }

  -- pop characters from the end of a string
  local function pop(str, n)
    local ret = str:sub(1, n)
    local also = str:sub(#ret + 1, -1)
 
    return also, ret
  end

  local function wrap_cursor(self)
    while self.cx > self.w do
      self.cx, self.cy = self.cx - self.w, self.cy + 1
    end
    
    while self.cx < 1 do
      self.cx, self.cy = self.w + self.cx, self.cy - 1
    end
    
    while self.cy < 1 do
      self.cy = self.cy + 1
      self.gpu.copy(1, 1, self.w, self.h, 0, 1)
      self.gpu.fill(1, 1, self.w, 1, " ")
    end
    
    while self.cy > self.h do
      self.cy = self.cy - 1
      self.gpu.copy(1, 1, self.w, self.h, 0, -1)
      self.gpu.fill(1, self.h, self.w, 1, " ")
    end
  end

  local function writeline(self, rline)
    while #rline > 0 do
      local to_write
      rline, to_write = pop(rline, self.w - self.cx + 1)
      
      self.gpu.set(self.cx, self.cy, to_write)
      
      self.cx = self.cx + #to_write
      
      wrap_cursor(self)
    end
  end

  local function write(self, lines)
    while #lines > 0 do
      local next_nl = lines:find("\n")

      if next_nl then
        local ln
        lines, ln = pop(lines, next_nl - 1)
        lines = lines:sub(2) -- take off the newline
        
        writeline(self, ln)
        
        self.cx, self.cy = 1, self.cy + 1
        
        wrap_cursor(self)
      else
        writeline(self, lines)
        break
      end
    end
  end

  local commands, control = {}, {}
  local separators = {
    standard = "[",
    control = "?"
  }

  -- move cursor up N[=1] lines
  function commands:A(args)
    local n = math.max(args[1] or 0, 1)
    self.cy = self.cy - n
  end

  -- move cursor down N[=1] lines
  function commands:B(args)
    local n = math.max(args[1] or 0, 1)
    self.cy = self.cy + n
  end

  -- move cursor right N[=1] lines
  function commands:C(args)
    local n = math.max(args[1] or 0, 1)
    self.cx = self.cx + n
  end

  -- move cursor left N[=1] lines
  function commands:D(args)
    local n = math.max(args[1] or 0, 1)
    self.cx = self.cx - n
  end

  function commands:G()
    self.cx = 1
  end

  function commands:H(args)
    local y, x = 1, 1
    y = args[1] or y
    x = args[2] or x
  
    self.cx = x
    self.cy = y
    
    wrap_cursor(self)
  end

  -- clear a portion of the screen
  function commands:J(args)
    local n = args[1] or 0
    
    if n == 0 then
      self.gpu.fill(1, self.cy, self.w, self.h, " ")
    elseif n == 1 then
      self.gpu.fill(1, 1, self.w, self.cy, " ")
    elseif n == 2 then
      self.gpu.fill(1, 1, self.w, self.h, " ")
    end
  end
  
  -- clear a portion of the current line
  function commands:K(args)
    local n = args[1] or 0
    
    if n == 0 then
      self.gpu.fill(self.cx, self.cy, self.w, 1, " ")
    elseif n == 1 then
      self.gpu.fill(1, self.cy, self.cx, 1, " ")
    elseif n == 2 then
      self.gpu.fill(1, self.cy, self.w, 1, " ")
    end
  end

  -- adjust some terminal attributes - foreground/background color and local
  -- echo.  for more control {ESC}?c may be desirable.
  function commands:m(args)
    args[1] = args[1] or 0
    for i=1, #args, 1 do
      local n = args[i]
      if n == 0 then
        self.fg = colors[8]
        self.bg = colors[1]
        self.attributes.echo = true
      elseif n == 8 then
        self.attributes.echo = false
      elseif n == 28 then
        self.attributes.echo = true
      elseif n > 29 and n < 38 then
        self.fg = colors[n - 29]
        self.gpu.setForeground(self.fg)
      elseif n == 39 then
        self.fg = colors[8]
        self.gpu.setForeground(self.fg)
      elseif n > 39 and n < 48 then
        self.bg = colors[n - 39]
        self.gpu.setBackground(self.bg)
      elseif n == 49 then
        self.bg = colors[1]
        self.gpu.setBackground(self.bg)
      elseif n > 89 and n < 98 then
        self.fg = colors[n - 81]
        self.gpu.setForeground(self.fg)
      elseif n > 99 and n < 108 then
        self.bg = colors[n - 91]
        self.gpu.setBackground(self.bg)
      end
    end
  end

  function commands:n(args)
    local n = args[1] or 0

    if n == 6 then
      self.rb = string.format("%s\27[%d;%dR", self.cy, self.cx)
    end
  end

  -- adjust more terminal attributes
  -- codes:
  --   - 0: reset
  --   - 1: enable echo
  --   - 2: enable line mode
  --   - 3: enable raw mode
  --   - 11: disable echo
  --   - 12: disable line mode
  --   - 13: disable raw mode
  function control:c(args)
    args[1] = args[1] or 0
    
    for i=1, #args, 1 do
      local n = args[i]

      if n == 0 then -- (re)set configuration to sane defaults
        -- echo text that the user has entered?
        self.attributes.echo = true
        
        -- buffer input by line?
        self.attributes.line = true
        
        -- whether to send raw key input data according to the VT100 spec,
        -- rather than e.g. changing \r -> \n and capturing backspace
        self.attributes.raw = false
      elseif n == 1 then
        self.attributes.echo = true
      elseif n == 2 then
        self.attributes.line = true
      elseif n == 3 then
        self.attributes.raw = true
      elseif n == 11 then
        self.attributes.echo = false
      elseif n == 12 then
        self.attributes.line = false
      elseif n == 13 then
        self.attributes.raw = false
      end
    end
  end

  local _stream = {}
  
  -- This is where most of the heavy lifting happens.  I've attempted to make
  -- this function fairly optimized, but there's only so much one can do given
  -- OpenComputers's call budget limits and wrapped string library.
  function _stream:write(str)
    checkArg(1, str, "string")

    local gpu = self.gpu

    -- TODO: cursor logic is a bit brute-force currently, there are certain
    -- TODO: scenarios where cursor manipulation is unnecessary
    local c, f, b = gpu.get(self.cx, self.cy)
    gpu.setForeground(b)
    gpu.setBackground(f)
    gpu.set(self.cx, self.cy, c)
    gpu.setForeground(self.fg)
    gpu.setBackground(self.bg)
    
    -- lazily convert tabs
    str = str:gsub("\t", "  ")
    
    while #str > 0 do
      if self.in_esc then
        local esc_end = str:find("[a-zA-Z]")

        if not esc_end then
          self.esc = string.format("%s%s", self.esc, str)
        else
          self.in_esc = false

          local finish
          str, finish = pop(str, esc_end)

          local esc = string.format("%s%s", self.esc, finish)
          self.esc = ""

          local separator, raw_args, code = esc:match(
            "\27([%[%(])([%d;]*)([a-zA-Z])")
          raw_args = raw_args or "0"
          
          local args = {}
          for arg in raw_args:gmatch("([^;]+)") do
            args[#args + 1] = tonumber(arg) or 0
          end
          
          if separator == separators.standard and commands[code] then
            commands[code](self, args)
          elseif separator == separators.control and control[code] then
            control[code](self, args)
          end
          
          wrap_cursor(self)
        end
      else
        local next_esc = str:find("\27")
        
        if next_esc then
          self.in_esc = true
          self.esc = ""
        
          local ln
          str, ln = pop(str, next_esc - 1)
          
          write(self, ln)
        else
          write(self, str)
          str = ""
        end
      end
    end

    c, f, b = gpu.get(self.cx, self.cy)
    
    gpu.setForeground(b)
    gpu.setBackground(f)
    gpu.set(self.cx, self.cy, c)
    gpu.setForeground(self.fg)
    gpu.setBackground(self.bg)
    
    return true
  end

  -- TODO: proper line buffering for output
  function _stream:flush()
    return true
  end

  -- aliases of key scan codes to key inputs
  local aliases = {
    [200] = "\27[A", -- up
    [208] = "\27[B", -- down
    [205] = "\27[C", -- right
    [203] = "\27[D", -- left
  }

  function _stream:key_down(...)
    local signal = table.pack(...)
    
    local char = aliases[signal[4]] or
              (signal[3] > 255 and unicode.char or string.char)(signal[3])
    local ch = signal[3]
    local tw = char
    
    if #char == 1 and ch == 0 then
      char = ""
      tw = ""
    elseif char:match("\27%[[ABCD]") then
      tw = string.format("^[%s", char:sub(-1))
    elseif #char == 1 and ch < 32 then
      local tch = string.char(
          (ch == 0 and 32) or
          (ch < 27 and ch + 96) or
          (ch == 27 and "[") or
          (ch == 28 and "\\") or
          (ch == 29 and "]") or
          (ch == 30 and "~") or
          (ch == 31 and "?") or ch
        ):upper()
    
      tw = "^" .. tch
    end
    
    if not self.attributes.raw then
      if ch == 13 then
        char = "\n"
        tw = "\n"
      elseif ch == 8 then
        tw = "\27[D \27[D"
        char = ""
        self.rb = self.rb:sub(1, -1)
      end
    end
    
    if self.attributes.echo then
      self:write(tw or "")
    end
    
    self.rb = string.format("%s%s", self.rb, char)
  end
  
  function _stream:read(n)
    checkArg(1, n, "number")

    if self.attributes.line then
      while (not self.rb:find("\n")) or (self.rb:find("\n") < n)
          and not self.rb:find("\4") do
        coroutine.yield()
      end
    else
      while #self.rb < n and (self.attributes.raw or not self.rb:find("\4")) do
        coroutine.yield()
      end
    end

    if self.rb:find("\4") then
      self.rb = ""
      return nil
    end

    local data = self.rb:sub(1, n)
    self.rb = self.rb:sub(n + 1)
    return data
  end

  local function closed()
    return nil, "stream closed"
  end

  function _stream:close()
    self.closed = true
    self.read = closed
    self.write = closed
    self.flush = closed
    self.close = closed
    k.event.unregister(self.key_handler_id)
    if self.ttyn then k.sysfs.unregister("/dev/tty"..self.ttyn) end
    return true
  end

  local ttyn = 0

  -- this is the raw function for creating TTYs over components
  -- userspace gets somewhat-abstracted-away stuff
  function k.create_tty(gpu, screen)
    checkArg(1, gpu, "string")
    checkArg(2, screen, "string")

    local proxy = component.proxy(gpu)
    
    proxy.bind(screen)
    proxy.setForeground(colors[8])
    proxy.setBackground(colors[1])
    
    -- userspace will never directly see this, so it doesn't really matter what
    -- we put in this table
    local new = setmetatable({
      attributes = {echo=true,line=true,raw=false}, -- terminal attributes
      keyboards = {}, -- all attached keyboards on terminal initialization
      in_esc = false, -- was a partial escape sequence written
      gpu = proxy, -- the associated GPU
      esc = "", -- the escape sequence buffer
      cx = 1, -- the cursor's X position
      cy = 1, -- the cursor's Y position
      fg = colors[8], -- the current foreground color
      bg = colors[1], -- the current background color
      rb = "" -- a buffer of characters read from the input
    }, {__index = _stream})

    -- avoid gpu.getResolution calls
    new.w, new.h = proxy.maxResolution()

    proxy.setResolution(new.w, new.h)
    proxy.fill(1, 1, new.w, new.h, " ")
    
    -- register all keyboards attached to the screen
    for _, keyboard in pairs(component.invoke(screen, "getKeyboards")) do
      new.keyboards[keyboard] = true
    end
    
    -- register a keypress handler
    new.key_handler_id = k.event.register("key_down", function(...)
      return new:key_down(...)
    end)

    -- register the TTY with the sysfs
    if k.sysfs then
      k.sysfs.register(k.sysfs.types.tty, new, "/dev/tty"..ttyn)
      new.ttyn = ttyn
      ttyn = ttyn + 1
    end
    
    return new
  end
end


-- event handling --

do
  local event = {}
  local handlers = {}

  local pull = computer.pullSignal
  computer.pullSignalOld = pull

  function computer.pullSignal(timeout)
    checkArg(1, timeout, "number", "nil")
    
    local sig = table.pack(pull(timeout))
    if sig.n == 0 then return nil end
    
    for _, v in pairs(handlers) do
      if v.signal == sig[1] then
        v.callback(table.unpack(sig))
      end
    end
    
    return table.unpack(sig)
  end

  local n = 0
  function event.register(sig, call)
    checkArg(1, sig, "string")
    checkArg(2, call, "function")
    
    n = n + 1
    handlers[n] = {signal=sig,callback=call}
    return n
  end

  function event.unregister(id)
    checkArg(1, id, "number")
    handlers[id] = nil
    return true
  end

  k.event = event
end


-- early boot logger

do
  local levels = {
    debug = 0,
    info = 1,
    warn = 64,
    error = 128,
    panic = 256,
  }
  k.loglevels = levels

  local lgpu = component.list("gpu", true)()
  local lscr = component.list("screen", true)()

  local function safe_concat(...)
    local args = table.pack(...)
    local msg = ""
  
    for i=1, args.n, 1 do
      msg = string.format("%s%s ", msg, tostring(args[i]))
    end
    return msg
  end

  if lgpu and lscr then
    k.logio = k.create_tty(lgpu, lscr)
    
    function k.log(level, ...)
      local msg = safe_concat(...)
      msg = msg:gsub("\t", "  ")
    
      if (tonumber(k.cmdline.loglevel) or 1) <= level then
        k.logio:write(string.format("[\27[35m%4.4f\27[37m] %s\n", k.uptime(),
          msg))
      end
      return true
    end
  else
    k.logio = nil
    function k.log()
    end
  end

  local raw_pullsignal = computer.pullSignalOld
  computer.pullSignalOld = nil
  
  function k.panic(...)
    local msg = safe_concat(...)
  
    computer.beep(440, 0.25)
    computer.beep(380, 0.25)
    
    k.log(k.loglevels.panic, "-- \27[91mbegin stacktrace\27[37m --")
    
    local traceback = debug.traceback(msg, 2)
      :gsub("\t", "  ")
      :gsub("([^\n]+):(%d+):", "\27[96m%1\27[37m:\27[95m%2\27[37m:")
      :gsub("'([^']+)'\n", "\27[93m'%1'\27[37m\n")
    
    for line in traceback:gmatch("[^\n]+") do
      k.log(k.loglevels.panic, line)
    end

    k.log(k.loglevels.panic, "-- \27[91mend stacktrace\27[37m --")
    k.log(k.loglevels.panic, "\27[93m!! \27[91mPANIC\27[93m !!\27[37m")
    
    while true do raw_pullsignal() end
  end
end

k.log(k.loglevels.info, "Starting\27[93m", _OSVERSION, "\27[37m")


-- kernel hooks

k.log(k.loglevels.info, "base/hooks")

do
  local hooks = {}
  k.hooks = {}
  
  function k.hooks.add(name, func)
    checkArg(1, name, "string")
    checkArg(2, func, "function")
  
    hooks[name] = hooks[name] or {}
    table.insert(hooks[name], func)
  end

  function k.hooks.call(name, ...)
    checkArg(1, name, "string")

    if hooks[name] then
      for k, v in ipairs(hooks[name]) do
        v(...)
      end
    end
  end
end


-- some utilities --

k.log(k.loglevels.info, "base/util")

do
  local util = {}
  
  function util.merge_tables(a, b)
    for k, v in pairs(b) do
      if not a[k] then
        a[k] = v
      end
    end
  
    return a
  end

  -- here we override rawset() in order to properly protect tables
  local _rawset = rawset
  local blacklist = setmetatable({}, {__mode = "k"})
  
  function _G.rawset(t, k, v)
    if not blacklist[t] then
      return _rawset(t, k, v)
    else
      -- this will error
      t[k] = v
    end
  end

  local function protecc()
    error("attempt to modify a write-protected table")
  end

  function util.protect(tbl)
    local new = {}
    local mt = {
      __index = tbl,
      __newindex = protecc,
      __pairs = tbl,
      __metatable = {}
    }
  
    return setmetatable(new, mt)
  end

  -- create hopefully memory-friendly copies of tables
  -- uses metatable magic
  -- this is a bit like util.protect except tables are still writable
  -- even i still don't fully understand how this works, but it works
  -- nonetheless
  --[[disabled due to some issues i was having
  if computer.totalMemory() < 262144 then
    -- if we have 256k or less memory, use the mem-friendly function
    function util.copy_table(tbl)
      if type(tbl) ~= "table" then return tbl end
      local shadow = {}
      local copy_mt = {
        __index = function(_, k)
          local item = rawget(shadow, k) or rawget(tbl, k)
          return util.copy(item)
        end,
        __pairs = function()
          local iter = {}
          for k, v in pairs(tbl) do
            iter[k] = util.copy(v)
          end
          for k, v in pairs(shadow) do
            iter[k] = v
          end
          return pairs(iter)
        end
        -- no __metatable: leaving this metatable exposed isn't a huge
        -- deal, since there's no way to access `tbl` for writing using any
        -- of the functions in it.
      }
      copy_mt.__ipairs = copy_mt.__pairs
      return setmetatable(shadow, copy_mt)
    end
  else--]] do
    -- from https://lua-users.org/wiki/CopyTable
    local function deepcopy(orig, copies)
      copies = copies or {}
      local orig_type = type(orig)
      local copy
    
      if orig_type == 'table' then
        if copies[orig] then
          copy = copies[orig]
        else
          copy = {}
          copies[orig] = copy
      
          for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
          end
          
          setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
      else -- number, string, boolean, etc
        copy = orig
      end

      return copy
    end

    function util.copy_table(t)
      return deepcopy(t)
    end
  end

  function util.to_hex(str)
    local ret = ""
    
    for char in str:gmatch(".") do
      ret = string.format("%s%02x", ret, string.byte(char))
    end
    
    return ret
  end

  -- lassert: local assert
  -- removes the "init:123" from errors (fires at level 0)
  function util.lassert(a, ...)
    if not a then error(..., 0) else return a, ... end
  end

  k.util = util
end


-- some security-related things --

k.log(k.loglevels.info, "base/security")

k.security = {}


-- users --

k.log(k.loglevels.info, "base/security/users")


-- from https://github.com/philanc/plc iirc

k.log(k.loglevels.info, "base/security/sha3.lua")

do
-- sha3 / keccak

local char	= string.char
local concat	= table.concat
local spack, sunpack = string.pack, string.unpack

-- the Keccak constants and functionality

local ROUNDS = 24

local roundConstants = {
0x0000000000000001,
0x0000000000008082,
0x800000000000808A,
0x8000000080008000,
0x000000000000808B,
0x0000000080000001,
0x8000000080008081,
0x8000000000008009,
0x000000000000008A,
0x0000000000000088,
0x0000000080008009,
0x000000008000000A,
0x000000008000808B,
0x800000000000008B,
0x8000000000008089,
0x8000000000008003,
0x8000000000008002,
0x8000000000000080,
0x000000000000800A,
0x800000008000000A,
0x8000000080008081,
0x8000000000008080,
0x0000000080000001,
0x8000000080008008
}

local rotationOffsets = {
-- ordered for [x][y] dereferencing, so appear flipped here:
{0, 36, 3, 41, 18},
{1, 44, 10, 45, 2},
{62, 6, 43, 15, 61},
{28, 55, 25, 21, 56},
{27, 20, 39, 8, 14}
}



-- the full permutation function
local function keccakF(st)
	local permuted = st.permuted
	local parities = st.parities
	for round = 1, ROUNDS do
--~ 		local permuted = permuted
--~ 		local parities = parities

		-- theta()
		for x = 1,5 do
			parities[x] = 0
			local sx = st[x]
			for y = 1,5 do parities[x] = parities[x] ~ sx[y] end
		end
		--
		-- unroll the following loop
		--for x = 1,5 do
		--	local p5 = parities[(x)%5 + 1]
		--	local flip = parities[(x-2)%5 + 1] ~ ( p5 << 1 | p5 >> 63)
		--	for y = 1,5 do st[x][y] = st[x][y] ~ flip end
		--end
		local p5, flip, s
		--x=1
		p5 = parities[2]
		flip = parities[5] ~ (p5 << 1 | p5 >> 63)
		s = st[1]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=2
		p5 = parities[3]
		flip = parities[1] ~ (p5 << 1 | p5 >> 63)
		s = st[2]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=3
		p5 = parities[4]
		flip = parities[2] ~ (p5 << 1 | p5 >> 63)
		s = st[3]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=4
		p5 = parities[5]
		flip = parities[3] ~ (p5 << 1 | p5 >> 63)
		s = st[4]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=5
		p5 = parities[1]
		flip = parities[4] ~ (p5 << 1 | p5 >> 63)
		s = st[5]
		for y = 1,5 do s[y] = s[y] ~ flip end

		-- rhopi()
		for y = 1,5 do
			local py = permuted[y]
			local r
			for x = 1,5 do
				s, r = st[x][y], rotationOffsets[x][y]
				py[(2*x + 3*y)%5 + 1] = (s << r | s >> (64-r))
			end
		end

		local p, p1, p2
		--x=1
		s, p, p1, p2 = st[1], permuted[1], permuted[2], permuted[3]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=2
		s, p, p1, p2 = st[2], permuted[2], permuted[3], permuted[4]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=3
		s, p, p1, p2 = st[3], permuted[3], permuted[4], permuted[5]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=4
		s, p, p1, p2 = st[4], permuted[4], permuted[5], permuted[1]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=5
		s, p, p1, p2 = st[5], permuted[5], permuted[1], permuted[2]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end

		-- iota()
		st[1][1] = st[1][1] ~ roundConstants[round]
	end
end


local function absorb(st, buffer)

	local blockBytes = st.rate / 8
	local blockWords = blockBytes / 8

	-- append 0x01 byte and pad with zeros to block size (rate/8 bytes)
	local totalBytes = #buffer + 1
	-- SHA3:
	buffer = buffer .. ( '\x06' .. char(0):rep(blockBytes - (totalBytes % blockBytes)))
	totalBytes = #buffer

	--convert data to an array of u64
	local words = {}
	for i = 1, totalBytes - (totalBytes % 8), 8 do
		words[#words + 1] = sunpack('<I8', buffer, i)
	end

	local totalWords = #words
	-- OR final word with 0x80000000 to set last bit of state to 1
	words[totalWords] = words[totalWords] | 0x8000000000000000

	-- XOR blocks into state
	for startBlock = 1, totalWords, blockWords do
		local offset = 0
		for y = 1, 5 do
			for x = 1, 5 do
				if offset < blockWords then
					local index = startBlock+offset
					st[x][y] = st[x][y] ~ words[index]
					offset = offset + 1
				end
			end
		end
		keccakF(st)
	end
end


-- returns [rate] bits from the state, without permuting afterward.
-- Only for use when the state will immediately be thrown away,
-- and not used for more output later
local function squeeze(st)
	local blockBytes = st.rate / 8
	local blockWords = blockBytes / 4
	-- fetch blocks out of state
	local hasht = {}
	local offset = 1
	for y = 1, 5 do
		for x = 1, 5 do
			if offset < blockWords then
				hasht[offset] = spack("<I8", st[x][y])
				offset = offset + 1
			end
		end
	end
	return concat(hasht)
end


-- primitive functions (assume rate is a whole multiple of 64 and length is a whole multiple of 8)

local function keccakHash(rate, length, data)
	local state = {	{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
	}
	state.rate = rate
	-- these are allocated once, and reused
	state.permuted = { {}, {}, {}, {}, {}, }
	state.parities = {0,0,0,0,0}
	absorb(state, data)
	return squeeze(state):sub(1,length/8)
end

-- output raw bytestrings
local function keccak256Bin(data) return keccakHash(1088, 256, data) end
local function keccak512Bin(data) return keccakHash(576, 512, data) end

k.sha3 = {
	sha256 = keccak256Bin,
	sha512 = keccak512Bin,
}
end


do
  local api = {}

  -- default root data so we can at least run init as root
  -- init should overwrite this with `users.prime()` later on
  -- but for now this will suffice
  local passwd = {
    [0] = {
      name = "root",
      home = "/root",
      shell = "/bin/rc",
      acls = 8191
    }
  }

  function api.prime(data)
    checkArg(1, data, "table")
 
    k.userspace.package.loaded.users.prime = nil
    passwd = data
    
    return true
  end

  function api.authenticate(uid, pass)
    checkArg(1, uid, "number")
    checkArg(2, pass, "string")
    
    pass = k.util.to_hex(pass)
    
    local udata = passwd[uid]
    
    if not udata then
      return nil, "no such user"
    end
    
    if pass == udata.pass then
      return true
    end
    
    return nil, "invalid password"
  end

  function api.exec_as(uid, pass, func, pname, wait)
    checkArg(1, uid, "number")
    checkArg(2, pass, "string")
    checkArg(3, func, "function")
    checkArg(4, pname, "string", "nil")
    checkArg(5, wait, "boolean", "nil")
    
    if not k.acl.user_has_permission(k.scheduler.info().owner,
        k.acl.permissions.user.SUDO) then
      return nil, "permission denied: no permission"
    end
    
    if not api.authenticate(uid, pass) then
      return nil, "permission denied: bad login"
    end
    
    local new = {
      func = func,
      name = pname or tostring(func),
      owner = uid,
    }
    
    local p = k.scheduler.spawn(new)
    
    if not wait then return end

    -- this is the only spot in the ENTIRE kernel where process.await is used
    return k.userspace.package.loaded.process.await(p.pid)
  end

  function api.get_uid(uname)
    checkArg(1, uname, "string")
    
    for uid, udata in pairs(passwd) do
      if udata.name == uname then
        return uid
      end
    end
    
    return nil, "no such user"
  end

  function api.attributes(uid)
    checkArg(1, uid, "number")
    
    local udata = passwd[uid]
    
    if not udata then
      return nil, "no such user"
    end
    
    return {
      name = udata.name,
      home = udata.home,
      shell = udata.shell,
      acls = udata.acls
    }
  end

  k.security.users = api
end


-- access control lists, mostly --

k.log(k.loglevels.info, "base/security/access_control")

do
  -- this implementation of ACLs is fairly basic.
  -- it only supports boolean on-off permissions rather than, say,
  -- allowing users only to log on at certain times of day.
  local permissions = {
    user = {
      SUDO = 1,
      MOUNT = 2,
      OPEN_UNOWNED = 4,
      COMPONENTS = 8,
      HWINFO = 16,
      SETARCH = 32,
      MANAGE_USERS = 64,
      BOOTADDR = 128
    },
    file = {
      OWNER_READ = 1,
      OWNER_WRITE = 2,
      OWNER_EXEC = 4,
      GROUP_READ = 8,
      GROUP_WRITE = 16,
      GROUP_EXEC = 32,
      OTHER_READ = 64,
      OTHER_WRITE = 128,
      OTHER_EXEC = 256
    }
  }

  local acl = {}

  acl.permissions = permissions

  function acl.user_has_permission(uid, permission)
    checkArg(1, uid, "number")
    checkArg(2, permission, "number")
  
    local attributes, err = k.security.users.attributes(uid)
    
    if not attributes then
      return nil, err
    end
    
    return acl.has_permission(attributes.acls, permission)
  end

  function acl.has_permission(perms, permission)
    checkArg(1, perms, "number")
    checkArg(2, permission, "number")
    
    return perms & permission ~= 0
  end

  k.security.acl = acl
end



-- some shutdown related stuff

k.log(k.loglevels.info, "base/shutdown")

do
  local shutdown = computer.shutdown
  
  function k.shutdown(rbt)
    k.is_shutting_down = true
    k.hooks.call("shutdown", rbt)
    shutdown(rbt)
  end
end


-- some component API conveniences

k.log(k.loglevels.info, "base/component")

do
  function component.get(addr, mkpx)
    checkArg(1, addr, "string")
    checkArg(2, mkpx, "boolean", "nil")
    
    local pat = string.format("^%s", addr:gsub("%-", "%%-"))
    for k, v in component.list() do
      if k:match(pat) then
        return mkpx and component.proxy(k) or k
      end
    end
    
    return nil, "no such component"
  end

  setmetatable(component, {
    __index = function(t, k)
      local addr = component.list(k)()
      if not addr then
        error(string.format("no component of type '%s'", k))
      end
    
      return component.proxy(addr)
    end
  })
end


-- fsapi: VFS and misc filesystem infrastructure

k.log(k.loglevels.info, "base/fsapi")

do
  local fs = {}

  -- common error codes
  fs.errors = {
    file_not_found = "no such file or directory",
    is_a_directory = "is a directory",
    not_a_directory = "not a directory",
    read_only = "target is read-only",
    failed_read = "failed opening file for reading",
    failed_write = "failed opening file for writing",
    file_exists = "file already exists"
  }

  -- standard file types
  fs.types = {
    file = 1,
    directory = 2,
    link = 3
  }

  -- This VFS should support directory overlays, fs mounting, and directory
  --    mounting, hopefully all seamlessly.
  -- mounts["/"] = { node = ..., children = {["bin"] = "usr/bin", ...}}
  local mounts = {}

  local function split(path)
    local segments = {}
    
    for seg in path:gmatch("[^/]+") do
      if seg == ".." then
        segments[#segments] = nil
      elseif seg ~= "." then
        segments[#segments + 1] = seg
      end
    end
    
    return segments
  end

  fs.split = split

  -- "clean" a path
  local function clean(path)
    return table.concat(split(path), "/")
  end

  local faux = {children = mounts}
  local resolving = {}

  local function resolve(path)
    if resolving[path] then
      return nil, "recursive mount detected"
    end
    
    path = clean(path)
    resolving[path] = true
    
    local current, parent = faux
    
    if not mounts["/"] then
      return nil, "root filesystem is not mounted!"
    end
    
    if current.children[path] then
      return current.children[path]
    end
    
    local segments = split(path)
    table.insert(segments, 1, "/")
    
    local base_n = 1 -- we may have to traverse multiple mounts
    
    for i=1, #segments, 1 do
      local try = table.concat(segments, "/", base_n, i)
    
      if current.children[try] then
        base_n = i -- we are now at this stage of the path
        local next_node = current.children[try]
      
        if type(next_node) == "string" then
          local err
          next_node, err = resolve(next_node)
        
          if not next_node then
            resolving[path] = false
            return nil, err
          end
        end
        
        parent = current
        current = next_node
      elseif not current.node:stat(try) then
        resolving[path] = false

        return nil, fs.errors.file_not_found
      end
    end
    
    resolving[path] = false
    local ret = "/"..table.concat(segments, "/", base_n, #segments)
    
    if must_exist and not current.node:exists(ret) then
      return nil, fs.errors.file_not_found
    end
    
    return current, parent, ret
  end

  local registered = {partition_tables = {}, filesystems = {}}

  local _managed = {}
  function _managed:info()
    return {
      read_only = self.node.isReadOnly(),
      address = self.node.address
    }
  end

  function _managed:stat(file)
    checkArg(1, file, "string")

    if not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    return {
      permissions = self:info().read_only and 365 or 511,
      isDirectory = self.node.isDirectory(file),
      owner       = -1,
      group       = -1,
      lastModified= self.node.lastModified(file),
      size        = self.node.size(file)
    }
  end

  function _managed:touch(file, ftype)
    checkArg(1, file, "string")
    checkArg(2, ftype, "number", "nil")
    
    if self.node.isReadOnly() then
      return nil, fs.errors.read_only
    end
    
    if self.node.exists(file) then
      return nil, fs.errors.file_exists
    end
    
    if ftype == fs.types.file or not ftype then
      local fd = self.node.open(file, "w")
    
      if not fd then
        return nil, fs.errors.failed_write
      end
      
      self.node.write(fd, "")
      self.node.close(fd)
    elseif ftype == fs.types.directory then
      local ok, err = self.node.makeDirectory(file)
      
      if not ok then
        return nil, err or "unknown error"
      end
    elseif ftype == fs.types.link then
      return nil, "unsupported operation"
    end
    
    return true
  end
  
  function _managed:remove(file)
    checkArg(1, file, "string")
    
    if not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    if self.node.isDirectory(file) and #(self.node.list(file) or {}) > 0 then
      return nil, fs.errors.is_a_directory
    end
    
    return self.node.remove(file)
  end

  function _managed:list(path)
    checkArg(1, path, "string")
    
    if not self.node.exists(path) then
      return nil, fs.errors.file_not_found
    elseif not self.node.isDirectory(path) then
      return nil, fs.errors.not_a_directory
    end
    
    local files = self.node.list(path) or {}
    
    return files
  end
  
  local function fread(s, n)
    return s.node.read(s.fd, n)
  end

  local function fwrite(s, d)
    return s.node.write(s.fd, d)
  end

  local function fseek(s, w, o)
    return s.node.seek(s.fd, w, o)
  end

  local function fclose(s)
    return s.node.close(s.fd)
  end

  function _managed:open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
    
    if (mode == "r" or mode == "a") and not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    local fd = {
      fd = self.node.open(file, mode or "r"),
      node = self.node,
      read = fread,
      write = fwrite,
      seek = fseek,
      close = fclose
    }
    
    return fd
  end
  
  local fs_mt = {__index = _managed}
  local function create_node_from_managed(proxy)
    return setmetatable({node = proxy}, fs_mt)
  end

  local function create_node_from_unmanaged(proxy)
    local fs_superblock = proxy.readSector(1)
    
    for k, v in pairs(registered.filesystems) do
      if v.is_valid_superblock(superblock) then
        return v.new(proxy)
      end
    end
    
    return nil, "no compatible filesystem driver available"
  end

  fs.PARTITION_TABLE = "partition_tables"
  fs.FILESYSTEM = "filesystems"
  
  function fs.register(category, driver)
    if not registered[category] then
      return nil, "no such category: " .. category
    end
  
    table.insert(registered[category], driver)
    return true
  end

  function fs.get_partition_table_driver(filesystem)
    checkArg(1, filesystem, "string", "table")
    
    if type(filesystem) == "string" then
      filesystem = component.proxy(filesystem)
    end
    
    if filesystem.type == "filesystem" then
      return nil, "managed filesystem has no partition table"
    else -- unmanaged drive - perfect
      for k, v in pairs(registered.partition_tables) do
        if v.has_valid_superblock(proxy) then
          return v.create(proxy)
        end
      end
    end
    
    return nil, "no compatible partition table driver available"
  end

  function fs.get_filesystem_driver(filesystem)
    checkArg(1, filesystem, "string", "table")
    
    if type(filesystem) == "string" then
      filesystem = component.proxy(filesystem)
    end
    
    if filesystem.type == "filesystem" then
      return create_node_from_managed(filesystem)
    else
      return create_node_from_unmanaged(filesystem)
    end
  end

  -- actual filesystem API now
  fs.api = {}
  
  function fs.api.open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
  
    local node, err, path = resolve(file)
    if not node then
      return nil, err
    end
    
    mode = mode or "r"
    local data = node.node:stat(path)
    local user = (k.scheduler.info() or {owner=0}).owner
    -- TODO: groups
    
    if data.owner ~= user and not k.security.acl.user_has_permission(user,
                            k.security.acl.permissions.user.OPEN_UNOWNED) then
      return nil, "permission denied"
    else
      local perms = k.security.acl.permissions.file
      local rperm, wperm
    
      if data.owner ~= user then
        rperm = perms.OTHER_READ
        wperm = perms.OTHER_WRITE
      else
        rperm = perms.OWNER_READ
        wperm = perms.OWNER_WRITE
      end
      
      if (mode == "r" and not
        k.security.acl.has_permission(data.permissions, rperm)) or
        ((mode == "w" or mode == "a") and not
        k.security.acl.has_permission(data.permissions, wperm)) then
        return nil, "permission denied"
      end
    end
    
    return node.node:open(path, mode)
  end

  function fs.api.stat(file)
    checkArg(1, file, "string")
    
    local node, err, path = resolve(file)
    
    if not node then
      return false
    end
    
    return node.node:stat(file)
  end

  function fs.api.touch(file, ftype)
    checkArg(1, file, "string")
    checkArg(2, ftype, "number", "nil")
    
    ftype = ftype or fs.types.file
    
    local root, base = file:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    base = base or file
    
    local node, err, path = resolve(root)
    
    if not node then
      return nil, err
    end
    
    return node.node:touch(path .. "/" .. base, ftype)
  end

  function fs.api.remove(file)
    checkArg(1, file, "string")
    
    local node, err, pack = resolve(root)
    
    if not node then
      return nil, err
    end
    
    return node.node:remove(file)
  end

  local mounted = {}

  fs.api.types = {
    RAW = 0,
    NODE = 1,
    OVERLAY = 2,
  }
  
  function fs.api.mount(node, fstype, path)
    checkArg(1, node, "string", "table")
    checkArg(2, fstype, "number")
    checkArg(2, path, "string")
    
    local device, err = node
    
    if fstype ~= fs.api.types.RAW then
      -- TODO: properly check object methods first
      goto skip
    end
    
    device, err = fs.get_filesystem_driver(node)
    if k.sysfs and not device then
      local sdev, serr = k.sysfs.retrieve(node)
      if not sdev then return nil, serr end
      device, err = fs.get_filesystem_driver(sdev)
    end
    
    ::skip::
    if not device then
      return nil, err
    end
    
    path = clean(path)
    if path == "" then path = "/" end
    
    local root, fname = path:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    fname = fname or path
    
    local pnode, err, rpath
    
    if path == "/" then
      mounts["/"] = {node = device, children = {}}
      return true
    else
      pnode, err, rpath = resolve(root)
    end
    
    if not pnode then
      return nil, err
    end
    
    local full = clean(string.format("%s/%s", rpath, fname))
    if full == "" then full = "/" end
    
    if type(node) == "string" then
      pnode.children[full] = node
    else
      pnode.children[full] = {node=device, children={}}
      mounted[path]=(device.node and device.node.getLabel and
        device.node.getLabel()) or "unknown"
    end
    
    return true
  end

  function fs.api.umount(path)
    checkArg(1, path, "string")
    
    path = clean(path)
    
    local root, fname = path:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    fname = fname or path
    
    local node, err, rpath = resolve(root)
    
    if not node then
      return nil, err
    end
    
    local full = clean(string.format("%s/%s", rpath, fname))
    node.children[full] = nil
    mounted[path] = nil
    
    return true
  end

  function fs.api.mounts()
    local new = {}
    -- prevent programs from meddling with these
    for k,v in pairs(mounted) do new[k] = v end
    return new
  end

  k.fs = fs
end


-- the Lua standard library --


-- implementation of the FILE* API --

k.log(k.loglevels.info, "base/stdlib/FILE*")

do
  local buffer = {}
 
  function buffer:read_byte()
    if self.buffer_mode ~= "none" then
      if (not self.read_buffer) or #self.read_buffer == 0 then
        self.read_buffer = self.base:read(self.buffer_size)
      end
  
      if not self.read_buffer then
        self.closed = true
        return nil
      end
      
      local dat = self.read_buffer:sub(1,1)
      self.read_buffer = self.read_buffer:sub(2, -1)
      
      return dat
    else
      return self.base:read(1)
    end
  end

  function buffer:write_byte(byte)
    if self.buffer_mode ~= "none" then
      if #self.write_buffer >= self.buffer_size then
        self.base:write(self.write_buffer)
        self.write_buffer = ""
      end
      
      self.write_buffer = string.format("%s%s", self.write_buffer, byte)
    else
      return self.base:write(byte)
    end

    return true
  end

  function buffer:read_line()
    local line = ""
    
    repeat
      local c = self:read_byte()
      line = string.format("%s%s", line, c or "")
    until c == "\n" or not c
    
    return line
  end

  local valid = {
    a = true,
    l = true,
    L = true,
    n = true
  }

  function buffer:read_formatted(fmt)
    checkArg(1, fmt, "string", "number")
    
    if type(fmt) == "number" then
      local read = ""
    
      repeat
        local byte = self:read_byte()
        read = string.format("%s%s", read, byte or "")
      until #read > fmt or not byte
      
      return read
    else
      fmt = fmt:gsub("%*", ""):sub(1,1)
      
      if #fmt == 0 or not valid[fmt] then
        error("bad argument to 'read' (invalid format)")
      end
      
      if fmt == "l" or fmt == "L" then
        local line = self:read_line()
      
        if fmt == "l" then
          line = line:sub(1, -2)
        end
        
        return line
      elseif fmt == "a" then
        local read = ""
        
        repeat
          local byte = self:read_byte()
          read = string.format("%s%s", read, byte or "")
        until not byte
        
        return read
      elseif fmt == "n" then
        local read = ""
        
        repeat
          local byte = self:read_byte()
          if not tonumber(byte) then
            -- TODO: this breaks with no buffering
            self.read_buffer = byte .. self.read_buffer
          else
            read = string.format("%s%s", read, byte or "")
          end
        until not tonumber(byte)
        
        return tonumber(read)
      end

      error("bad argument to 'read' (invalid format)")
    end
  end

  function buffer:read(...)
    if self.closed or not self.mode.r then
      return nil, "bad file descriptor"
    end
    
    local args = table.pack(...)
    if args.n == 0 then args[1] = "l" args.n = 1 end
    
    local read = {}
    for i=1, args.n, 1 do
      read[i] = self:read_formatted(args[i])
    end
    
    return table.unpack(read)
  end

  function buffer:lines(format)
    format = format or "l"
    
    return function()
      return self:read(format)
    end
  end

  function buffer:write(...)
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    local args = table.pack(...)
    local write = ""
    
    for i=1, #args, 1 do
      checkArg(i, args[i], "string", "number")
    
      args[i] = tostring(args[i])
      write = string.format("%s%s", write, args[i])
    end
    
    if self.buffer_mode == "none" then
      -- a-ha! performance shortcut!
      -- because writing in a chunk is much faster
      return self.base:write(write)
    end

    for i=1, #write, 1 do
      local char = write:sub(i,i)
      self:write_byte(char)
    end

    return true
  end

  function buffer:seek(whence, offset)
    checkArg(1, whence, "string")
    checkArg(2, offset, "number")
    
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    self:flush()
    return self.base:seek()
  end

  function buffer:flush()
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    if #self.write_buffer > 0 then
      self.base:write(self.write_buffer)
      self.write_buffer = ""
    end
    
    return true
  end

  function buffer:close()
    self:flush()
    self.closed = true
  end

  local fmt = {
    __index = buffer,
    -- __metatable = {},
    __name = "FILE*"
  }

  function k.create_fstream(base, mode)
    checkArg(1, base, "table")
    checkArg(2, mode, "string")
  
    local new = {
      base = base,
      buffer_size = 512,
      read_buffer = "",
      write_buffer = "",
      buffer_mode = "standard", -- standard, line, none
      closed = false,
      mode = {}
    }
    
    for c in mode:gmatch(".") do
      new.mode[c] = true
    end
    
    setmetatable(new, fmt)
    return new
  end
end


-- io library --

k.log(k.loglevels.info, "base/stdlib/io")

do
  local fs = k.fs.api
  local im = {stdin = 0, stdout = 1, stderr = 2}
 
  local mt = {
    __index = function(t, k)
      local info = k.scheduler.info()
  
      if info.data.io[k] then
        return info.data.io[k]
      end
      
      return nil
    end,
    __newindex = function(t, k, v)
      local info = k.scheduler.info()
      info.data.io[k] = v
      info.handles[im[k]] = v
    end
  }

  _G.io = {}
  
  function io.open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
  
    mode = mode or "r"
    
    local handle, err = fs.open(file, mode)
    if not handle then
      return nil, err
    end

    local fstream = k.create_fstream(handle, mode)

    local info = k.scheduler.info()
    if info then
      info.data.handles[#info.data.handles + 1] = fstream
      fstream.n = #info.data.handles
      
      local close = fstream.close
      function fstream:close()
        close(self)
        info.data.handles[self.n] = nil
      end
    end
    
    return fstream
  end

  -- popen should be defined in userspace so the shell can handle it.
  -- tmpfile should be defined in userspace also.
  -- it turns out that defining things PUC Lua can pass off to the shell
  -- *when you don't have a shell* is rather difficult and so, instead of
  -- weird hacks like in Paragon or Monolith, I just leave it up to userspace.
  function io.popen()
    return nil, "io.popen unsupported at kernel level"
  end

  function io.tmpfile()
    return nil, "io.tmpfile unsupported at kernel level"
  end

  function io.read(...)
    return io.input():read(...)
  end

  function io.write(...)
    return io.output():write(...)
  end

  function io.lines(file, fmt)
    file = file or io.stdin

    if type(file) == "string" then
      file = assert(io.open(file, "r"))
    end
    
    checkArg(1, file, "FILE*")
    
    return file:lines(fmt)
  end

  local function stream(kk)
    return function(v)
      if v then checkArg(1, v, "FILE*") end

      local t = k.scheduler.info().data.io
    
      if v then
        t[kk] = v
      end
      
      return t[kk]
    end
  end

  io.input = stream("input")
  io.output = stream("output")

  function io.type(stream)
    assert(stream, "bad argument #1 (value expected)")
    
    if type(stream) == "FILE*" then
      if stream.closed then
        return "closed file"
      end
    
      return "file"
    end

    return nil
  end

  function io.flush(s)
    s = s or io.stdout
    checkArg(1, s, "FILE*")

    return s:flush()
  end

  function io.close(stream)
    checkArg(1, stream, "FILE*")

    if stream == io.stdin or stream == io.stdout or stream == io.stderr then
      return nil, "cannot close standard file"
    end
    
    return stream:close()
  end

  setmetatable(io, mt)

  function _G.print(...)
    local args = table.pack(...)
   
    for i=1, args.n, 1 do
      args[i] = tostring(args[i])
    end
    
    return io.write(table.concat(args, "  ", 1, args.n), "\n")
  end
end


-- package API.  this is probably the lib i copy-paste the most. --

k.log(k.loglevels.info, "base/stdlib/package")

do
  _G.package = {}
 
  local loaded = {
    os = os,
    io = io,
    math = math,
    string = string,
    table = table,
    users = k.users,
    sha3 = k.sha3,
    unicode = unicode
  }
  
  package.loaded = loaded
  package.path = "/lib/?.lua;/lib/lib?.lua;/lib/?/init.lua"
  
  local fs = k.fs.api

  local function libError(name, searched)
    local err = "module '%s' not found:\n\tno field package.loaded['%s']"
    err = err .. ("\n\tno file '%s'"):rep(#searched)
  
    return string.format(err, name, name, table.unpack(searched))
  end

  function package.searchpath(name, path, sep, rep)
    checkArg(1, name, "string")
    checkArg(2, path, "string")
    checkArg(3, sep, "string", "nil")
    checkArg(4, rep, "string", "nil")
    
    sep = "%" .. (sep or ".")
    rep = rep or "/"
    
    local searched = {}
    
    name = name:gsub(sep, rep)
    
    for search in path:gmatch("[^;]+") do
      search = search:gsub("%?", name)
    
      if fs.stat(search) then
        return search
      end
      
      searched[#searched + 1] = search
    end

    return nil, libError(name, searched)
  end

  package.protect = k.util.protect

  function package.delay(lib, file)
    local mt = {
      __index = function(tbl, key)
        setmetatable(lib, nil)
        setmetatable(lib.internal or {}, nil)
        ; -- this is just in case, because Lua is weird
        (k.userspace.dofile or dofile)(file)
    
        return tbl[key]
      end
    }

    if lib.internal then
      setmetatable(lib.internal, mt)
    end
    
    setmetatable(lib, mt)
  end

  -- let's define this here because WHY NOT
  function _G.loadfile(file, mode, env)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
    checkArg(3, env, "table", "nil")
    
    local handle, err = io.open(file, "r")
    if not handle then
      return nil, err
    end
    
    local data = handle:read("a")
    handle:close()
    
    return load(data, "="..file, "bt", k.userspace or _G)
  end

  function _G.dofile(file)
    checkArg(1, file, "string")
    
    local ok, err = loadfile(file)
    if not ok then
      error(err, 0)
    end
    
    local stat, ret = xpcall(ok, debug.traceback)
    if not stat and ret then
      error(ret, 0)
    end
    
    return ret
  end

  local k = k
  k.hooks.add("sandbox", function()
    k.userspace.k = nil
    
    local acl = k.security.acl
    local perms = acl.permissions
    
    local function wrap(f, p)
      return function(...)
        if not acl.user_has_permission(k.scheduler.info().owner,
            p) then
          error("permission denied")
        end
    
        return f(...)
      end
    end

    k.userspace.component = nil
    k.userspace.computer = nil
    k.userspace.unicode = nil
    k.userspace.package.loaded.component = {}
    
    for f,v in pairs(component) do
      k.userspace.package.loaded.component[f] = wrap(v,
        perms.user.COMPONENTS)
    end
    
    k.userspace.package.loaded.computer = {
      getDeviceInfo = wrap(computer.getDeviceInfo, perms.user.HWINFO),
      setArchitecture = wrap(computer.setArchitecture, perms.user.SETARCH),
      addUser = wrap(computer.addUser, perms.user.MANAGE_USERS),
      removeUser = wrap(computer.removeUser, perms.user.MANAGE_USERS),
      setBootAddress = wrap(computer.setBootAddress, perms.user.BOOTADDR)
    }
    
    for f, v in pairs(computer) do
      k.userspace.package.loaded.computer[f] =
        k.userspace.package.loaded.computer[f] or v
    end
    
    k.userspace.package.loaded.unicode = k.util.copy_table(unicode)
    k.userspace.package.loaded.filesystem = k.util.copy_table(k.fs.api)
    
    local ufs = k.userspace.package.loaded.filesystem
    ufs.mount = wrap(k.fs.api.mount, perms.user.MOUNT)
    ufs.umount = wrap(k.fs.api.umount, perms.user.MOUNT)
  end)
end



-- custom types

k.log(k.loglevels.info, "base/types")

do
  local old_type = type
  function _G.type(obj)
    if old_type(obj) == "table" then
      local s, mt = pcall(getmetatable, obj)
      
      if not s and mt then
        -- getting the metatable failed, so it's protected.
        -- instead, we should tostring() it - if the __name
        -- field is set, we can let the Lua VM get the
        -- """type""" for us.
        local t = tostring(obj):gsub(" [%x+]$", "")
        return t
      end
       
      -- either there is a metatable or ....not. If
      -- we have gotten this far, the metatable was
      -- at least not protected, so we can carry on
      -- as normal.  And yes, i have put waaaay too
      -- much effort into making this comment be
      -- almost a rectangular box :)
      mt = mt or {}
 
      return mt.__name or mt.__type or old_type(obj)
    else
      return old_type(obj)
    end
  end

  -- ok time for cursed shit: aliasing one type to another
  -- i will at least blacklist the default Lua types
  local cannot_alias = {
    string = true,
    number = true,
    boolean = true,
    ["nil"] = true,
    ["function"] = true,
    table = true,
    userdata = true
  }
  local defs = {}
  
  -- ex. typedef("number", "int")
  function _G.typedef(t1, t2)
    checkArg(1, t1, "string")
    checkArg(2, t2, "string")
  
    if cannot_alias[t2] then
      error("attempt to override default type")
    end

    if defs[t2] then
      error("cannot override existing typedef")
    end
    
    defs[t2] = t1
    
    return true
  end

  -- copied from machine.lua
  function _G.checkArg(n, have, ...)
    have = type(have)
    
    local function check(want, ...)
      if not want then
        return false
      else
        return have == want or defs[want] == have or check(...)
      end
    end
    
    if not check(...) then
      local msg = string.format("bad argument #%d (%s expected, got %s)",
                                n, table.concat(table.pack(...), " or "), have)
      error(msg, 2)
    end
  end
end


-- binary struct
-- note that to make something unsigned you ALWAYS prefix the type def with
-- 'u' rather than 'unsigned ' due to Lua syntax limitations.
-- ex:
-- local example = struct {
--   uint16("field_1"),
--   string[8]("field_2")
-- }
-- local copy = example "\0\14A string"
-- yes, there is lots of metatable hackery behind the scenes

k.log(k.loglevels.info, "ksrc/struct")

do
  -- step 1: change the metatable of _G so we can have convenient type notation
  -- without technically cluttering _G
  local gmt = {}
  
  local types = {
    int = "i",
    uint = "I",
    bool = "b", -- currently booleans are just signed 8-bit values because reasons
    short = "h",
    ushort = "H",
    long = "l",
    ulong = "L",
    size_t = "T",
    float = "f",
    double = "d",
    lpstr = "s",
  }

  -- char is a special case:
  --   - the user may want a single byte (char("field"))
  --   - the user may also want a fixed-length string (char[42]("field"))
  local char = {}
  setmetatable(char, {
    __call = function(field)
      return {fmtstr = "B", field = field}
    end,
    __index = function(t, k)
      if type(k) == "number" then
        return function(value)
          return {fmtstr = "c" .. k, field = value}
        end
      else
        error("invalid char length specifier")
      end
    end
  })

  function gmt.__index(t, k)
    if k == "char" then
      return char
    else
      local tp
  
      for t, v in pairs(types) do
        local match = k:match("^"..t)
        if match then tp = t break end
      end
      
      if not tp then return nil end
      
      return function(value)
        return {fmtstr = types[tp] .. tonumber(k:match("%d+$") or "0")//8,
          field = value}
      end
    end
  end

  -- step 2: change the metatable of string so we can have string length
  -- notation.  Note that this requires a null-terminated string.
  local smt = {}

  function smt.__index(t, k)
    if type(k) == "number" then
      return function(value)
        return {fmtstr = "z", field = value}
      end
    end
  end

  -- step 3: apply these metatable hacks
  setmetatable(_G, gmt)
  setmetatable(string, smt)

  -- step 4: ???

  -- step 5: profit

  function struct(fields, name)
    checkArg(1, fields, "table")
    checkArg(2, name, "string", "nil")
    
    local pat = "<"
    local args = {}
    
    for i=1, #fields, 1 do
      local v = fields[i]
      pat = pat .. v.fmtstr
      args[i] = v.field
    end
  
    return setmetatable({}, {
      __call = function(_, data)
        assert(type(data) == "string" or type(data) == "table",
          "bad argument #1 to struct constructor (string or table expected)")
    
        if type(data) == "string" then
          local set = table.pack(string.unpack(pat, data))
          local ret = {}
        
          for i=1, #args, 1 do
            ret[args[i]] = set[i]
          end
          
          return ret
        elseif type(data) == "table" then
          local set = {}
          
          for i=1, #args, 1 do
            set[i] = data[args[i]]
          end
          
          return string.pack(pat, table.unpack(set))
        end
      end,
      __len = function()
        return string.packsize(pat)
      end,
      __name = name or "struct"
    })
  end
end


-- system log API hook for userspace

k.log(k.loglevels.info, "base/syslog")

do
  local mt = {
    __name = "syslog"
  }

  local syslog = {}
  local open = {}

  function syslog.open(pname)
    checkArg(1, pname, "string", "nil")

    pname = pname or k.scheduler.info().name
    open[n] = pname
    
    return n
  end

  function syslog.write(n, ...)
    checkArg(1, n, "number")
    
    if not open[n] then
      return nil, "bad file descriptor"
    end
    
    k.log(open[n] .. ":", ...)
  end

  function syslog.close(n)
    checkArg(1, n, "number")
    
    if not open[n] then
      return nil, "bad file descriptor"
    end
    
    open[n] = nil
  end

  k.hooks.add("sandbox", function()
    k.userspace.package.loaded.syslog = k.util.copy_table(syslog)
  end)
end


-- thread: wrapper around coroutines

k.log(k.loglevels.info, "base/thread")

do
  local function handler(err)
    return debug.traceback(err, 3)
  end

  local old_coroutine = coroutine
  local _coroutine = {}
  _G.coroutine = _coroutine
  
  function _coroutine.create(func)
    checkArg(1, func, "function")
  
    return setmetatable({
      __thread = old_coroutine.create(function()
        return select(2, k.util.lassert(xpcall(func, handler)))
      end)
    }, {
      __index = _coroutine,
      __name = "thread"
    })
  end

  function _coroutine.wrap(fnth)
    checkArg(1, fnth, "function", "thread")
    
    if type(fnth) == "function" then fnth = _coroutine.create(fnth) end
    
    return function(...)
      return select(2, fnth:resume(...))
    end
  end

  function _coroutine:resume(...)
    return old_coroutine.resume(self.__thread, ...)
  end

  function _coroutine:status()
    return old_coroutine.status(self.__thread)
  end

  for k,v in pairs(old_coroutine) do
    _coroutine[k] = _coroutine[k] or v
  end
end


-- processes
-- mostly glorified coroutine sets

k.log(k.loglevels.info, "base/process")

do
  local process = {}
  local proc_mt = {
    __index = process,
    __name = "process"
  }

  function process:resume(...)
    for k, v in pairs(self.threads) do
      local result = table.pack(v:resume(...))
  
      if v:status() == "dead" then
        self.threads[k] = nil
      
        if not result[1] then
          self:push_signal("thread_died", v.id)
        
          return nil, result[2]
        end
      end
    end

    if not next(self.threads) then
      self.dead = true
    end
    
    return true
  end

  local id = 0
  function process:add_thread(func)
    checkArg(1, func, "function")
    
    local new = coroutine.create(func)
    
    id = id + 1
    new.id = id
    
    self.threads[#self.threads + 1] = new
    
    return id
  end

  function process:status()
    return self.coroutine:status()
  end

  local c_pushSignal = computer.pushSignal
  
  function process:push_signal(...)
    local signal = table.pack(...)
    table.insert(self.queue, signal)
    return true
  end

  -- there are no timeouts, the scheduler manages that
  function process:pull_signal()
    if #self.queue > 0 then
      return table.remove(self.queue, 1)
    end
  end

  local pid = 0
  
  function k.create_process(args)
    pid = pid + 1
  
    local new = setmetatable({
      name = args.name,
      pid = pid,
      io = {
        stdin = args.stdin or {},
        input = args.input or args.stdin or {},
        stdout = args.stdout or {},
        output = args.output or args.stdout or {},
        stderr = args.stderr or {}
      },
      queue = {},
      threads = {},
      waiting = true,
      stopped = false,
      handles = {},
      coroutine = {},
      cputime = 0,
      deadline = 0,
    }, proc_mt)
    
    args.stdin, args.stdout, args.stderr,
                    args.input, args.output = nil, nil, nil
    
    for k, v in pairs(args) do
      new[k] = v
    end

    new.handles[0] = new.stdin
    new.handles[1] = new.stdout
    new.handles[2] = new.stderr
    
    new.coroutine.status = function(self)
      if self.dead then
        return "dead"
      elseif self.stopped then
        return "stopped"
      elseif self.waiting then
        return "waiting"
      else
        return "running"
      end
    end
    
    return new
  end
end


-- scheduler

k.log(k.loglevels.info, "base/scheduler")

do
  local processes = {}
  local current

  local api = {}

  function api.spawn(args)
    checkArg(1, args.name, "string")
    checkArg(2, args.func, "function")
    
    local parent = processes[current or 0] or {}
    
    local new = k.create_process {
      name = args.name,
      parent = parent.pid or 0,
      stdin = parent.stdin or args.stdin,
      stdout = parent.stdout or args.stdout,
      input = args.input or parent.stdin,
      output = args.output or parent.stdout,
      owner = args.owner or parent.owner or 0,
    }
    
    new:add_thread(args.func)
    processes[new.pid] = new
    
    if k.sysfs then
      assert(k.sysfs.register(k.sysfs.types.process, new, "/proc/"..new.pid))
    end
    
    return new
  end

  function api.info(pid)
    checkArg(1, pid, "number", "nil")
    
    pid = pid or current
    
    local proc = processes[pid]
    if not proc then
      return nil, "no such process"
    end

    local info = {
      pid = proc.pid,
      name = proc.name,
      waiting = proc.waiting,
      stopped = proc.stopped,
      deadline = proc.deadline,
      n_threads = #proc.threads,
      status = proc:status(),
      cputime = proc.cputime,
      owner = proc.owner
    }
    
    if proc.pid == current then
      info.data = {
        push_signal = proc.push_signal,
        pull_signal = proc.pull_signal,
        io = proc.io,
        self = proc,
        handles = proc.handles,
        coroutine = proc.coroutine
      }
    end
    
    return info
  end

  function api.kill(proc)
    checkArg(1, proc, "number", "nil")
    
    proc = proc or current.pid
    
    if not processes[proc] then
      return nil, "no such process"
    end
    
    processes[proc].dead = true
    
    return true
  end

  local pullSignal = computer.pullSignal
  function api.loop()
    while next(processes) do
      local to_run = {}
      local going_to_run = {}
      local min_timeout = math.huge
    
      for k, v in pairs(processes) do
        if not v.stopped then
          if v.deadline - computer.uptime() < min_timeout then
            min_timeout = v.deadline - computer.uptime()
          end
        end
      
        if min_timeout <= 0 then
          min_timeout = 0
          break
        end
      end
      
      --k.log(k.loglevels.info, min_timeout)
      
      local sig = table.pack(pullSignal(min_timeout))
      for k, v in pairs(processes) do
        if (v.deadline <= computer.uptime() or #v.queue > 0 or sig.n > 0) and
            not (v.stopped or going_to_run[v.pid] or v.dead) then
          to_run[#to_run + 1] = v
      
          if v.resume_next then
            to_run[#to_run + 1] = v.resume_next
            going_to_run[v.resume_next.pid] = true
          end
        end
      end

      for i, proc in ipairs(to_run) do
        local psig = sig
        current = i
      
        if #proc.queue > 0 then -- the process has queued signals
          proc:push_signal(table.unpack(sig))
          psig = proc:pull_signal()
        end
        
        local start_time = computer.uptime()
        local ok, err = proc:resume(table.unpack(psig))
        
        if proc.dead or ok == "__internal_process_exit" or not ok then
          local exit = err or 0
        
          if type(err) == "string" then
            exit = 127
          else
            exit = err or 0
            err = "exited"
          end
          
          err = err or "died"
          k.log(k.loglevels.warn, "process died: ", proc.pid, exit, err)
          computer.pushSignal("process_died", proc.pid, exit, err)
          
          for k, v in pairs(proc.handles) do
            pcall(v.close, v)
          end
          
          processes[proc.pid] = nil
        else
          proc.cputime = proc.cputime + computer.uptime() - start_time
          proc.deadline = computer.uptime() + (tonumber(ok) or math.huge)
        end
      end
    end

    if not k.is_shutting_down then
      -- !! PANIC !!
      k.panic("all user processes died")
    end
  end

  k.scheduler = api
  
  -- sandbox hook for userspace 'process' api
  k.hooks.add("sandbox", function()
    local p = {}
    k.userspace.package.loaded.process = p
    
    function p.spawn(args)
      checkArg(1, args.name, "string")
      checkArg(2, args.func, "function")
    
      local sanitized = {
        func = args.func,
        name = args.name,
        stdin = args.stdin,
        stdout = args.stdout,
        input = args.input,
        output = args.output
      }
      
      local new = api.spawn(sanitized)
      
      return new.pid
    end
    
    function p.kill(pid)
      checkArg(1, pid, "number", "nil")
      
      local cur = current
      local atmp = processes[pid]
      
      if not atmp then
        return true
      end
      
      if (atmp or {owner=current.owner}).owner ~= cur.owner and
         cur.owner ~= 0 then
        return nil, "permission denied"
      end
      
      return api.kill(pid)
    end
    
    function p.list()
      local pr = {}
      
      for k, v in pairs(processes) do
        pr[#pr+1]=k
      end
      
      table.sort(pr)
      return pr
    end

    -- this is not provided at the kernel level
    -- largely because there is no real use for it
    -- returns: exit status, exit message
    function p.await(pid)
      checkArg(1, pid, "number")
      
      local signal = {}
      
      if not processes[pid] then
        return nil, "no such process"
      end
      
      repeat
        signal = table.pack(coroutine.yield())
      until signal[1] == "process_died" and signal[2] == pid
      
      return signal[3], signal[4]
    end
    
    p.info = api.info
  end)
end


-- sysfs API --

k.log(k.loglevels.info, "sysfs/sysfs")

do
  local tree = {
    components = {dir = true},
    proc = {dir = true},
    dev = {dir = true},
    mounts = {
      dir = false,
      read = function(h)
        if h.__has_been_read then
          return nil
        end

        local mounts = k.fs.api.mounts()
        local ret = ""
        
        for k, v in pairs(mounts) do
          ret = string.format("%s%s\n", ret, k..": "..v)
        end
        
        h.__has_been_read = true
        
        return ret
      end,
      write = function()
        return nil, "bad file descriptor"
      end
    }
  }

  local function find(f)
    if f == "/" then
      return tree
    end

    local s = k.fs.split(f)
    local c = tree
    
    for i=1, #s, 1 do
      if s[i] == "dir" then
        return nil, k.fs.errors.file_not_found
      end
    
      if not c[s[i]] then
        return nil, k.fs.errors.file_not_found
      end
      
      c = c[s[i]]
    end

    return c
  end

  local obj = {}

  function obj:stat(f)
    checkArg(1, f, "string")
    
    local n, e = find(f)
    local e = tree[f]
    
    if n then
      return {
        permissions = 365,
        owner = 0,
        group = 0,
        lastModified = 0,
        size = 0,
        isDirectory = not not n.dir
      }
    else
      return nil, e
    end
  end

  function obj:touch()
    return nil, k.fs.errors.read_only
  end

  function obj:remove()
    return nil, k.fs.errors.read_only
  end

  function obj:list(d)
    local n, e = find(d)
    
    if not n then return nil, e end
    if not n.dir then return nil, k.fs.errors.not_a_directory end
    
    local f = {}
    
    for k, v in pairs(e) do
      if k ~= "dir" then
        f[#f+1] = k
      end
    end
    
    return f
  end

  local function ferr()
    return nil, "bad file descriptor"
  end

  local function fclose(self)
    if self.closed then
      return ferr()
    end
    
    self.closed = true
  end

  function obj:open(f, m)
    checkArg(1, f, "string")
    checkArg(2, m, "string")
    
    local n, e = find(f)
    
    if not n then return nil, e end
    if n.dir then return nil, k.fs.errors.is_a_directory end

    if n.open then return n.open(m) end
    
    return {
      read = n.read or ferr,
      write = n.write or ferr,
      seek = n.seek or ferr,
      close = n.close or fclose
    }
  end

  -- now here's the API
  local api = {}
  api.types = {
    generic = "generic",
    process = "process",
    directory = "directory"
  }
  typedef("string", "SYSFS_NODE")

  local handlers = {}

  function api.register(otype, node, path)
    checkArg(1, otype, "SYSFS_NODE")
    assert(type(node) ~= "nil", "bad argument #2 (value expected, got nil)")
    checkArg(3, path, "string")

    if not handlers[otype] then
      return nil, string.format("sysfs: node type '%s' not handled", otype)
    end

    local segments = k.fs.split(path)
    local nname = segments[#segments]
    local n, e = find(table.concat(segments, "/", 1, #segments - 1))

    if not n then
      return nil, e
    end

    local nn, ee = handlers[otype](node)
    if not nn then
      return nil, ee
    end

    n[nname] = nn

    return true
  end

  function api.retrieve(path)
    checkArg(1, path, "string")
    return find(path)
  end

  function api.unregister(path)
    checkArg(1, path, "string")
    
    local segments = fs.split(path)
    local ppath = table.concat(segments, "/", 1, #segments - 1)
    
    local node = segments[#segments]
    if node == "dir" then
      return nil, fs.errors.file_not_found
    end

    local n, e = find(ppath)
    if not n then
      return nil, e
    end

    if not n[node] then
      return nil, fs.errors.file_not_found
    end

    n[node] = nil

    return true
  end
  
  function api.handle(otype, mkobj)
    checkArg(1, otype, "SYSFS_NODE")
    checkArg(2, mkobj, "function")

    api.types[otype] = otype
    handlers[otype] = mkobj

    return true
  end
  
  k.sysfs = api

  -- we have to hook this here since the root filesystem isn't mounted yet
  -- when the kernel reaches this point.
  k.hooks.add("sandbox", function()
    assert(k.fs.api.mount(obj, k.fs.api.types.NODE, "/sys"))
    -- Adding the sysfs API to userspace is probably not necessary for most
    -- things.  If it does end up being necessary I'll do it.
    --k.userspace.package.loaded.sysfs = k.util.copy_table(api)
  end)
end


-- sysfs handlers

k.log(k.loglevels.info, "sysfs/handlers")

do
  local util = {}
  function util.mkfile(data)
    local data = data
    return {
      dir = false,
      read = function(self, n)
        self.__ptr = self.__ptr or 0
        if self.__ptr >= #data then
          return nil
        else
          self.__ptr = self.__ptr + n
          return data:sub(self.__ptr - n, self.__ptr)
        end
      end
    }
  end

  function util.fmkfile(tab, k, w)
    return {
      dir = false,
      read = function(self)
        if self.__read then
          return nil
        end

        self.__read = true
        return tostring(tab[k])
      end,
      write = w and function(self, d)
        tab[k] = tonumber(d) or d
      end or nil
    }
  end

  function util.fnmkfile(r, w)
    return {
      dir = false,
      read = function(s)
        if s.__read then
          return nil
        end
        return r()
      end,
      write = w
    }
  end


-- sysfs: Generic component handler

k.log(k.loglevels.info, "sysfs/handlers/generic")

do
  local function mknew(addr)
    return {
      dir = true,
      addr = util.mkfile(addr),
      type = util.mkfile(component.type(addr)),
      slot = util.mkfile(tostring(component.slot(addr)))
    }
  end

  k.sysfs.handle("generic", mknew)
end


-- sysfs: Directory generator

k.log(k.loglevels.info, "sysfs/handlers/directory")

do
  local function mknew()
    return { dir = true }
  end

  k.sysfs.handle("directory", mknew)
end


-- sysfs: Process handler

k.log(k.loglevels.info, "sysfs/handlers/process")

do
  local function mknew(proc)
    checkArg(1, proc, "process")
    
    local base = {
      dir = true,
      handles = {
        dir = true,
      },
      cputime = util.fmkfile(proc, "cputime"),
      name = util.mkfile(proc.name),
      threads = util.fmkfile(proc, "threads"),
      owner = util.mkfile(proc.owner),
      deadline = util.fmkfile(proc, "deadline"),
      stopped = util.fmkfile(proc, "stopped"),
      waiting = util.fmkfile(proc, "waiting")
    }

    local mt = {
      __index = function(t, k)
        k = tonumber(k) or k
        if not proc.handles[k] then
          return nil, k.fs.errors.file_not_found
        else
          return {dir = false, open = function(m)
            -- you are not allowed to access other
            -- people's files!
            return nil, "permission denied"
          end}
        end
      end,
      __pairs = function(t)
        local iter = pairs(t)
        return function()
          return (iter())
        end
      end
    }
    mt.__ipairs = mt.__pairs

    setmetatable(base, mt)

    return base
  end

  k.sysfs.handle("process", mknew)
end


-- sysfs: TTY device handling

k.log(k.loglevels.info, "sysfs/handlers/tty")

do
  local function mknew(tty)
    return {
      dir = false,
      read = function(_, n)
        return tty:read(n)
      end,
      write = function(_, d)
        return tty:write(d)
      end
    }
  end

  k.sysfs.handle("tty", mknew)
end


-- component-specific handlers
-- #include "sysfs/handlers/"

-- component event handler

-- sysfs: component event handlers

k.log(k.loglevels.info, "sysfs/handlers/component")

do
  local n = {}
  local function added(addr, ctype)
    n[ctype] = n[ctype] or 0
    local path = "/sys/dev/by-address/" .. addr
    local path2 = "/sys/dev/by-type/" .. ctype .. n[ctype]
    n[ctype] = n[ctype] + 1
    local s = k.sysfs.register(ctype, addr, path)
    if not s then
      s = k.sysfs.register("generic", addr, path)
      s = k.sysfs.register("generic", addr, path2)
    else
      k.sysfs.register(ctype, addr, path2)
    end
    return s
  end

  local function removed(addr, ctype)
    local path = "/sys/dev/by-address/" .. addr
    return k.sysfs.unregister(path)
  end

  k.event.register("component_added", added)
  k.event.register("component_removed", removed)
end


end -- sysfs handlers: Done





-- load init, i guess

k.log(k.loglevels.info, "base/load_init")

-- we need to mount the root filesystem first
do
  local root, reftype = nil, "UUID"
  
  if k.cmdline.root then
    local rtype, ref = k.cmdline.root:match("^(.-)=(.+)$")
    reftype = rtype:upper() or "UUID"
    root = ref or k.cmdline.root
  elseif not computer.getBootAddress then
    if not k.logio then
      -- we have no logger output, resort to desparate measures
      -- GOODBYE CRUEL WORLD
      error("cannot determine root filesystem")
    end
  
    -- still error, but slightly less hard
    k.panic("Cannot determine root filesystem!")
  else
    k.log(k.loglevels.warn,
      "\27[101;97mWARNING\27[39;49m use of computer.getBootAddress to detect the root filesystem is discouraged.")
    k.log(k.loglevels.warn,
      "\27[101;97mWARNING\27[39;49m specify root=UUID=<address> on the kernel command line to suppress this message.")
    root = computer.getBootAddress()
    reftype = "UUID"
  end

  local ok, err
  
  if reftype ~= "LABEL" then
    if reftype ~= "UUID" then
      k.log(k.loglevels.warn, "invalid rootspec type (expected LABEL or UUID, got ", reftype, ") - assuming UUID")
    end
  
    if not component.list("filesystem")[root] then
      for k, v in component.list("drive", true) do
        local ptable = k.fs.get_partition_table_driver(k)
    
        if ptable then
          for i=1, #ptable:list(), 1 do
            local part = ptable:partition(i)
        
            if part and (part.address == root) then
              root = part
              break
            end
          end
        end
      end
    end

    ok, err = k.fs.api.mount(root, k.fs.api.types.RAW, "/")
  elseif reftype == "LABEL" then
    local comp
    
    for k, v in component.list() do
      if v == "filesystem" then
        if component.invoke(k, "getLabel") == root then
          comp = root
          break
        end
      elseif v == "drive" then
        local ptable = k.fs.get_partition_table_driver(k)
    
        if ptable then
          for i=1, #ptable:list(), 1 do
            local part = ptable:partition(i)
        
            if part then
              if part.getLabel() == root then
                comp = part
                break
              end
            end
          end
        end
      end
    end

    if not comp then
      k.panic("Could not determine root filesystem from root=", k.cmdline.root)
    end
    
    ok, err = k.fs.api.mount(comp, k.fs.api.types.RAW, "/")
  end

  if not ok then
    k.panic(err)
  end
  
  k.log(k.loglevels.info, "Mounted root filesystem")
end

-- register components with the sysfs, if possible
do
  k.log(k.loglevels.info, "Registering components")
  for k, v in component.list() do
    computer.pushSignal("component_added", k, v)
  end
end

do
  k.log(k.loglevels.info, "Creating userspace sandbox")
  
  local sbox = k.util.copy_table(_G)
  
  k.userspace = sbox
  sbox._G = sbox
  
  k.hooks.call("sandbox", sbox)

  k.log(k.loglevels.info, "Loading init from",
                               k.cmdline.init or "/sbin/init.lua")
  
  local ok, err = loadfile(k.cmdline.init or "/sbin/init.lua")
  
  if not ok then
    k.panic(err)
  end
  
  local ios = k.create_fstream(k.logio, "rw")
  ios.buffer_mode = "none"
  
  k.scheduler.spawn {
    name = "init",
    func = ok,
    input = ios,
    output = ios
  }

  k.log(k.loglevels.info, "Starting scheduler loop")
  k.scheduler.loop()
end

k.panic("Premature exit!")
