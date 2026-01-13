# saveAction.nvim

A Neovim plugin that automatically copies files on save, with support for Java compilation and XML validation.

## Features

- **Automatic file copying**: Copy files from source to destination directories on save
- **Java compilation**: Automatically compile Java files using `javac` with incremental compilation support
- **XML validation**: Validate XML files against XSD schemas using `xmllint`
- **Multiple source/destination pairs**: Configure multiple src/dst mappings
- **Classpath management**: Support for both `.classpath` and `saveAction.properties` classpath configuration
- **Verbose logging**: Configurable notification levels

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "yourusername/saveAction.nvim",
  config = function()
    require("saveAction").setup({
      verbose = true,
      ignore_errors = false,
      silent = false,
      enabled = true,
    })
  end,
},
```

## Configuration

Create a `saveAction.properties` file in your project directory. The plugin searches for this file in:
1. The directory of the current file being saved
2. The current working directory
3. Parent directories (up to 10 levels)

## Properties Reference

| Property | Description |
|----------|-------------|
| `PRJ` | Project name used for `{PRJ}` placeholder substitution |
| `src` or `src.0` | Source directory (first pair) |
| `dst` or `dst.0` | Destination directory (first pair) |
| `src.N` | Source directory (Nth pair, N > 0) |
| `dst.N` | Destination directory (Nth pair, N > 0) |
| `dst.classpath` | Output directory for compiled Java classes |
| `classpath.N` | Classpath entries (directories containing JARs or class files) |

## Examples

### Basic Single Directory Copy

```properties
src=~/projects/myapp/src
dst=/var/www/html/src
```

### Multiple Source/Destination Pairs

```properties
PRJ=myapp

src.0=/home/dev/projects/myapp/src/main/java
dst.0=/home/dev/projects/myapp/target/classes

src.1=/home/dev/projects/myapp/src/main/resources
dst.1=/home/dev/projects/myapp/target/classes

src.2=/home/dev/projects/myapp/config
dst.2=/home/dev/projects/myapp/deploy/config
```

### Java Project with Classpath

```properties
PRJ=myproject

src=/c/gitlab/eco/eco_rep7/src/main/java
dst=/c/gitlab/eco/eco_rep7/target/classes

dst.classpath=target/classes

classpath.0=target/lib/*.jar
classpath.1=target/classes
classpath.2=/c/Users/dev/.m2/repository/org/apache/commons/commons-lang3/3.12.0/commons-lang3-3.12.0.jar
```

### Java Project with Maven Dependencies

```properties
PRJ=backend-service

src=/projects/backend/src/main/java
dst=/projects/backend/target/classes

dst.classpath=target/classes

classpath.0=/projects/backend/lib
classpath.1=/opt/java/openjdk/lib/jmods
```

### Using {PRJ} Placeholder

```properties
PRJ=order-service

src={PRJ}/src/main/java
dst={PRJ}/target/classes

src.1={PRJ}/src/main/resources
dst.1={PRJ}/target/classes
```

Expands to:
```
src=order-service/src/main/java
dst=order-service/target/classes
src.1=order-service/src/main/resources
dst.1=order-service/target/classes
```

### Windows-style Paths

```properties
PRJ=myapp

src=C:\projects\myapp\src\main\java
dst=C:\projects\myapp\target\classes

dst.classpath=target/classes

classpath.0=C:\projects\myapp\lib
classpath.1=C:\Program Files\Java\jdk-17\lib
```

### Complete Example with XML Validation

```properties
PRJ=enterprise-app

src.0=C:/dev/projects/enterprise-app/src/main/java
dst.0=C:/dev/projects/enterprise-app/target/classes

src.1=C:/dev/projects/enterprise-app/src/main/resources
dst.1=C:/dev/projects/enterprise-app/target/classes

src.2=C:/dev/projects/enterprise-app/config
dst.2=C:/dev/projects/enterprise-app/deploy

dst.classpath=target/classes

classpath.0=C:/dev/projects/enterprise-app/lib
classpath.1=C:/dev/projects/enterprise-app/target/classes
```

## Environment Variables

The plugin supports environment variable expansion using `%%` syntax:

```properties
PRJ=myapp

src=%USERPROFILE%/projects/{PRJ}/src
dst=%PROGRAMFILES%/deploy/{PRJ}
```

## Commands

| Command | Description |
|---------|-------------|
| `:SaveActionEnable` | Enable the plugin |
| `:SaveActionDisable` | Disable the plugin |
| `:SaveActionStatus` | Show current configuration |
| `:SaveActionToggle` | Toggle plugin enabled/disabled |
| `:SaveActionInitialCopy` | Perform initial copy from src to dst |

## Keybindings

| Keybinding | Description |
|------------|-------------|
| `<leader>sae` | Enable saveAction |
| `<leader>sad` | Disable saveAction |
| `<leader>saS` | Show saveAction status |
| `<leader>saT` | Toggle saveAction |
| `<leader>jI` | Perform initial copy |
| `<C-s>` | Save file (normal/insert mode) |

## Java Compilation Features

- **Incremental compilation**: Only compiles Java files if the source is newer than the class file
- **Classpath resolution**: Supports both `.classpath` XML format and `classpath.N` properties
- **Maven support**: Automatically fetches classpath from `pom.xml` for Maven projects
- **JRE/JDK container**: Detects and includes Java module paths from `JAVA_HOME`

## XML Validation Features

- **XSD schema detection**: Automatically finds XSD files in common locations
- **schemaLocation support**: Parses `xsi:schemaLocation` attribute to find schemas
- **Fallback search**: Searches buffer directory for matching `.xsd` files
- **Error/warning reporting**: Reports validation errors and warnings

## Troubleshooting

### Plugin not working

1. Check if `saveAction.properties` exists in your project directory
2. Run `:SaveActionStatus` to verify configuration
3. Enable verbose mode in setup for debug output

### Java compilation fails

1. Ensure `javac` is in your PATH
2. Check classpath entries point to valid directories/JARs
3. Verify `JAVA_HOME` is set for JRE container resolution

### XML validation skipped

1. Ensure `xmllint` is installed (part of libxml2)
2. Check that XSD files exist in expected locations
3. Disable silent mode to see warning messages

## Requirements

- Neovim 0.8+
- `javac` (optional, for Java compilation)
- `xmllint` (optional, for XML validation)
- `mvn` (optional, for Maven classpath resolution)
