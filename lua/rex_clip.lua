-- rex-clip: paste the Mac clipboard's image into any Rex pane, local or remote, as a file path.
--
--   require("rex_clip").setup()
--   rex.bind("cmd+shift+v", "clip_paste")
--
-- Key actions run in the Mac's own Rex server, so rex.exec can read the Mac clipboard. When the
-- focused pane lives on another Rex server, ctx.server names it and rex.server(ctx.server) calls it.
-- The image travels over that same Rex connection: a hidden terminal on the remote runs `base64 -d`
-- into a file, and the action types the encoded image into it. The remote needs only sh and base64.

local M = {}

M.version = "1.0.0" -- x-release-please-version

M.options = {
  -- Shrink images whose long edge is bigger than this. Agents downscale anyway. false keeps the original.
  max_dimension = 2000,
  -- Where images are staged on the Mac, and where they stay for panes on this server.
  local_dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/*$", "") .. "/rex-clip",
  -- Rex stops a configuration action after 30 seconds.
  timeout = 25,
  -- Bytes of base64 per terminal write.
  chunk_size = 48 * 1024,
  -- Tests only: read this named pasteboard instead of the general one.
  pasteboard = nil,
}

local SHELL = "com.superlogical.terminal.shell"

-- Writes the pasteboard's image next to argv[0] and prints "png", "tiff", "file<TAB>path", or "none".
-- A Finder copy is a file URL plus a TIFF of the file's icon, so the URL is checked first.
local CLIPBOARD_JS = [=[
ObjC.import('AppKit');
function run(argv) {
  const pb = argv[1] ? $.NSPasteboard.pasteboardWithName(argv[1]) : $.NSPasteboard.generalPasteboard;
  const opts = $.NSDictionary.dictionaryWithObjectForKey(true, $.NSPasteboardURLReadingFileURLsOnlyKey);
  const urls = pb.readObjectsForClassesOptions($([$.NSURL]), opts);
  if (urls && !urls.isNil() && urls.count > 0) {
    const path = ObjC.unwrap(urls.objectAtIndex(0).path);
    return /\.(png|jpe?g|gif|webp|heic|tiff?|bmp)$/i.test(path) ? 'file\t' + path : 'none';
  }
  for (const [type, ext] of [[$.NSPasteboardTypePNG, 'png'], [$.NSPasteboardTypeTIFF, 'tiff']]) {
    const data = pb.dataForType(type);
    if (data.isNil()) continue;
    if (!data.writeToFileAtomically(argv[0] + '.' + ext, true)) throw new Error('cannot write ' + argv[0]);
    return ext;
  }
  return 'none';
}
]=]

-- Runs in the hidden remote terminal as: sh -c RECEIVER rex-clip NAME
-- Prints one marker line the action watches for: HAVE (already there), READY (send now), then
-- DONE <sha256> <path>, or FAIL <reason>. It lingers afterwards so the action can read the screen.
local RECEIVER = [=[
umask 077
d="${TMPDIR:-/tmp}"; d="${d%/}/rex-clip-$(id -u)"
linger() { sleep 60; exit "$1"; }
mkdir -p "$d" && [ -O "$d" ] && chmod 700 "$d" || { echo "REXCLIP FAIL cannot use $d"; linger 1; }
find "$d" -type f -mmin +1440 -delete 2>/dev/null
f="$d/$1"
if [ -s "$f" ]; then touch "$f"; echo "REXCLIP HAVE $f"; linger 0; fi
stty -echo 2>/dev/null
t="$f.part.$$"
trap 'rm -f "$t"' EXIT
echo "REXCLIP READY"
if base64 -d > "$t" && mv "$t" "$f"; then
  echo "REXCLIP DONE $( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -d' ' -f1) $f"
else
  echo "REXCLIP FAIL could not decode the upload"
fi
linger 0
]=]

local function fail(message)
  error("rex-clip: " .. message, 0)
end

local function exec(argv, opts)
  local r, err = rex.exec(argv, opts)
  if r == nil then fail(argv[1] .. ": " .. tostring(err)) end
  if not r.ok then fail(argv[1] .. ": " .. (r.stderr ~= "" and r.stderr or ("exit " .. r.code))) end
  return r.stdout
end

local function call(api, method, args)
  local result, err = api.call(method, args)
  if result == nil then fail(method .. ": " .. tostring(err)) end
  return result
end

-- The configuration file has no rex.sleep; scripts do.
local function sleep(seconds)
  if rex.sleep then return rex.sleep(seconds) end
  rex.exec({ "sleep", tostring(seconds) })
end

local function sha256(path)
  return exec({ "shasum", "-a", "256", path }):match("^(%x+)")
end

local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
end

-- Reads the clipboard into base.<ext>. Returns the file and its extension, or nil without an image.
local function read_clipboard(base)
  local argv = { "osascript", "-l", "JavaScript", "-e", CLIPBOARD_JS, base, M.options.pasteboard }
  local kind, path = exec(argv, { timeout = 5 }):gsub("%s+$", ""):match("^(%w+)\t?(.*)$")
  if kind == "png" or kind == "tiff" then return base .. "." .. kind, kind end
  if kind ~= "file" then return nil end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  exec({ "cp", path, base .. "." .. ext })
  return base .. "." .. ext, ext
end

-- Formats agents read as they are. Anything else becomes PNG.
local KEEP = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

local function output_ext(ext)
  return KEEP[ext] and ext or "png"
end

-- Converts and shrinks src as needed with sips, and returns the file to send.
local function prepare(src, base, ext)
  local argv = { "sips" }
  if output_ext(ext) ~= ext then
    for _, a in ipairs({ "-s", "format", "png" }) do
      argv[#argv + 1] = a
    end
  end
  local limit = M.options.max_dimension
  if limit and ext ~= "gif" and ext ~= "webp" then
    local info = exec({ "sips", "-g", "pixelWidth", "-g", "pixelHeight", src })
    local w = tonumber(info:match("pixelWidth: (%d+)")) or 0
    local h = tonumber(info:match("pixelHeight: (%d+)")) or 0
    if math.max(w, h) > limit then
      argv[#argv + 1] = "-Z"
      argv[#argv + 1] = tostring(limit)
    end
  end
  if #argv == 1 then return src end
  local out = base .. "-ready." .. output_ext(ext)
  for _, a in ipairs({ src, "--out", out }) do
    argv[#argv + 1] = a
  end
  exec(argv, { timeout = 10 })
  return out
end

local function method(api, session_id, block_id, name, args)
  return call(api, "block.method", { session_id = session_id, block_id = block_id, method = name, args = args or {} })
end

-- Copies a file to the server behind api, named name in the receiver's directory.
-- make() returns the local file and its sha256, and runs only if the remote lacks name.
-- Returns the remote path and whether it was already there.
function M.upload(api, session_id, name, make)
  local deadline = os.time() + M.options.timeout
  local block_id = call(api, "session.new_block", {
    session_id = session_id,
    flavor = SHELL,
    label = "rex-clip",
    options = {
      shell = "none",
      command = { "sh", "-c", RECEIVER, "rex-clip", name },
      size = { columns = 400, rows = 10 },
    },
  }).block_id

  -- Waits for one of the markers in wanted and returns its name and the rest of its line.
  local function await(wanted, doing)
    while true do
      local text = method(api, session_id, block_id, "format", { trim = true, unwrap = true }).content or ""
      for line in text:gmatch("[^\r\n]+") do
        local marker, rest = line:match("^REXCLIP (%u+) ?(.*)$")
        if marker == "FAIL" then fail(rest) end
        if marker and wanted[marker] then return marker, rest end
      end
      if os.time() >= deadline then fail(string.format("gave up %s after %ds", doing, M.options.timeout)) end
      sleep(0.05)
    end
  end

  local ok, path, had = pcall(function()
    local marker, rest = await({ HAVE = true, READY = true }, "starting the upload")
    if marker == "HAVE" then return rest, true end

    local file, sum = make()
    -- Short lines, since a terminal in canonical mode buffers at most 4096 bytes per line.
    local encoded = exec({ "base64", "-b", "76", "-i", file })
    for i = 1, #encoded, M.options.chunk_size do
      method(api, session_id, block_id, "write", { data = encoded:sub(i, i + M.options.chunk_size - 1) })
      if os.time() >= deadline then
        fail(string.format("gave up after sending %d of %d KiB", math.floor(i / 1024), math.floor(#encoded / 1024)))
      end
    end
    -- Ctrl-D at the start of a line ends base64's input.
    method(api, session_id, block_id, "write", { data = "\n\004" })

    local _, done = await({ DONE = true }, "waiting for the remote file")
    local got, remote = done:match("^(%x+) (.+)$")
    if got ~= sum then fail("checksum mismatch for " .. tostring(remote)) end
    return remote, false
  end)

  api.call("block.close", { session_id = session_id, block_id = block_id })
  if not ok then error(path, 0) end
  return path, had
end

-- The server can only read its own clipboard, so the key must come from the Mac it runs on.
local function check_machine(ctx)
  M.platform = M.platform or exec({ "uname", "-s" }):gsub("%s+$", "")
  if M.platform ~= "Darwin" then fail("load rex-clip in your Mac's Rex config; this server runs " .. M.platform) end
  if ctx.client_id then
    local info = rex.call("client.inspect", { client_id = ctx.client_id })
    local kind = info and info.client and info.client.principal and info.client.principal.kind
    if kind and kind ~= "peer" then fail("the key came from another device, whose clipboard this server can't read") end
  end
end

function M.paste(ctx)
  if not ctx.session_id or not ctx.block_id then fail("no focused pane") end
  check_machine(ctx)
  local api = ctx.server and rex.server(ctx.server) or rex

  exec({ "mkdir", "-p", M.options.local_dir })
  local base = string.format("%s/clip-%d-%04x", M.options.local_dir, os.time(), math.random(0, 0xffff))
  local src, ext = read_clipboard(base)
  if not src then return { pasted = "nothing" } end

  -- Name the image after the clipboard's bytes, so pasting it again reuses the earlier copy.
  -- sips output isn't repeatable, so the name comes from the original.
  local name = sha256(src):sub(1, 16) .. "." .. output_ext(ext)
  local ready
  local function make()
    ready = prepare(src, base, ext)
    return ready, sha256(ready)
  end

  local ok, path, had = pcall(function()
    if ctx.server then return M.upload(api, ctx.session_id, name, make) end
    local target = M.options.local_dir .. "/" .. name
    if exists(target) then return target, true end
    make()
    exec({ "mv", ready, target })
    ready = nil
    return target, false
  end)
  os.remove(src)
  if ready and ready ~= src then os.remove(ready) end
  if not ok then error(path, 0) end

  call(api, "block.event", {
    session_id = ctx.session_id,
    block_id = ctx.block_id,
    event = { type = "paste", payload = { text = path } },
  })
  return { pasted = "image", path = path, server = ctx.server, cached = had }
end

function M.setup(opts)
  for k, v in pairs(opts or {}) do
    -- root is the checkout path that plugin loaders pass along; this module doesn't need it.
    if k ~= "root" then
      if M.options[k] == nil and k ~= "pasteboard" then rex.log("warn", "rex-clip: unknown option " .. tostring(k)) end
      M.options[k] = v
    end
  end
  math.randomseed(os.time())
  rex.action({
    name = "clip_paste",
    title = "Paste Clipboard Image as a File Path",
    description = "Paste the clipboard's image as a file path. For a pane on another server, the image is copied there first.",
    keywords = "clipboard image screenshot paste upload remote agent",
    run = function(ctx)
      return M.paste(ctx)
    end,
  })
  return M
end

return M
