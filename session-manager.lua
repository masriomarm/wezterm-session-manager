local wezterm = require("wezterm")
local act = wezterm.action
local mux = wezterm.mux
local session_manager = {}
local os_wezterm = wezterm.target_triple
local save_dir = wezterm.config_dir .. "/"

function create_file_name(workspace_name)
  local prefix = "wezterm_workspace_"
  return prefix .. workspace_name .. ".json"
  end

--- Displays a notification in WezTerm.
-- @param message string: The notification message to be displayed.
local function display_notification(message)
  wezterm.log_info(message)
  -- Additional code to display a GUI notification can be added here if needed
end

--- Retrieves the current workspace data from the active window.
-- @return table or nil: The workspace data table or nil if no active window is found.
local function retrieve_workspace_data(window)
  local workspace_name = window:active_workspace()
  local workspace_data = {
    name = workspace_name,
    tabs = {}
  }

  active_tab_id = window:active_tab():tab_id()

  -- Iterate over tabs in the current window
  for _, tab in ipairs(window:mux_window():tabs()) do
    local tab_data = {
      tab_id = tostring(tab:tab_id()),
      tab_title = tostring(tab:get_title()),
      active_tab = (tab:tab_id() == active_tab_id), 
      panes = {},
    }

    -- Iterate over panes in the current tab
    for _, pane_info in ipairs(tab:panes_with_info()) do
      -- Collect pane details, including layout and process information
      table.insert(tab_data.panes, {
        pane_id = tostring(pane_info.pane:pane_id()),
        index = pane_info.index,
        is_active = pane_info.is_active,
        is_zoomed = pane_info.is_zoomed,
        left = pane_info.left,
        top = pane_info.top,
        width = pane_info.width,
        height = pane_info.height,
        pixel_width = pane_info.pixel_width,
        pixel_height = pane_info.pixel_height,
        cwd = tostring(pane_info.pane:get_current_working_dir()),
        tty = tostring(pane_info.pane:get_foreground_process_name())
      })
    end

    table.insert(workspace_data.tabs, tab_data)
  end

  return workspace_data
end

--- Saves data to a JSON file.
-- @param data table: The workspace data to be saved.
-- @param file_path string: The file path where the JSON file will be saved.
-- @return boolean: true if saving was successful, false otherwise.
local function save_to_json_file(data, file_path)
  if not data then
    wezterm.log_info("No workspace data to log.")
    return false
  end

  local file = io.open(file_path, "w")
  if file then
    file:write(wezterm.json_encode(data))
    file:close()
    return true
  else
    return false
  end
end

--- Recreates the workspace based on the provided data.
-- @param workspace_data table: The data structure containing the saved workspace state.
local function recreate_workspace(window, workspace_data, on_complete)
  local function extract_path_from_dir(working_directory)
    if os_wezterm == "x86_64-pc-windows-msvc" then
      -- On Windows, transform 'file:///C:/path/to/dir' to 'C:/path/to/dir'
      return working_directory:gsub("file:///", "")
    elseif os_wezterm == "x86_64-unknown-linux-gnu" then
      -- On Linux, transform 'file://{computer-name}/home/{user}/path/to/dir' to '/home/{user}/path/to/dir'
      return working_directory:gsub("^.*(/home/)", "/home/")
    else
      return working_directory:gsub("^.*(/Users/)", "/Users/")
    end
  end

  local function finish(ok)
    if on_complete then on_complete(ok) end
  end

  if not workspace_data or not workspace_data.tabs then
    wezterm.log_info("Invalid or empty workspace data provided.")
    finish(false)
    return
  end

  local tabs = window:mux_window():tabs()

  if #tabs ~= 1 or #tabs[1]:panes() ~= 1 then
    wezterm.log_info(
      "Restoration can only be performed in a window with a single tab and a single pane, to prevent accidental data loss.")
    finish(false)
    return
  end

  -- Flatten the nested tab/pane structure into a queue of single mux
  -- operations, so the stepper below stays trivial.
  local plan = {}
  for index, tab_data in ipairs(workspace_data.tabs) do
    table.insert(plan, {
      op = 'tab',
      index = index,
      cwd = extract_path_from_dir(tab_data.panes[1].cwd),
      title = tab_data.tab_title,
      active = tab_data.active_tab,
    })
    for j = 2, #tab_data.panes do
      local pane_data = tab_data.panes[j]
      local direction = 'Right'
      if pane_data.left == tab_data.panes[j - 1].left then
        direction = 'Bottom'
      end
      table.insert(plan, {
        op = 'split',
        direction = direction,
        cwd = extract_path_from_dir(pane_data.cwd),
      })
    end
  end

  local created_tabs = {}
  local active_tab_index = nil
  local current_tab = nil
  local i = 0

  -- Tab titles need two passes, for two separate reasons.
  --
  -- They cannot be set inline right after spawn_tab: under a mux domain a
  -- later spawn discards the write, so only the final tab keeps its name.
  -- Hence pass 1, after every spawn and split is done.
  --
  -- And set_title can report success while still not sticking -- a write
  -- issued close to other mux traffic is dropped silently. Seen with
  -- logging in place: "titled tab 1 -> code" logged no error, yet the tab
  -- came back empty in `wezterm cli list`, reproducibly, always the first
  -- restored tab; on Linux more of them were lost. So pass 2 reads each
  -- title back and re-applies only the ones that did not take. Reads are
  -- cheap, and pass 2 usually issues no writes at all.
  --
  -- Both passes resolve the tab by id rather than reusing the handle
  -- captured during the spawn loop, since those can go stale.
  local function resolve_tab(entry)
    if entry.tab_id then
      local ok, fresh = pcall(function() return wezterm.mux.get_tab(entry.tab_id) end)
      if ok and fresh then return fresh end
    end
    return entry.tab
  end

  local function verify_step(t)
    local entry = created_tabs[t]
    if not entry then
      if active_tab_index then
        -- active_tab_index is the 1-based ipairs index of the saved tab,
        -- while ActivateTab is 0-based. That looks off by one and is not:
        -- restore leaves the window's pre-existing tab at position 0 and
        -- appends the restored tabs after it, so saved tab i lands at
        -- 0-based position i and the two conventions cancel.
        --
        -- Verified rather than assumed: restoring a fixture whose third
        -- saved tab is marked active leaves "zprj" focused, which is that
        -- tab. Do not "correct" this to active_tab_index - 1 without also
        -- handling the leftover tab -- the commented-out block above,
        -- which would exit the initial pane, is exactly what would break
        -- the assumption if it were ever re-enabled.
        window:perform_action(wezterm.action.ActivateTab(active_tab_index), window:active_pane())
      end
      wezterm.log_info("Workspace recreated with new tabs and panes based on saved state.")
      finish(true)
      return
    end
    if entry.title and entry.title ~= '' then
      pcall(function()
        local tab = resolve_tab(entry)
        if tab:get_title() ~= entry.title then
          wezterm.log_info('session-manager: title for tab ' .. t ..
            ' did not stick, re-applying "' .. tostring(entry.title) .. '"')
          tab:set_title(entry.title)
        end
      end)
    end
    wezterm.time.call_after(0.05, function() verify_step(t + 1) end)
  end

  local function title_step(t)
    local entry = created_tabs[t]
    if not entry then
      verify_step(1)
      return
    end
    if entry.title and entry.title ~= '' then
      local ok, err = pcall(function()
        resolve_tab(entry):set_title(entry.title)
      end)
      if not ok then
        wezterm.log_info('session-manager: could not title tab ' .. t ..
          ' ("' .. tostring(entry.title) .. '"): ' .. tostring(err))
      else
        wezterm.log_info('session-manager: titled tab ' .. t .. ' -> "' ..
          tostring(entry.title) .. '"')
      end
    end
    wezterm.time.call_after(0.01, function() title_step(t + 1) end)
  end

  -- Each step runs inside a timer callback, so an error raised here does
  -- NOT propagate to the caller -- it just kills the chain, leaving the
  -- restore silently half-finished with no completion log. Observed
  -- exactly that: a run stopped at 7 panes / 4 tabs with no error and no
  -- "Workspace recreated". pane:split() in particular raises when the
  -- pane has no room left to divide. So every step is guarded, and a
  -- failed split is logged and skipped rather than aborting the restore.
  local function step()
    i = i + 1
    local item = plan[i]

    if not item then
      title_step(1)
      return
    end

    local ok, err = pcall(function()
      if item.op == 'tab' then
        local new_tab = window:mux_window():spawn_tab({ cwd = item.cwd })
        if not new_tab then
          error('spawn_tab returned nil')
        end
        new_tab:activate()
        current_tab = new_tab
        if item.active then
          active_tab_index = item.index
        end
        local ok_id, tab_id = pcall(function() return new_tab:tab_id() end)
        table.insert(created_tabs, {
          tab = new_tab,
          tab_id = ok_id and tab_id or nil,
          title = item.title,
        })
      elseif current_tab then
        current_tab:active_pane():split({
          direction = item.direction,
          cwd = item.cwd,
        })
      end
    end)

    if not ok then
      wezterm.log_info('session-manager: step ' .. i .. ' (' .. item.op ..
        ') failed, continuing: ' .. tostring(err))
    end

    -- Yield: one mux round-trip per event-loop turn keeps the GUI alive.
    wezterm.time.call_after(0.01, step)
  end

  step()
end

--- Loads data from a JSON file.
-- @param file_path string: The file path from which the JSON data will be loaded.
-- @return table or nil: The loaded data as a Lua table, or nil if loading failed.
local function load_from_json_file(file_path)
  local file = io.open(file_path, "r")
  if not file then
    wezterm.log_info("Failed to open file: " .. file_path)
    return nil
  end

  local file_content = file:read("*a")
  os.execute("nu -c 'touch " .. file_path .."'")
  file:close()

  local data = wezterm.json_parse(file_content)
  if not data then
    wezterm.log_info("Failed to parse JSON data from file: " .. file_path)
  end
  return data
end

--- Loads the saved json file matching the current workspace.
function session_manager.restore_state(window)
  local workspace_name = window:active_workspace()
  local file_name = create_file_name(workspace_name)
  local file_path = save_dir .. file_name

  local workspace_data = load_from_json_file(file_path)
  if not workspace_data then
    window:toast_notification('WezTerm',
      'Workspace state file not found for workspace: ' .. workspace_name, nil, 4000)
    return
  end

  -- recreate_workspace is stepped across event-loop turns now, so it
  -- returns immediately and reports through this callback instead of a
  -- return value.
  recreate_workspace(window, workspace_data, function(ok)
    if not ok then
      window:toast_notification('WezTerm', 'Workspace "'.. workspace_name .. '" restore fail', nil, 4000)
    end
  end)
end

--- Allows to select which workspace to load
function session_manager.load_state(window)
  -- TODO: Implement
  -- Placeholder for user selection logic
  -- ...
  -- TODO: Call the function recreate_workspace(workspace_data) to recreate the workspace
  -- Placeholder for recreation logic...
end

--- Orchestrator function to save the current workspace state.
-- Collects workspace data, saves it to a JSON file, and displays a notification.
function session_manager.save_state(window)
  local data = retrieve_workspace_data(window)

  -- Construct the file path based on the workspace name
  local file_name = create_file_name(data.name)
  local file_path = save_dir .. file_name

  -- Save the workspace data to a JSON file and display the appropriate notification
  local status = 'fail'
  if save_to_json_file(data, file_path) then
    status = 'success'
  end
  local message = "WezTerm Session Manager, Workspace: "  .. data.name .. '. Save ' .. status
  window:toast_notification('WezTerm', message, nil, 4000)
  wezterm.log_info(message)
end

return session_manager
