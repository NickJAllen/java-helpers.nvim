local M = {}

local new_file = require("java-helpers.new-file")
local stack_trace = require("java-helpers.stack-trace")

---Should be called to initialize this plug-in
---@param opts table|nil User-provided configuration to override defaults.
function M.setup(opts)
	new_file.setup(opts)
	stack_trace.setup(opts)
end

M.create_java_file = new_file.create_java_file
M.go_to_current_java_stack_trace_line = stack_trace.go_to_current_java_stack_trace_line

return M
