# **java-helpers.nvim**

A lightweight Neovim plugin written in Lua for quickly navigating printed Java stack traces and creating new Java files (Classes, Interfaces, Enums, Records, etc.) with the correct package declaration automatically determined from the current buffer or file explorer context.

<!-- toc -->

- [Features](#features)
  * [Java Stack Trace Navigation](#java-stack-trace-navigation)
  * [New File Creation](#new-file-creation)
- [Demos](#demos)
  * [Selecting a line from a stack trace using Snacks picker](#selecting-a-line-from-a-stack-trace-using-snacks-picker)
  * [Deobfuscate a stack trace in place in a log file](#deobfuscate-a-stack-trace-in-place-in-a-log-file)
  * [Create a new Java class in same package as current Java file](#create-a-new-java-class-in-same-package-as-current-java-file)
  * [Create a new type in the same package as current Java file](#create-a-new-type-in-the-same-package-as-current-java-file)
- [Installation and Configuration](#installation-and-configuration)
  * [lazy.nvim](#lazynvim)
- [Usage](#usage)
  * [**1\. Interactive File Creation**](#1-interactive-file-creation)
  * [**2\. Direct File Creation (Using Arguments)**](#2-direct-file-creation-using-arguments)
- [**🔧 Configuration**](#%F0%9F%94%A7-configuration)
  * [**Template Placeholders**](#template-placeholders)

<!-- tocstop -->

## Features

### Java Stack Trace Navigation

* Ability to jump to any line in a stack trace
* Supports nested Java exceptions so that navigation works in actual call order (not printed order)
* Use Snacks picker to select a line from stack trace 
* All commands can get stack trace from current buffer (default) or a vim register (e.g '+' for system clipboard) if provided as extra argument to command
* Commands to quickly navigate up and down or to the top or bottom of the stack trace
* Commands to go to next and previous stack trace (e.g when viewing a log file)
* Send stack trace to quickfix list
* Supports jdtls or java_language_server LSP in order to look up file path from class name
* Quickly and easily deobfuscate stack traces (in place, on the clipboard, or just directly use the obfuscated one and it's deobfuscated automatically for you)

### New File Creation

* **Automatic Package Detection:** Intelligent determination of the correct package declaration based on standard Maven/Gradle source directories (src/main/java, src/test/java, etc.) and the current file path.  
* **Context-Aware Creation:** Works from a regular buffer, or while selecting a directory in file explorers like **MiniFiles**, **Oil.nvim**, **Snacks Explorer**, or **Neo-tree**.  
* **Template-Based:** Ships with built-in templates for common Java types (Class, Interface, Enum, Record, Annotation, Abstract Class).  
* **Customizable:** Easily override built-in templates or define your own custom templates.  
* **LSP Formatting:** Automatically formats the newly created file using the attached Language Server (via vim.lsp.buf.format()) if configured.

## Demos

### Selecting a line from a stack trace using Snacks picker

Demonstation of the ":JavaHelpersPickStackTraceLine" command:

![Java Stack Picker](https://github.com/NickJAllen/resources/blob/main/java-helpers/java-stack-picker.gif)

### Deobfuscate a stack trace in place in a log file

Demonstation of the ":JavaHelpersDeobfuscate" command:

![Inplace Stack Deobfuscation](https://github.com/NickJAllen/resources/blob/main/java-helpers/inplace-stack-deobfuscation.gif)

### Create a new Java class in same package as current Java file

Demonstation of the ":JavaHelpersNewFile Class"

![New Class Creation](https://github.com/NickJAllen/resources/blob/main/java-helpers/new-class-creation.gif)

### Create a new type in the same package as current Java file

Demonstation of the ":JavaHelpersNewFile"

![Java Stack Picker](https://github.com/NickJAllen/resources/blob/main/java-helpers/new-type-creation.gif)

## Installation and Configuration

Use your favorite package manager.

### lazy.nvim

An example for lazy.nvim with some quick key bindings to navigate Java stack traces and to create Java files:

```
  {
    'NickJAllen/java-helpers.nvim',
    cmd = {
      'JavaHelpersNewFile',
      'JavaHelpersPickStackTraceLine',
      'JavaHelpersPickStackTrace',
      'JavaHelpersGoToStackTraceLine',
      'JavaHelpersGoUpStackTrace',
      'JavaHelpersGoDownStackTrace',
      'JavaHelpersGoToBottomOfStackTrace',
      'JavaHelpersGoToTopOfStackTrace',
      'JavaHelpersGoToNextStackTrace',
      'JavaHelpersGoToPrevStackTrace',
      'JavaHelpersSendStackTraceToQuickfix',
      'JavaHelpersDeobfuscate',
      'JavaHelpersSelectObfuscationFile',
      'JavaHelpersForgetObfuscationFile',
    },

    ---@type JavaHelpers.Config
    opts = {
      new_file = {
        ---Each template has a name and some template source code.
        ---${package_decl} and ${name} will be replaced with the package declaration and name for the Java type being created.
        ---If ${pos} is provided then the cursor will be positioned there ready to type.
        templates = {},

        ---Defines patters to recognize Java source directories in order to determine the package name.
        java_source_dirs = { 'src/main/java', 'src/test/java', 'src' },

        ---If true then newly created Java files will be formatted
        should_format = true,
      },

      stack_trace = {
        --Command that is used to deobfuscate stack traces
        deobfuscate_command = 'retrace',

        --Directory that will be used to select an obfuscation mapping file, if nil or empty the current directory will be used
        obfuscation_mappings_dir = vim.uv.os_homedir() .. '/.obfuscation',
      },
    },
    keys = {
      -- New file creation
      { '<leader>jn', ':JavaHelpersNewFile<cr>', desc = 'New Java Type' },
      { '<leader>jc', ':JavaHelpersNewFile Class<cr>', desc = 'New Java Class' },
      { '<leader>ji', ':JavaHelpersNewFile Interface<cr>', desc = 'New Java Interface' },
      { '<leader>ja', ':JavaHelpersNewFile Abstract Class<cr>', desc = 'New Abstract Java Class' },
      { '<leader>jr', ':JavaHelpersNewFile Record<cr>', desc = 'New Java Record' },
      { '<leader>je', ':JavaHelpersNewFile Enum<cr>', desc = 'New Java Enum' },

      -- Stack trace navigation
      { '<leader>jg', ':JavaHelpersGoToStackTraceLine<cr>', desc = 'Go to Java stack trace line' },
      { '<leader>jG', ':JavaHelpersGoToStackTraceLine +<cr>', desc = 'Go to Java stack trace line on Clipboard' },
      { '<leader>jp', ':JavaHelpersPickStackTraceLine<cr>', desc = 'Pick Java stack trace line' },
      { '<leader>jP', ':JavaHelpersPickStackTraceLine +<cr>', desc = 'Pick Java stack trace line from Clipboard' },
      { '<leader>js', ':JavaHelpersPickStackTrace<cr>', desc = 'Pick Java stack trace in current file' },
      { '[j', ':JavaHelpersGoUpStackTrace<cr>', desc = 'Go up Java stack trace' },
      { ']j', ':JavaHelpersGoDownStackTrace<cr>', desc = 'Go down Java stack trace' },
      { '[J', ':JavaHelpersGoToPrevStackTrace<cr>', desc = 'Go to previous Java stack trace' },
      { ']J', ':JavaHelpersGoToNextStackTrace<cr>', desc = 'Go to next Java stack trace' },
      { '<leader>jt', ':JavaHelpersGoToTopOfStackTrace<cr>', desc = 'Go to top of Java stack trace' },
      { '<leader>jb', ':JavaHelpersGoToBottomOfStackTrace<cr>', desc = 'Go to bottom of Java stack trace' },
      { '<leader>jq', ':JavaHelpersSendStackTraceToQuickfix<cr>', desc = 'Send Java stack trace to quickfix list' },
      { '<leader>jd', ':JavaHelpersDeobfuscate<cr>', desc = 'Deofuscate Java stack trace' },
      { '<leader>jD', ':JavaHelpersDeobfuscate +<cr>', desc = 'Deofuscate Java stack trace on Clipboard' },
      { '<leader>jo', ':JavaHelpersSelectObfuscationFile<cr>', desc = 'Select obfuscation file' },
    },
    dependencies = {
      'nvim-lua/plenary.nvim',

      -- This is only needed if you want to use the JavaHelpersPickStackTraceLine or JavaHelpersSelectObfuscationFile commands (but highly recommended)
      'folke/snacks.nvim',
    },
  }


```

## Usage

The plugin exposes the following user commands: 

* JavaHelpersNewFile
* JavaHelpersGoToStackTraceLine
* JavaHelpersGoUpStackTrace
* JavaHelpersGoDownStackTrace
* JavaHelpersGoToTopStackTrace
* JavaHelpersGoToBottomOfStackTrace
* JavaHelpersSendStackTraceToQuickfix
* JavaHelpersPickStackTraceLine

### **1\. Interactive File Creation**

Run the command without any arguments. This opens an interactive selection list (using vim.ui.select) for you to choose one of the templates, and then prompts you for the name.

:JavaHelpersNewFile

### **2\. Direct File Creation (Using Arguments)**

You can also provide the template name directly to skip the interactive prompt for template selection.

| Syntax | Description |
| :---- | :---- |
| :JavaHelpersNewFile \<TemplateName\> | Uses the supplied template name, then prompts for the Name. |

**Examples:**

```
" Opens a chooser to select the type (class, enum etc) and then afterwards asks for the name
:JavaHelpersNewFile

" Opens a prompt asking for the class name, then creates the file  
:JavaHelpersNewFile Class

" Opens a prompt asking for the name of an Interface  
:JavaHelpersNewFile Interface
```

The argument (\<TemplateName\>) supports command-line completion, suggesting available templates (Class, Enum, Interface, etc.). The name is case insensitive.

## **🔧 Configuration**

These are the default configuration options:

```
-- Default configuration
{
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
```

The plug-in has some built-in templates but you can also define your own or override any the existing ones. The following templates are built-in and can't be removed (just redefined):

```
{
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
```

To define your own templates simply add them inside the 'templates' of your configuration. For example, here is a lazy.nvim configuration defining a new template:

```
{
    'NickJAllen/java-helpers.nvim',
    cmd = 'JavaHelpersNewFile',

    opts = {

        ---Each template has a name and some template source code.
        ---${package_decl} and ${name} will be replaced with the package declaration and name for the Java type being created.
        ---If ${pos} is provided then the cursor will be positioned there ready to type.
        ---@type TemplateDefinition[]
        templates = {
            {
                name = "MyCustomTemplate",
                template = [[${package_decl}public class ${name} extends MyBaseClass {
    ${pos}
}]],

            }
        },
    },
    dependencies = {
      { 'nvim-lua/plenary.nvim' },
    },
}
```

### **Template Placeholders**

When defining or overriding templates, the following placeholders are processed:

| Placeholder | Description |
| :---- | :---- |
| ${package\_decl} | Replaced with a package declaration for the detected package or an empty string if no package could be detected. |
| ${name} | Replaced with the type name provided by the user (e.g., MyClass). |
| ${pos} | **Optional.** If present, the cursor is placed at this exact location after the file is created and opened. The placeholder itself is removed from the content. |
