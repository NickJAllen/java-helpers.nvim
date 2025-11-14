local M = {}

local log = require("plenary.log").new({ plugin = "java-creator", level = "info" })

---@class TemplateDefinition
---@field name string The name of the template
---@field template string The source of the template

---Bult-in templates - these can't be deleted but they can be overridden
---@type TemplateDefinition[]
local builtin_templates = {
	{
		name = "Class",
		template = [[${package_decl}public class ${name} {
    ${pos}
}]],
	},
	{
		name = "Interface",
		template = [[${package_decl}public interface ${name} {
    ${pos}
}]],
	},
	{
		name = "Abstract Class",
		template = [[${package_decl}public abstract class ${name} {
    ${pos} 
}]],
	},
	{
		name = "Record",
		template = [[${package_decl}public record ${name}(${pos}) {

}]],
	},
	{
		name = "Enum",
		template = [[${package_decl}public enum ${name} {
    ${pos}
}]],
	},
	{
		name = "Annotation",
		template = [[${package_decl}public @interface ${name} {
    ${pos}
}]],
	},
}

-- Default configuration
local default_config = {
	---Each template has a name and some template source code.
	---${package_decl} and ${name} will be replaced with the package declaration and name for the Java type being created.
	---If ${pos} is provided then the cursor will be positioned there ready to type.
	---@type TemplateDefinition[]
	templates = {},

	---Defines patters to recognize Java source directories in order to determine the package name.
	---@type string[]
	java_source_dirs = { "src/main/java", "src/test/java", "src" },

	---If true then newly created Java files will be formatted
	---@type boolean
	should_format = true,
}

local config = {}

---All defined templates with name as the key and the template source as the value
---@type table<string, string>
local all_templates = {}

---All template names defined in order
---@type string[]
local all_template_names = {}

---
--- Validates if a string is a valid Java identifier and also not a keyword.
---
---@param name string The identifier to validate.
---@return string|nil The error message or nil if everything is valid
local function validate_java_name(name)
	if not name or name == "" then
		return "Name cannot be empty"
	end
	if not name:match("^[a-zA-Z_]") then
		return "Name must start with a letter or underscore"
	end
	if not name:match("^[a-zA-Z0-9_]*$") then
		return "Name can only contain letters, numbers, and underscores"
	end

	local java_keywords = {
		"abstract",
		"assert",
		"boolean",
		"break",
		"byte",
		"case",
		"catch",
		"char",
		"class",
		"const",
		"continue",
		"default",
		"do",
		"double",
		"else",
		"enum",
		"extends",
		"final",
		"finally",
		"float",
		"for",
		"goto",
		"if",
		"implements",
		"import",
		"instanceof",
		"int",
		"interface",
		"long",
		"native",
		"new",
		"null",
		"package",
		"private",
		"protected",
		"public",
		"return",
		"short",
		"static",
		"strictfp",
		"super",
		"switch",
		"synchronized",
		"this",
		"throw",
		"throws",
		"transient",
		"try",
		"void",
		"volatile",
		"while",
		"true",
		"false",
	}

	for _, keyword in ipairs(java_keywords) do
		if name == keyword then
			return "Name cannot be a Java keyword: " .. keyword
		end
	end

	return nil
end

---If the supplied path is a directory then returns that otherwise if it is a file then the directory the file is inside
---@param path string The path name
---@return string
local function get_dir(path)
	-- Make path absolute
	local abs_path = vim.fn.fnamemodify(path, ":p")

	-- Check if it's a directory
	if vim.fn.isdirectory(abs_path) == 1 then
		return abs_path -- keep directory as-is
	else
		-- It's a file, return parent directory
		return vim.fn.fnamemodify(abs_path, ":h")
	end
end

---@return string|nil
local function get_neo_tree_current_dir_impl()
	local manager = require("neo-tree.sources.manager")

	local state = manager.get_state("filesystem")
	local node = state.tree:get_node()
	local path = node:get_id()

	if path then
		return get_dir(path)
	end

	return nil
end

---@param buf integer The buffer number to check if it's a neo-tree or not
---@return string|nil dir_path The path to the current directory in neo tree or nil if the buffer is not a neo tree buffer.
local function get_neo_tree_current_dir(buf)
	local file_type = vim.bo[buf].filetype

	if file_type ~= "neo-tree" then
		return nil
	end

	local ok, dir = pcall(get_neo_tree_current_dir_impl)

	if not ok then
		log.error("Could not get current directory in neo tree: " .. tostring(dir))
		return nil
	end

	return dir
end

---@param buf integer The buffer number to check if it's an oil buffer or not
---@return string|nil dir_path The path to the current directory in the oil buffer or nil if the buffer is not an oil buffer.
local function get_oil_current_dir(buf)
	local file_type = vim.bo[buf].filetype

	if file_type ~= "oil" then
		return nil
	end

	local filepath = vim.api.nvim_buf_get_name(buf)
	local prefix = "oil://"

	if not filepath:sub(1, #prefix) == prefix then
		log.error("File path for oil buffer does not start with " .. prefix)
		return nil
	end

	return vim.fn.fnamemodify(filepath:sub(#prefix + 1), ":p:h")
end

-- Gets the current directory in an intelligent way.
-- If the user is focused in neo-tree then it retuns the path to the current directory that is selected there.
-- If the current buffer is an oil buffer then returns the directory of oil.
-- Otherwise, if the user is editing a file then it uses the current diretory of that file.
-- If none of those work then it returns vim.fn.getcwd()
--- @return string
local function get_current_directory()
	local buf = vim.api.nvim_get_current_buf()

	if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
		local dir = get_neo_tree_current_dir(buf)

		if dir then
			return dir
		end

		dir = get_oil_current_dir(buf)

		if dir then
			return dir
		end

		if vim.bo[buf].buftype == "" then
			local filepath = vim.api.nvim_buf_get_name(buf)

			return vim.fn.fnamemodify(filepath, ":p:h")
		end
	end

	return vim.fn.getcwd()
end

--- @param str string
--- @param ending string
--- @return boolean
function string.ends_with(str, ending)
	return ending == "" or str:sub(-#ending) == ending
end

-- Tries to find the source directory and package name using the registered patterns for the supplied path
--- @param path string
--- @return string | nil source_dir_path
--- @return string | nil package_name
local function determine_source_directory_and_package_from_path(path)
	for _, pattern in ipairs(config.java_source_dirs) do
		local _, end_index = path:find("/" .. pattern .. "/")

		if end_index then
			local package_name = path:sub(end_index + 1):gsub("/", ".")

			return path, package_name
		elseif path:ends_with("/" .. pattern) then
			return path, ""
		end
	end

	return nil
end

---@param java_source_code string
---@return string | nil
local function get_package_from_java_source_code(java_source_code)
	return java_source_code:match("package%s+([^;]+);")
end

--- @param buffer_id integer
--- @return string | nil source_dir_path
--- @return string | nil package_name
local function determine_source_directory_and_package_from_buffer(buffer_id)
	local path = vim.api.nvim_buf_get_name(buffer_id)

	if not path:ends_with(".java") then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(buffer_id, 0, -1, true)

	for _, line in ipairs(lines) do
		local package_name = get_package_from_java_source_code(line)

		if package_name then
			local buffer_dir = vim.fn.fnamemodify(path, ":p:h")

			return buffer_dir, package_name
		end
	end
end

--- @return string source_dir_path
--- @return string package_name
local function determine_source_directory_and_package()
	local current_dir = get_current_directory()

	local source_dir, package_name = determine_source_directory_and_package_from_path(current_dir)

	if source_dir and package_name then
		log.trace("Found source dir " .. source_dir .. " and package " .. package_name .. " from path " .. current_dir)
		return source_dir, package_name
	end

	local current_buffer = vim.api.nvim_get_current_buf()

	source_dir, package_name = determine_source_directory_and_package_from_buffer(current_buffer)

	if source_dir and package_name then
		log.trace("Found source dir " .. source_dir .. " and package " .. package_name .. " from current buffer")
		return source_dir, package_name
	end

	log.info("Could not determine source directory and package name so using defalut package")
	return current_dir, ""
end

---Finds the line and column of the start of the suppied substring in the given text
---@param text string
---@param substring string
---@return integer | nil line Line number (1 based)
---@return integer | nil column Column number (0 based)
local function find_line_col(text, substring)
	-- Split text into lines
	local lines = vim.split(text, "\n", { plain = true })

	for line_num, line_text in ipairs(lines) do
		local col = string.find(line_text, substring, 1, true) -- plain text search
		if col then
			col = col - 1

			return line_num, col
		end
	end

	return nil, nil
end

---Instantiates a template filling in the package declaration and type name.
--- @param template_source string The template source that should be used to generate the type
--- @param package_name string The package name the type should be in
--- @param name string The name of the type to create
--- @return string result The instantiated template text
--- @return integer cursor_line The line where the cursor should be positioned
--- @return integer cursor_column The column where the cursor should be positioned
local function instantiate_template(template_source, package_name, name)
	local package_decl = ""

	if package_name ~= "" then
		package_decl = "package " .. package_name .. ";\n\n"
	end

	local result = template_source:gsub("${package_decl}", package_decl)
	result = result:gsub("${name}", name)

	local cursor_line, cursor_col = find_line_col(result, "${pos}")

	if cursor_line and cursor_col then
		result = result:gsub("${pos}", "")
	else
		cursor_line = 0
		cursor_col = 0
	end

	return result, cursor_line, cursor_col
end

---@return string[] List of all known template names
local function get_template_names()
	return all_template_names
end

---Given the name of a template, looks up the template source or nil if not found
---@param template_name string
---@return string|nil The template source or nil if not found
local function get_template(template_name)
	return all_templates[template_name]
end

---Asks the user to select one of the available templates to use
---@param callback function The function to call with the selected template name.
local function select_template(callback)
	vim.ui.select(get_template_names(), {
		prompt = "New Java File",
	}, callback)
end

--- Asks the user for the name of the type to be created
---@param template_name string Name of the template
---@param callback function() The function to call with the user's input.
local function ask_for_name(template_name, callback)
	vim.ui.input({
		prompt = template_name .. " Name",
		default = "",
	}, function(name)
		if not name or name == "" then
			return
		end

		local error = validate_java_name(name)

		if error then
			log.error("Invalid name for Java type: " .. name)
			ask_for_name(template_name, callback)
			return
		end

		callback(name)
	end)
end

--- Creates the Java file after validating inputs.
---@param template string The template source to use
---@param name string The type name.
---@param source_dir string The directory where the Java file should be created
---@param package_name string The package name.
local function create_java_file(template, name, source_dir, package_name)
	local file_path = source_dir .. "/" .. name .. ".java"
	if vim.fn.filereadable(file_path) == 1 then
		log.error("File already exists: " .. file_path)
		return
	end

	local content, cursor_line, cursor_col = instantiate_template(template, package_name, name)

	local file = io.open(file_path, "w")

	if not file then
		log.error("Could not create file: " .. file_path)
		return
	end

	file:write(content)
	file:close()

	vim.cmd("edit " .. file_path)
	vim.api.nvim_win_set_cursor(0, { cursor_line, cursor_col })

	if config.should_format then
		vim.lsp.buf.format()
	end
end

---Adds a new template with the supplied name
---@param name string The name of the template to add
---@param template string The template source
local function add_template(name, template)
	local is_new_template = all_templates[name] == nil

	all_templates[name] = template

	if is_new_template then
		table.insert(all_template_names, name)
	end
end

---Adds a template from a template definition (a lua table with name and template keys)
---@param template_definition TemplateDefinition
function M.add_template(template_definition)
	local name = template_definition["name"]

	if not name then
		log.error("Template name not provided for template defintion " .. vim.inspect(template_definition))
		return
	end

	local template = template_definition["template"]

	if not template then
		log.error("Template source not provided for template defintion " .. vim.inspect(template_definition))
		return
	end

	add_template(name, template)
end

---Adds some new templates.
---@param templates TemplateDefinition[] Template definitions to add
function M.add_templates(templates)
	for _, template_definition in ipairs(templates) do
		M.add_template(template_definition)
	end
end

---Creates a new java type using the supplied (optional) template name.
---If the template name is not provided then the user will be asked to select one.
---@param template_name string|nil The template name to use or nil if user should select one
---@param type_name string|nil The type name to create or nil if should ask the user for the name
function M.create_java_file(template_name, type_name)
	if not template_name or template_name == "" then
		select_template(function(selected_template)
			if not selected_template then
				return
			end

			M.create_java_file(selected_template, type_name)
		end)

		return
	end

	local template = get_template(template_name)

	if not template then
		log.error("No template with name " .. template_name)
		return
	end

	local source_dir, package_name = determine_source_directory_and_package()

	if not type_name or type_name == "" then
		ask_for_name(template_name, function(name)
			create_java_file(template, name, source_dir, package_name)
		end)

		return
	end

	create_java_file(template, type_name, source_dir, package_name)
end

---Should be called to initialize this plug-in
---@param opts table|nil User-provided configuration to override defaults.
function M.setup(opts)
	config = vim.tbl_deep_extend("force", default_config, opts or {})

	M.add_templates(builtin_templates)

	local user_templates = config.templates

	if user_templates then
		M.add_templates(user_templates)
	end

	vim.api.nvim_create_user_command("JavaHelpersNewFile", function(command_options)
		M.create_java_file(command_options.args)
	end, {
		nargs = "?",
		desc = "Create a new Java file",
		complete = function(_, _, _)
			return get_template_names()
		end,
	})
end

return M
