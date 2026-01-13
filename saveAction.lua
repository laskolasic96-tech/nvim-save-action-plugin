local M = {}

local config = {
  enabled = false,
  src = nil,
  dst = nil,
  pairs = nil,
  verbose = false,
  ignore_errors = false,
  silent = false,
  config_path = nil,
}

local function parse_properties(filepath)
  local props = {}
  if vim.fn.filereadable(filepath) ~= 1 then
    return nil
  end
  for line in io.lines(filepath) do
    local key, value = line:match("^([^=]+)=(.+)$")
    if key and value then
      props[key] = value:gsub("^%s*(.-)%s*$", "%1"):gsub("%%(%w+)", function(s)
        return vim.fn.expand("$" .. s)
      end)
    end
  end
  return props
end

local function find_config_file()
  local search_dirs = {}

  if vim.bo.filetype and vim.fn.expand("%:p") ~= "" then
    local buf_path = vim.fn.expand("%:p:h")
    table.insert(search_dirs, buf_path)
  end

  local current_dir = vim.fn.getcwd()
  if current_dir ~= "/" then
    table.insert(search_dirs, current_dir)
  end

  for _, dir in ipairs(search_dirs) do
    local search_path = dir
    for i = 1, 10 do
      local config_path = search_path .. "/saveAction.properties"
      if vim.fn.filereadable(config_path) == 1 then
        return config_path
      end
      local parent = vim.fn.fnamemodify(search_path, ":h")
      if parent == search_path or parent == "/" then
        break
      end
      search_path = parent
    end
  end

  return nil
end

local function expand_path(path, config_dir)
  if not path then return nil end
  if path:sub(1, 1) == "~" then
    return vim.fn.expand(path)
  elseif not path:match("^/") and not path:match("^%a:") then
    return config_dir .. "/" .. path
  end
  return path
end

local function load_config()
  local config_path = find_config_file()
  if not config_path then
    return false
  end

  local props = parse_properties(config_path)
  if not props then
    return false
  end

  local config_dir = vim.fn.fnamemodify(config_path, ":h")
  
  -- Get PRJ from properties and expand {PRJ} placeholders
  local prj = props["PRJ"] or ""
  
  local function expand_prj(value)
    if not value then return nil end
    return value:gsub("{PRJ}", prj)
  end

  -- Build pairs from src.N / dst.N entries
  local pairs_list = {}
  
  -- Check for src.0, src.1, etc.
  local max_index = -1
  for key, _ in pairs(props) do
    local idx = key:match("^src%.(%d+)$")
    if idx then
      local n = tonumber(idx)
      if n and n > max_index then
        max_index = n
      end
    end
  end
  
  -- Also check for plain src (no index) as src.0
  if props.src then
    if max_index < 0 then max_index = 0 end
  end
  
  for i = 0, max_index do
    local src_key = (i == 0 and "src") or "src." .. i
    local dst_key = (i == 0 and "dst") or "dst." .. i
    
    local src = expand_prj(props[src_key])
    local dst = expand_prj(props[dst_key])
    
    if src and dst then
      src = expand_path(src, config_dir)
      dst = expand_path(dst, config_dir)
      
      if src:sub(-1) == "/" then src = src:sub(1, -2) end
      if dst:sub(-1) == "/" then dst = dst:sub(1, -2) end
      
      if vim.fn.isdirectory(src) == 1 then
        vim.fn.mkdir(dst, "p")
        table.insert(pairs_list, { src = src, dst = dst })
      end
    end
  end

  if #pairs_list == 0 then
    return false
  end

  config.config_path = config_path
  config.pairs = pairs_list
  config.enabled = true

  if config.verbose and not config.silent then
    if #config.pairs == 1 then
      vim.notify("saveAction: " .. config.pairs[1].src .. " -> " .. config.pairs[1].dst, vim.log.levels.INFO)
    else
      local parts = {}
      for _, pair in ipairs(config.pairs) do
        table.insert(parts, pair.src .. " -> " .. pair.dst)
      end
      vim.notify("saveAction: (" .. #config.pairs .. " pairs) " .. table.concat(parts, ", "), vim.log.levels.INFO)
    end
  end

  -- Store classpath destination if specified
  local dst_classpath = expand_prj(props["dst.classpath"])
  if dst_classpath then
    config.dst_classpath = expand_path(dst_classpath, config_dir)
  end

  return true
end

local function get_relative_path(filepath, src)
  local abs_filepath = vim.fn.fnamemodify(filepath, ":p"):gsub("\\", "/")
  local abs_src = vim.fn.fnamemodify(src, ":p"):gsub("\\", "/")

  if abs_src:sub(-1) ~= "/" then abs_src = abs_src .. "/" end

  if abs_filepath:sub(1, #abs_src) == abs_src then
    return abs_filepath:sub(#abs_src + 1)
  end

  return nil
end

local function find_pair_for_file(filepath)
  for _, pair in ipairs(config.pairs) do
    local rel_path = get_relative_path(filepath, pair.src)
    if rel_path then
      return pair, rel_path
    end
  end
  return nil, nil
end

local function compile_java_incremental(filepath)
  filepath = filepath:gsub("\\", "/")

  vim.notify("DEBUG compile_java: Starting for " .. filepath, vim.log.levels.INFO)

  -- Try to read classpath from saveAction.properties first
  local props = nil
  if config.config_path and vim.fn.filereadable(config.config_path) == 1 then
    props = parse_properties(config.config_path)
  end

  -- Build classpath from classpath.N entries in properties file
  local classpath_libs = {}
  local classpath_dirs = {}  -- Add class directories too
  if props then
    local prj = props["PRJ"] or ""
    for key, value in pairs(props) do
      if key:match("^classpath%.%d+$") then
        local cp_value = value:gsub("{PRJ}", prj)
        -- Expand relative paths
        if cp_value:sub(1, 1) ~= "/" and not cp_value:match("^%a:") then
          local config_dir = vim.fn.fnamemodify(config.config_path, ":h")
          cp_value = config_dir .. "/" .. cp_value
        end
        
        -- Check if path exists
        if vim.fn.isdirectory(cp_value) == 1 then
          -- Add all JARs from directory
          local has_jars = false
          for _, f in ipairs(vim.fn.readdir(cp_value)) do
            if f:match("%.jar$") then
              table.insert(classpath_libs, cp_value .. "/" .. f)
              has_jars = true
            end
          end
          if has_jars then
            vim.notify("DEBUG compile_java: Added JARs from " .. cp_value, vim.log.levels.INFO)
          else
            -- No JARs, it's a classes directory - add to classpath
            table.insert(classpath_dirs, cp_value)
            vim.notify("DEBUG compile_java: Added class directory " .. cp_value, vim.log.levels.INFO)
          end
        elseif vim.fn.filereadable(cp_value) == 1 then
          -- It's a file, add directly
          table.insert(classpath_libs, cp_value)
        else
          vim.notify("DEBUG compile_java: Classpath path not found: " .. cp_value, vim.log.levels.WARN)
        end
      end
    end
  end

  -- Fall back to .classpath file parsing if no classpath.N entries
  local classpath
  local project_dir
  
  if #classpath_libs == 0 then
    local classpath_file = nil
    if config.config_path and vim.fn.filereadable(config.config_path) == 1 then
      classpath_file = vim.fn.fnamemodify(config.config_path, ":h") .. "/.classpath"
    end

    if not classpath_file or vim.fn.filereadable(classpath_file) ~= 1 then
      vim.notify("DEBUG compile_java: No classpath source found (.classpath or classpath.N)", vim.log.levels.ERROR)
      return nil
    end

    local content = vim.fn.readfile(classpath_file)
    local xml = table.concat(content, "\n")

    project_dir = vim.fn.fnamemodify(classpath_file, ":p"):gsub("\\", "/"):gsub("/%.[^/]*$", "")
    vim.notify("DEBUG compile_java: project_dir = " .. project_dir, vim.log.levels.INFO)

    classpath = {
      sources = {},
      output = "target/classes",
      libs = {},
    }

    for line in xml:gmatch("[^\n]+") do
      local kind = line:match('kind="([^"]+)"')
      local path = line:match('path="([^"]+)"')
      local output = line:match('output="([^"]+)"')

      if kind == "src" then
        table.insert(classpath.sources, path)
      elseif kind == "output" then
        if output then classpath.output = output end
      elseif kind == "lib" then
        local lib_path = path
        if lib_path:sub(1, 1) ~= "/" and not lib_path:match("^%a:") then
          lib_path = project_dir .. "/" .. lib_path
        end
        table.insert(classpath.libs, lib_path)
      elseif kind == "con" then
        if path:match("JRE_CONTAINER") or path:match("JAVA") then
          local java_home = os.getenv("JAVA_HOME")
          if java_home and java_home ~= "" then
            local jmods = java_home .. "/jmods"
            if vim.fn.isdirectory(jmods) == 1 then
              for _, f in ipairs(vim.fn.readdir(jmods)) do
                if f:match("%.jmod$") then
                  table.insert(classpath.libs, jmods .. "/" .. f)
                end
              end
            end
          end
        elseif path:match("MAVEN2_CLASSPATH_CONTAINER") then
          vim.notify("DEBUG compile_java: Getting Maven classpath via mvn...", vim.log.levels.INFO)
          local mvn_cp = vim.fn.system("mvn -f " .. project_dir .. "/pom.xml dependency:build-classpath -Dmdep.outputFile=/dev/stdout -q 2>&1")
          if vim.v.shell_error == 0 then
            for lib in mvn_cp:gmatch("[^;]+") do
              lib = lib:gsub("^%s*(.-)%s*$", "%1")
              if lib ~= "" and lib:match("%.jar$") then
                table.insert(classpath.libs, lib)
              end
            end
            vim.notify("DEBUG compile_java: Found " .. #classpath.libs .. " Maven JARs", vim.log.levels.INFO)
          else
            vim.notify("DEBUG compile_java: mvn command failed", vim.log.levels.ERROR)
          end
        end
      end
    end
  else
    -- Use classpath from saveAction.properties
    project_dir = vim.fn.fnamemodify(filepath, ":p"):gsub("\\", "/"):gsub("/src/main/.*$", "")
    vim.notify("DEBUG compile_java: Using classpath from saveAction.properties", vim.log.levels.INFO)
    vim.notify("DEBUG compile_java: project_dir = " .. project_dir, vim.log.levels.INFO)
    vim.notify("DEBUG compile_java: Found " .. #classpath_libs .. " classpath entries", vim.log.levels.INFO)

    classpath = {
      sources = {},
      output = config.dst_classpath or "target/classes",
      libs = vim.list_extend(classpath_libs, classpath_dirs),
    }
  end

  local function normalize_path(path)
    path = path:gsub("\\", "/")
    local parts = {}
    for part in path:gmatch("([^/]+)") do
      if part == ".." then
        if #parts > 0 and parts[#parts] ~= ".." then
          table.remove(parts)
        else
          table.insert(parts, part)
        end
      elseif part ~= "." then
        table.insert(parts, part)
      end
    end
    local result = table.concat(parts, "/")
    if path:match("^%a:") then
      result = result:gsub("^/", "")
    end
    return result
  end

  local java_abs = normalize_path(filepath)
  local src_abs = nil

  for _, s in ipairs(classpath.sources) do
    local s_abs
    if s:sub(1, 1) == "/" or s:match("^%a:") then
      s_abs = normalize_path(s)
    else
      s_abs = normalize_path(project_dir .. "/" .. s)
    end
    if java_abs:sub(1, #s_abs + 1) == s_abs .. "/" then
      src_abs = s_abs
      break
    end
  end

  if not src_abs then
    src_abs = normalize_path(vim.fn.fnamemodify(filepath, ":h"))
  end

  local rel_path = filepath:sub(#src_abs + 1)
  local class_filename = rel_path:gsub("%.java$", ".class"):gsub("^/", "")

  local output_abs
  if classpath.output:sub(1, 1) == "/" or classpath.output:match("^%a:") then
    output_abs = classpath.output:gsub("/$", "")
  else
    output_abs = project_dir .. "/" .. classpath.output:gsub("/$", "")
  end

  local class_file = output_abs .. "/" .. class_filename
  vim.notify("DEBUG compile_java: Expected class file: " .. class_file, vim.log.levels.INFO)

  local java_mtime = vim.fn.getftime(filepath)
  local class_exists = vim.fn.filereadable(class_file) == 1

  vim.notify("DEBUG compile_java: java_mtime = " .. java_mtime .. ", class_exists = " .. tostring(class_exists), vim.log.levels.INFO)

  if class_exists then
    local class_mtime = vim.fn.getftime(class_file)
    vim.notify("DEBUG compile_java: class_mtime = " .. class_mtime, vim.log.levels.INFO)
    if java_mtime <= class_mtime then
      if config.verbose and not config.silent then
        vim.notify("Skipping (up-to-date): " .. vim.fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
      end
      return true
    end
  end

  if vim.fn.isdirectory(output_abs) == 0 then
    vim.notify("DEBUG compile_java: Creating output directory: " .. output_abs, vim.log.levels.INFO)
    vim.fn.mkdir(output_abs, "p")
  end

  local cp_parts = {}
  for _, lib in ipairs(classpath.libs) do
    table.insert(cp_parts, lib)
  end
  
  local target_dir = project_dir .. "/target/classes"
  vim.notify("DEBUG compile_java: Checking target/classes: " .. target_dir, vim.log.levels.INFO)
  if vim.fn.isdirectory(target_dir) == 1 then
    table.insert(cp_parts, target_dir)
    vim.notify("DEBUG compile_java: Added target/classes to classpath", vim.log.levels.INFO)
  end
  
  local cp_string = table.concat(cp_parts, ";")
  vim.notify("DEBUG compile_java: Classpath length = " .. #cp_string, vim.log.levels.INFO)

  local cmd = { "javac", "-d", output_abs, "-cp", cp_string, filepath }
  vim.notify("DEBUG compile_java: Running javac command...", vim.log.levels.INFO)
  local output = vim.fn.systemlist(cmd)

  vim.notify("DEBUG compile_java: shell_error = " .. vim.v.shell_error, vim.log.levels.INFO)
  vim.notify("DEBUG compile_java: javac output:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)

  if vim.v.shell_error ~= 0 then
    vim.notify("DEBUG compile_java: Compilation FAILED", vim.log.levels.ERROR)
    if config.verbose and not config.silent then
      vim.notify("Compilation failed: " .. vim.fn.fnamemodify(filepath, ":t") .. "\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
    end
    return false
  else
    vim.notify("DEBUG compile_java: Compilation SUCCEEDED", vim.log.levels.INFO)
    if config.verbose and not config.silent then
      vim.notify("Compiled: " .. vim.fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
    end
    return true
  end
end

local function validate_xml(filepath)
  -- Check if xmllint is available
  local xmllint_cmd = vim.fn.executable("xmllint") == 1
  if not xmllint_cmd then
    vim.notify("DEBUG validate_xml: xmllint not available, skipping validation", vim.log.levels.WARN)
    return nil
  end

  -- Try to find XSD from schemaLocation in XML
  local content = vim.fn.readfile(filepath)
  local xml_content = table.concat(content, "\n")
  
  -- Look for schemaLocation attribute
  local schema_location = xml_content:match('xsi:schemaLocation="([^"]+)"') or xml_content:match('schemaLocation="([^"]+)"')
  
  local xsd_path = nil
  
  if schema_location then
    vim.notify("DEBUG validate_xml: Found schemaLocation: " .. schema_location, vim.log.levels.INFO)
    -- Extract the XSD file path (last part after last space/tab)
    local last_space = schema_location:match("()%s") or #schema_location
    local xsd_file = schema_location:match("/([^/]+%.xsd)$") or schema_location:match("([^/]+%.xsd)$")
    
    if xsd_file then
      -- Try to find XSD in common locations
      local search_paths = {
        vim.fn.fnamemodify(filepath, ":h") .. "/",
        vim.fn.fnamemodify(filepath, ":h"):gsub("/config/.*$", "/schemas/"),
        "C:/gitlab/eco/eco_rep7/target/iGate/schemas/",
        "C:/gitlab/eco/eco_rep7/target/iGate/products/ua-web-login/schema/",
      }
      
      for _, base_path in ipairs(search_paths) do
        local candidate = base_path .. xsd_file
        vim.notify("DEBUG validate_xml: Checking: " .. candidate, vim.log.levels.INFO)
        if vim.fn.filereadable(candidate) == 1 then
          xsd_path = candidate
          vim.notify("DEBUG validate_xml: Found XSD: " .. xsd_path, vim.log.levels.INFO)
          break
        end
      end
    end
  end
  
  -- Fallback: search for XSD in buffer directory
  if not xsd_path then
    local function find_xsd(dir)
      for _, f in ipairs(vim.fn.readdir(dir)) do
        local full_path = dir .. "/" .. f
        if vim.fn.isdirectory(full_path) == 1 then
          if f ~= "." and f ~= ".." then
            local found = find_xsd(full_path)
            if found then return found end
          end
        elseif f:match("%.xsd$") then
          -- Prefer XSD that matches the XML filename or contains "report" for this file
          if f:match(vim.fn.fnamemodify(filepath, ":t"):gsub("%.xml$", "")) or f:match("report") then
            return full_path
          end
        end
      end
      return nil
    end
    
    local buf_dir = vim.fn.fnamemodify(filepath, ":h")
    xsd_path = find_xsd(buf_dir)
  end

  if not xsd_path then
    if config.verbose and not config.silent then
      vim.notify("No XSD found for " .. vim.fn.fnamemodify(filepath, ":t"), vim.log.levels.WARN)
    end
    return nil
  end

  local cmd = { "xmllint", "--schema", xsd_path, filepath, "--noout" }
  vim.notify("DEBUG validate_xml: Running: " .. table.concat(cmd, " "), vim.log.levels.INFO)
  local output = vim.fn.systemlist(cmd)

  local has_errors = false
  local has_warnings = false

  for _, line in ipairs(output) do
    vim.notify("DEBUG validate_xml: " .. line, vim.log.levels.INFO)
    if line:match("error") then has_errors = true end
    if line:match("warning") then has_warnings = true end
  end

  if has_errors then
    if config.verbose and not config.silent then
      vim.notify("XML errors:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
    end
    return false
  elseif has_warnings then
    if config.verbose and not config.silent then
      vim.notify("XML warnings:\n" .. table.concat(output, "\n"), vim.log.levels.WARN)
    end
    return true
  end

  if config.verbose and not config.silent then
    vim.notify("XML valid: " .. vim.fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
  end
  return true
end

local function process_file(filepath)
  if config.verbose and not config.silent then
    vim.notify("saveAction: processing " .. filepath, vim.log.levels.INFO)
  end

  vim.notify("DEBUG: process_file called for: " .. filepath, vim.log.levels.INFO)
  vim.notify("DEBUG: config.enabled = " .. tostring(config.enabled), vim.log.levels.INFO)

  if not config.enabled then
    vim.notify("DEBUG: Loading config...", vim.log.levels.INFO)
    if not load_config() then
      vim.notify("DEBUG: load_config returned false", vim.log.levels.ERROR)
      return
    end
    vim.notify("DEBUG: Config loaded successfully", vim.log.levels.INFO)
  end

  local pair, rel_path = find_pair_for_file(filepath)
  if not pair then
    vim.notify("DEBUG: No pair found for file", vim.log.levels.WARN)
    return
  end
  vim.notify("DEBUG: Found pair: " .. pair.src .. " -> " .. pair.dst, vim.log.levels.INFO)

  local filename = vim.fn.fnamemodify(filepath, ":t")
  vim.notify("DEBUG: filename = " .. filename, vim.log.levels.INFO)

  if filename:match("%.java$") then
    vim.notify("DEBUG: Calling compile_java_incremental for Java file", vim.log.levels.INFO)
    local compile_result = compile_java_incremental(filepath)
    vim.notify("DEBUG: compile_java_incremental returned: " .. tostring(compile_result), vim.log.levels.INFO)
  elseif filename:match("%.xml$") then
    pcall(validate_xml, filepath)
  else
    vim.notify("DEBUG: File is not Java or XML, skipping compilation", vim.log.levels.INFO)
  end

  local saved_any = false
  for _, p in ipairs(config.pairs) do
    local rp = get_relative_path(filepath, p.src)
    if rp then
      local dst_path = p.dst .. "/" .. rp
      local dst_dir = vim.fn.fnamemodify(dst_path, ":h")

      if vim.fn.isdirectory(dst_dir) == 0 then
        vim.fn.mkdir(dst_dir, "p")
      end

      local ok, err = pcall(function()
        local content = vim.fn.readfile(filepath)
        vim.fn.writefile(content, dst_path)
      end)

      if ok then
        saved_any = true
      else
        if not config.ignore_errors then
          if config.verbose and not config.silent then
            vim.notify("save failed: " .. err, vim.log.levels.ERROR)
          end
        end
      end
    end
  end

  if saved_any and config.verbose and not config.silent then
    vim.notify("saved: " .. rel_path, vim.log.levels.INFO)
  end
end

function M.initialCopy()
  if not load_config() then
    vim.notify("saveAction: no saveAction.properties found", vim.log.levels.WARN)
    return
  end

  if not config.pairs or #config.pairs == 0 then
    vim.notify("saveAction: no src/dst pairs configured", vim.log.levels.WARN)
    return
  end

  vim.notify("saveAction: starting initial copy...", vim.log.levels.INFO)

  local copied_count = 0
  local error_count = 0

  for _, pair in ipairs(config.pairs) do
    local function copy_dir(src, dst)
      vim.fn.mkdir(dst, "p")

      for _, f in ipairs(vim.fn.readdir(src)) do
        local src_path = src .. "/" .. f
        local dst_path = dst .. "/" .. f

        if vim.fn.isdirectory(src_path) == 1 then
          copy_dir(src_path, dst_path)
        else
          local content = vim.fn.readfile(src_path)
          vim.fn.writefile(content, dst_path)
          copied_count = copied_count + 1
        end
      end
    end

    if vim.fn.isdirectory(pair.src) == 1 then
      vim.notify("saveAction: copying " .. pair.src .. " -> " .. pair.dst, vim.log.levels.INFO)
      local ok, err = pcall(function()
        copy_dir(pair.src, pair.dst)
      end)
      if not ok then
        vim.notify("saveAction: error copying " .. pair.src .. ": " .. err, vim.log.levels.ERROR)
        error_count = error_count + 1
      end
    else
      vim.notify("saveAction: src not found: " .. pair.src, vim.log.levels.WARN)
    end
  end

  vim.notify(string.format("saveAction: initial copy complete. Copied: %d, Errors: %d",
    copied_count, error_count), vim.log.levels.INFO)
end

function M.enable()
  if load_config() then
    setup_autocmds()
    if config.verbose and not config.silent then
      if #config.pairs == 1 then
        vim.notify("saveAction: enabled", vim.log.levels.INFO)
      else
        vim.notify("saveAction: enabled (" .. #config.pairs .. " pairs)", vim.log.levels.INFO)
      end
    end
  else
    if config.verbose and not config.silent then
      vim.notify("saveAction: no saveAction.properties found", vim.log.levels.WARN)
    end
  end
end

function M.disable()
  config.enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, "SaveAction")
  if config.verbose and not config.silent then
    vim.notify("saveAction: disabled", vim.log.levels.INFO)
  end
end

function M.status()
  if config.enabled and config.pairs then
    local parts = {}
    for i, pair in ipairs(config.pairs) do
      table.insert(parts, pair.src .. " -> " .. pair.dst)
    end
    print("saveAction: " .. table.concat(parts, ", "))
  else
    print("saveAction: disabled")
  end
end

function M.toggle()
  if config.enabled then
    M.disable()
  else
    M.enable()
  end
end

local function setup_autocmds()
  local augroup = vim.api.nvim_create_augroup("SaveAction", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = "*",
    group = augroup,
    callback = function(ev)
      process_file(ev.match)
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    pattern = "*",
    group = augroup,
    callback = function()
      load_config()
    end,
    once = true,
  })
end

function M.setup(opts)
  opts = opts or {}
  config.verbose = opts.verbose or false
  config.ignore_errors = opts.ignore_errors or false
  config.silent = opts.silent or false

  local loaded = load_config()

  setup_autocmds()

  if loaded then
    config.enabled = opts.enabled ~= false
  elseif opts.enabled then
    config._pending_enable = true
  end

  vim.api.nvim_create_user_command("SaveActionEnable", M.enable, {})
  vim.api.nvim_create_user_command("SaveActionDisable", M.disable, {})
  vim.api.nvim_create_user_command("SaveActionStatus", M.status, {})
  vim.api.nvim_create_user_command("SaveActionToggle", M.toggle, {})
  vim.api.nvim_create_user_command("SaveActionInitialCopy", M.initialCopy, {})

  vim.keymap.set("n", "<leader>sae", ":SaveActionEnable<CR>", { desc = "Enable saveAction", silent = true })
  vim.keymap.set("n", "<leader>sad", ":SaveActionDisable<CR>", { desc = "Disable saveAction", silent = true })
  vim.keymap.set("n", "<leader>saS", ":SaveActionStatus<CR>", { desc = "SaveAction status", silent = true })
  vim.keymap.set("n", "<leader>saT", ":SaveActionToggle<CR>", { desc = "Toggle saveAction", silent = true })
  vim.keymap.set("n", "<leader>jI", ":SaveActionInitialCopy<CR>", { desc = "Initial copy from src to dst", silent = true })

  vim.keymap.set("i", "<C-s>", "<Esc>:write<CR>a", { desc = "Save and stay in insert", silent = true })
  vim.keymap.set("n", "<C-s>", ":write<CR>", { desc = "Save file", silent = true })
end

return M