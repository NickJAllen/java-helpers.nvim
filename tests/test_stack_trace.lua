local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

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

---@class TestStackLine
---@field line string
---@field expected JavaStackTraceElement|nil

---@type TestStackLine[]
local test_stack_lines = {
	{
		line = "           at com.example.MyClass.doSomething(MyClass.java:100)",
		expected = {
			class_name = "com.example.MyClass",
			method_name = "doSomething",
			file_name = "MyClass.java",
			line_number = 100,
		},
	},
	{
		line = "           at com.example.MyClass.<init>(MyClass.java:1234)",
		expected = {
			class_name = "com.example.MyClass",
			method_name = "<init>",
			file_name = "MyClass.java",
			file_name = "MyClass.java",
			line_number = 1234,
		},
	},
	{
		line = "some text to ignore           at com.example.MyClass.doSomething(MyClass.java:100) more text to ignore\n",
		expected = {
			class_name = "com.example.MyClass",
			method_name = "doSomething",
			file_name = "MyClass.java",
			line_number = 100,
		},
	},
	{
		line = "at java.base/java.lang.Thread.dumpStack(Thread.java:1383)",
		expected = {
			class_name = "java.lang.Thread",
			method_name = "dumpStack",
			file_name = "Thread.java",
			line_number = 1383,
		},
	},
	{
		line = "    at com.example.SomeClass$NestedClass.someMethod(Unknown Source)",
		expected = {
			class_name = "com.example.SomeClass",
			method_name = "someMethod",
			file_name = "Unknown Source",
			line_number = 1,
		},
	},
	{
		line = "    at com.example.SomeClass$NestedClass.someMethod(SomeClass.java)",
		expected = {
			class_name = "com.example.SomeClass",
			method_name = "someMethod",
			file_name = "SomeClass.java",
			line_number = 1,
		},
	},
	{
		line = "    at java.base/java.util.ArrayList$Itr.checkForComodification(Unknown Source)",
		expected = {
			class_name = "java.util.ArrayList",
			method_name = "checkForComodification",
			file_name = "Unknown Source",
			line_number = 1,
		},
	},
	{
		line = "    at java.base/java.util.Collections$UnmodifiableCollection$1.next(Native Method)",
		expected = {
			class_name = "java.util.Collections",
			method_name = "next",
			file_name = "Native Method",
			line_number = 1,
		},
	},
	{
		line = "        at com.example.MyClass.lambda$0(MyClass.java:596)",
		expected = {
			class_name = "com.example.MyClass",
			method_name = "lambda$0",
			file_name = "MyClass.java",
			line_number = 596,
		},
	},
	{
		line = "This is not a stack trace",
		expected = nil,
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
