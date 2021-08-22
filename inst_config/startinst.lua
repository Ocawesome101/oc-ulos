-- basic script for starting the installer --

local handle = assert(io.open("/sys/dev/tty0"))
handle.tty = 0
handle.buffer_mode = "none"

local lsh = assert(loadfile("/bin/lsh.lua"))

require("process").spawn {
	name = "lsh",
	func = function()
		return lsh("--exec=installer")
	end,
	stdin=handle,
	stdout=handle,
	stderr=handle,
	input=handle,
	output=handle
}
