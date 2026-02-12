local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality

-- Create (but not start) child Neovim object
local child = MiniTest.new_child_neovim()

-- Define main test set of this file
local T = new_set({
	-- Register hooks
	hooks = {
		-- This will be executed before every (even nested) case
		pre_case = function()
			-- Restart child process with custom 'init.lua' script
			child.restart({ "-u", "scripts/minimal_init.lua" })
			-- Load tested plugin
			child.lua([[M = require('hello_lines')]])
		end,
		-- This will be executed one after all tests from this set are finished
		post_once = child.stop,
	},
})

-- Define main test set of this file
local T = new_set()

---@class JavaStackTraceElement
---@field class_name string
---@field file_name string?
---@field line_number integer

---@class TestStackLine
---@field line string
---@field expected JavaStackTraceElement|nil

---@type TestStackLine[]
local test_stack_lines = {
	{
		line = "           at com.example.MyClass.doSomething(MyClass.java:100)",
		expected = {
			class_name = "com.example.MyClass",
			file_name = "MyClass.java",
			line_number = 100,
		},
	},
	{
		line = "           at com.example.MyClass.<init>(MyClass.java:1234)",
		expected = {
			class_name = "com.example.MyClass",
			file_name = "MyClass.java",
			line_number = 1234,
		},
	},
	{
		line = "some text to ignore           at com.example.MyClass.doSomething(MyClass.java:100) more text to ignore\n",
		expected = {
			class_name = "com.example.MyClass",
			file_name = "MyClass.java",
			line_number = 100,
		},
	},
}

for i, test_stack_line in ipairs(test_stack_lines) do
	T["Can parse stack " .. i] = function()
		local M = require("java-helpers.stack-trace")
		local actual_parsed = M.parse_java_stack_trace_line(test_stack_line.line)
		eq(actual_parsed, test_stack_line.expected)
	end
end

return T
