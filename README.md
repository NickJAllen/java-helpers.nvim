# **java-helpers.nvim**

A lightweight Neovim plugin written in Lua for quickly creating new Java files (Classes, Interfaces, Enums, Records, etc.) with the correct package declaration automatically determined from the current buffer or file explorer context.

## **✨ Features**

* **Automatic Package Detection:** Intelligent determination of the correct package declaration based on standard Maven/Gradle source directories (src/main/java, src/test/java, etc.) and the current file path.  
* **Context-Aware Creation:** Works from a regular buffer, or while selecting a directory in file explorers like **Neo-tree** or **Oil.nvim**.  
* **Template-Based:** Ships with built-in templates for common Java types (Class, Interface, Enum, Record, Annotation, Abstract Class).  
* **Customizable:** Easily override built-in templates or define your own custom templates.  
* **LSP Formatting:** Automatically formats the newly created file using the attached Language Server (via vim.lsp.buf.format()) if configured.

## **⚙️ Installation**

Use your favorite package manager.

### **lazy.nvim**

{  
  'your-username/java-helpers.nvim',  
  lazy \= false, \-- Load at startup for the command to be available  
  config \= function()  
    require('java-helpers').setup({  
      \-- Optional configuration goes here  
    })  
  end  
}

## **🚀 Usage**

The plugin exposes a single user command: :JavaHelpersNewFile.

### **1\. Interactive Creation (Recommended)**

Run the command without any arguments. This opens an interactive selection list (using vim.ui.select) for you to choose the type, and then prompts you for the name.

:JavaHelpersNewFile

### **2\. Direct Creation (Using Arguments)**

You can provide the type and name directly to skip the interactive prompts.

| Syntax | Description |
| :---- | :---- |
| :JavaHelpersNewFile \<Type\> | Selects the Type, then prompts for the Name. |
| :JavaHelpersNewFile \<Type\> \<Name\> | Creates the file immediately. |

**Examples:**

" Opens a prompt asking for the class name, then creates the file  
:JavaHelpersNewFile Class

" Creates a Record named 'User' immediately  
:JavaHelpersNewFile Record User

" Opens a prompt asking for the name of an Interface  
:JavaHelpersNewFile Interface

The first argument (\<Type\>) supports command-line completion, suggesting available templates (Class, Enum, Interface, etc.).

## **🔧 Configuration**

The setup function allows you to override defaults, add custom templates, and change source directory patterns.

require('java-helpers').setup({  
    \-- Determines package name based on these source directories.  
    \-- The current path is checked against these patterns.  
    java\_source\_dirs \= {  
        "src/main/java",  
        "src/test/java",  
        "src"  
    },

    \-- If true, calls vim.lsp.buf.format() after creation and cursor placement.  
    should\_format \= true,

    \-- Define custom templates or override built-in ones  
    templates \= {  
        {  
            name \= "TestClass",  
            template \= \[\[${package\_decl}import org.junit.jupiter.api.Test;

public class ${name}Test {  
    @Test  
    void testSomething() {  
        ${pos}  
    }  
}  
\]\],  
        },  
        \-- Overrides the built-in 'Class' template  
        {  
            name \= "Class",  
            template \= \[\[${package\_decl}  
public final class ${name} {  
    private ${name}() {}

    ${pos}  
}  
\]\],  
        },  
    },  
})

### **Template Placeholders**

When defining or overriding templates, the following placeholders are processed:

| Placeholder | Description |
| :---- | :---- |
| ${package\_decl} | Replaced with package com.example.mypackage;\\n\\n or an empty string if no package is found. |
| ${name} | Replaced with the type name provided by the user (e.g., MyClass). |
| ${pos} | **Optional.** If present, the cursor is placed at this exact location after the file is created and opened. The placeholder itself is removed from the content. |
