--!nonstrict
-- LOQ RGB: service (no UI). Owns the profile and talks to the keyboard through helper/lamparray.py.
--   * panel and widget send requests through noctalia.state; the service reacts to them (no polling)
--   * it computes the colours, writes DATA_DIR/command.txt and the helper animates the transition
--   * it saves the profile as JSON in noctalia.pluginDataDir() and publishes status for the UI
local P = require("./lib/profile.luau")

local BUSY_MS = 33                   -- only while a command write waits for the rate limit
local MIN_WRITE_GAP_MS = 33          -- at most ~30 commands per second while dragging a slider
local DRAG_GAP_MS = 220              -- requests closer than this count as a drag (short fades)
local HEARTBEAT_TIMEOUT_MS = 20000   -- the helper prints a heartbeat every 5 s
local HUNG_AFTER_SILENT_ROUNDS = 3   -- alive but silent for 3 timeouts in a row: replace it
local PYTHON_RECHECK_MS = 10000      -- how often to look for python3 while it is missing
local SAVE_DEBOUNCE_MS = 1500

local dataDir = noctalia.pluginDataDir()
local commandPath = dataDir and (dataDir .. "/command.txt")
local commandTmp = dataDir and (dataDir .. "/command.tmp")
local profilePath = dataDir and (dataDir .. "/profile.json")
local profileTmp = dataDir and (dataDir .. "/profile.tmp")

local profile = P.defaults()
local status = { state = "starting" }
local cmdSeq = noctalia.nowMs()
local lastReqMs = 0
local lastWriteMs = 0
local pendingMs = nil                -- transition (ms) of a command waiting to be written; last request wins
local dirtySince = nil
local lastBeat = 0
local helperStarted = false
local helperGen = 0                  -- lines from a replaced helper are ignored
local probing = false
local silentRounds = 0
local paletteSig = ""
local lastPaletteMs = 0
local lastPythonCheckMs = 0
local interval = 0

local function setInterval(ms)
  if ms ~= interval then
    interval = ms
    noctalia.setUpdateInterval(ms)
  end
end

-- Wake-ups cost something: poll the palette once a second only when it matters, and rarely otherwise.
local function idleInterval()
  if status.state ~= "ready" then
    return 5000
  end
  if profile.on and profile.mode == "palette" then
    return 1000
  end
  return 3000
end

local function transitionMs()
  local v = noctalia.getConfig("transition_ms")
  if type(v) ~= "number" then
    return 350
  end
  return math.max(0, math.min(2000, v))
end

local function publishProfile()
  noctalia.state.set("kb_profile", profile)
end

local function setStatus(obj)
  status = obj
  noctalia.state.set("kb_status", status)
  if pendingMs == nil and dirtySince == nil then
    setInterval(idleInterval())
  end
end

-- tmp + rename, so a reader never sees a half-written file.
local function atomicWrite(tmp, path, text)
  if not path then
    return false
  end
  if noctalia.writeFile(tmp, text) and noctalia.renameFile(tmp, path) then
    return true
  end
  return noctalia.writeFile(path, text) -- last resort; the helper ignores a command without its END line
end

-- ---------------------------------------------------------------- persistence
local function loadProfile()
  if not profilePath then
    return
  end
  local raw = noctalia.readFile(profilePath)
  if raw then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      profile = P.sanitize(decoded)
    end
  end
end

local function saveProfile()
  local encoded = noctalia.json.encode(profile)
  if encoded then
    atomicWrite(profileTmp, profilePath, encoded)
  end
end

-- ---------------------------------------------------------------- helper commands
local function writeCommand(ms)
  if status.state ~= "ready" or type(status.zones) ~= "number" or not commandPath then
    return
  end
  local mode, colors = "rgb", ""
  if not profile.on then
    mode = "off"
  elseif profile.mode == "firmware" then
    mode = "auto"
  else
    local cols = P.colors(profile, status.zones)
    if not cols then
      return
    end
    colors = table.concat(cols, ",")
    paletteSig = P.paletteSignature(profile)
  end
  cmdSeq = cmdSeq + 1
  atomicWrite(commandTmp, commandPath,
    string.format("seq=%.0f\nmode=%s\nbr=%.0f\nms=%.0f\ncolors=%s\nEND\n", cmdSeq, mode, profile.br, ms, colors))
  lastWriteMs = noctalia.nowMs()
end

local function flush(now)
  if pendingMs ~= nil and now - lastWriteMs >= MIN_WRITE_GAP_MS then
    local ms = pendingMs
    pendingMs = nil
    writeCommand(ms)
  end
end

local function requestSend(ms)
  pendingMs = ms
  flush(noctalia.nowMs())
  if pendingMs ~= nil then
    setInterval(BUSY_MS)
  end
end

local function markDirty()
  dirtySince = noctalia.nowMs()
end

-- ---------------------------------------------------------------- helper process
local function onHelperLine(line)
  local tag, body = string.match(line, "^(%u+)%s*(.*)$")
  if tag == "BEAT" then
    lastBeat = noctalia.nowMs()
    silentRounds = 0
  elseif tag == "STATE" then
    local obj = noctalia.json.decode(body)
    if type(obj) == "table" then
      lastBeat = noctalia.nowMs()
      silentRounds = 0
      setStatus(obj)
      if obj.state == "ready" then
        writeCommand(0)
      end
    end
  end
end

local function startHelper()
  if not dataDir or not noctalia.pluginDir() then
    setStatus({ state = "error", message = "no plugin directory" })
    return
  end
  if not noctalia.commandExists("python3") then
    helperStarted = false
    setStatus({ state = "needs_python" })
    return
  end
  if status.state == "needs_python" then
    setStatus({ state = "starting" })
  end
  -- noctalia.runStream returns no handle: an older stream cannot be stopped from here. Lines from a
  -- replaced helper are dropped by the generation check, and the new helper makes the old one leave
  -- (see takeover_previous in the helper).
  helperGen = helperGen + 1
  local gen = helperGen
  local script = noctalia.pluginDir() .. "/helper/lamparray.py"
  lastBeat = noctalia.nowMs()
  silentRounds = 0
  -- "exec" so that stopping the stream signals Python directly (it then hands the keyboard back)
  helperStarted = noctalia.runStream("exec python3 -u " .. P.shellQuote(script) .. " " .. P.shellQuote(dataDir), function(line)
    if gen == helperGen then
      onHelperLine(line)
    end
  end)
  if not helperStarted then
    setStatus({ state = "error", message = "could not start the helper" })
  end
end

-- Silence is not death (a suspend/resume also looks like silence): ask the system before replacing it.
local function checkHelperAlive()
  probing = true
  local accepted = noctalia.processMatches(function(matched)
    probing = false
    if matched then
      silentRounds = silentRounds + 1
      lastBeat = noctalia.nowMs()
      if silentRounds >= HUNG_AFTER_SILENT_ROUNDS then
        silentRounds = 0
        noctalia.log("loq-rgb: helper running but silent, replacing it")
        startHelper()
      end
    else
      silentRounds = 0
      noctalia.log("loq-rgb: helper silent and not running, restarting it")
      startHelper()
    end
  end, "helper/lamparray.py")
  if not accepted then
    probing = false
    lastBeat = noctalia.nowMs()
  end
end

-- ---------------------------------------------------------------- requests from the panel / widget
noctalia.state.watch("kb_req_profile", function(req)
  if type(req) ~= "table" or type(req.profile) ~= "table" then
    return
  end
  local now = noctalia.nowMs()
  local dragging = now - lastReqMs < DRAG_GAP_MS
  lastReqMs = now
  profile = P.sanitize(req.profile)
  markDirty()
  local ms = transitionMs()
  if dragging then
    ms = math.min(ms, 80)
  end
  requestSend(ms)
  publishProfile()
end)

noctalia.state.watch("kb_req_widget", function(req)
  if type(req) ~= "table" then
    return
  end
  if req.name == "set" and (req.arg == "on" or req.arg == "off") then
    profile.on = (req.arg == "on")
  elseif req.name == "bright" and type(req.arg) == "number" then
    profile.br = math.floor(math.max(0, math.min(100, req.arg)) + 0.5)
  else
    return
  end
  markDirty()
  requestSend(transitionMs())
  publishProfile()
end)

-- ---------------------------------------------------------------- periodic work
function update()
  local now = noctalia.nowMs()
  flush(now)

  -- follow the Noctalia palette (wallpaper / theme changes): a slower, gentler fade
  if status.state == "ready" and profile.on and profile.mode == "palette" and now - lastPaletteMs >= 900 then
    lastPaletteMs = now
    if P.paletteSignature(profile) ~= paletteSig then
      requestSend(math.floor(transitionMs() * 2))
    end
  end

  if dirtySince and now - dirtySince >= SAVE_DEBOUNCE_MS then
    dirtySince = nil
    saveProfile()
  end

  -- python3 was missing at start: notice it as soon as it gets installed
  if status.state == "needs_python" and now - lastPythonCheckMs >= PYTHON_RECHECK_MS then
    lastPythonCheckMs = now
    if noctalia.commandExists("python3") then
      startHelper()
    end
  end

  if helperStarted and not probing and now - lastBeat > HEARTBEAT_TIMEOUT_MS then
    checkHelperAlive()
  end

  if pendingMs ~= nil then
    setInterval(BUSY_MS)
  elseif dirtySince then
    setInterval(250)
  else
    setInterval(idleInterval())
  end
end

-- Never lose the last change; on disable, ask the helper to give the keyboard back to its firmware effects.
function onExit(_signal, reason)
  if dirtySince then
    dirtySince = nil
    saveProfile()
  end
  if commandPath and (reason == "disable" or reason == "uninstall") then
    cmdSeq = cmdSeq + 1
    atomicWrite(commandTmp, commandPath, string.format("seq=%.0f\nmode=auto\nbr=100\nms=0\nEND\n", cmdSeq))
  end
end

loadProfile()
publishProfile()
setStatus(status)
startHelper()
setInterval(idleInterval())
