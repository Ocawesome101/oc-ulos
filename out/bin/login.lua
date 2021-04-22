-- login.  finally!!!

local users = require("users")

io.write("\n\nWelcome to ULOS.\n\n")

while true do
  io.write("\27?0clogin: ")
  local un = io.read("l")
  io.write("password: \27?11c")
  local pw = io.read("l")
  io.write("\n\27?0c")
  local uid = users.get_uid(un)
  if not uid then
    io.write("no such user\n\n")
  else
    local ok, err = users.authenticate(uid, pw)
    if not ok then
      io.write(err, "\n\n")
    else
      local info = users.attributes(uid)
      local shell = info.shell or "/bin/sh"
      if not shell:match("%.lua$") then
        shell = string.format("%s.lua", shell)
      end
      local shell, sherr = loadfile(shell)
      if not shell then
        io.write("failed loading shell: ", sherr, "\n\n")
      else
        users.exec_as(uid, pw, shell, shell, true)
      end
    end
  end
end
