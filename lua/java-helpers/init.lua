local M = {}

---@class JavaHelpers.Config
---@field new_file JavaHelpers.NewFileConfig?
---@field stack_trace JavaHelpers.StackTraceConfig?

local new_file = require("java-helpers.new-file")
local stack_trace = require("java-helpers.stack-trace")

---Should be called to initialize this plug-in
---@param opts JavaHelpers.Config? User-provided configuration to override defaults.
function M.setup(opts)
	new_file.setup(opts and opts.new_file or {})
	stack_trace.setup(opts and opts.stack_trace or {})
end

M.create_java_file = new_file.create_java_file
M.go_to_current_java_stack_trace_line = stack_trace.go_to_current_java_stack_trace_line

return M
