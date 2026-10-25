-- End-to-end test. Run from a Rex terminal on the Mac:
--
--   rex do test/e2e.lua               # local pane, plus the upload path against this server
--   rex do test/e2e.lua host=LABEL    # a pane on another Rex server
--
-- It uses a private pasteboard, so your clipboard is untouched, and pastes into a hidden terminal.

local root = debug.getinfo(1, "S").source:match("^@?(.*)/test/[^/]+$") or "."
package.path = root .. "/lua/?.lua;" .. package.path
local M = require("rex_clip")
M.options.pasteboard = "rex-clip-test"

local SEED_JS = [=[
ObjC.import('AppKit');
function run([name, kind, value]) {
  const pb = $.NSPasteboard.pasteboardWithName(name);
  pb.clearContents;
  if (kind === 'png') pb.setDataForType($.NSData.dataWithContentsOfFile(value), $.NSPasteboardTypePNG);
  else pb.setStringForType(value, $.NSPasteboardTypeString);
  return 'ok';
}
]=]

local failed = false
local function check(cond, message)
  if not cond then
    rex.log("error", "FAIL: " .. message)
    failed = true
  end
  return cond
end

local function seed(kind, value)
  local r = rex.exec({ "osascript", "-l", "JavaScript", "-e", SEED_JS, M.options.pasteboard, kind, value })
  assert(r and r.ok, "could not seed the pasteboard: " .. (r and r.stderr or "?"))
end

local png = (os.getenv("TMPDIR") or "/tmp"):gsub("/*$", "") .. "/rex-clip-test.png"
rex.exec({
  "sips",
  "-s",
  "format",
  "png",
  "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns",
  "--out",
  png,
})

local host = rex.args.host
local api, session_id = rex, rex.session_id
if host then
  api = rex.server(host)
  session_id = assert(api.call("session.list", {}).sessions[1], "no sessions on " .. host).session_id
end

-- A hidden terminal that turns on bracketed paste and shows what it receives.
local target = assert(api.call("session.new_block", {
  session_id = session_id,
  flavor = "com.superlogical.terminal.shell",
  label = "rex-clip-test",
  options = { shell = "none", command = { "sh", "-c", [[printf '\033[?2004h'; cat]] } },
})).block_id
rex.sleep(0.5)

local function screen()
  local s = api.call("block.method", {
    session_id = session_id,
    block_id = target,
    method = "format",
    args = { trim = true, unwrap = true },
  })
  return s and s.content or ""
end

local function paste(label)
  local ok, result = pcall(M.paste, { server = host, session_id = session_id, block_id = target })
  if not check(ok, label .. ": " .. tostring(result)) then return nil end
  rex.sleep(0.3)
  if result.path then
    check(screen():find("^[[200~" .. result.path .. "^[[201~", 1, true), label .. ": pane shows " .. screen())
  end
  rex.log(
    string.format(
      "%s: %s %s%s",
      label,
      result.pasted,
      tostring(result.path),
      result.cached and " (already there)" or ""
    )
  )
  return result
end

seed("png", png)
local first = paste("first paste")
local again = paste("same image again")
check(first and first.pasted == "image", "first paste wasn't an image")
check(again and again.cached and again.path == first.path, "the same image was copied again")

seed("text", "echo nope")
local text = paste("text on the clipboard")
check(text and text.pasted == "nothing", "text was pasted")

-- Without a host, still exercise the remote transport against this server.
if not host then
  local sum = rex.exec({ "shasum", "-a", "256", png }).stdout:match("^(%x+)")
  local name = "e2e-" .. os.time() .. ".png"
  local ok, path, had = pcall(M.upload, rex, session_id, name, function()
    return png, sum
  end)
  if check(ok, "upload: " .. tostring(path)) then
    check(not had, "upload: fresh name reported as already there")
    local copied = rex.exec({ "shasum", "-a", "256", path }).stdout:match("^(%x+)")
    check(copied == sum, "upload: copy differs from the original")
    rex.log("upload: " .. path)
    local ok2, path2, had2 = pcall(M.upload, rex, session_id, name, function()
      error("should not resend")
    end)
    check(ok2 and had2 and path2 == path, "upload again: " .. tostring(path2))
    os.remove(path)
  end
end

if first and not host then os.remove(first.path) end
api.call("block.close", { session_id = session_id, block_id = target })
os.remove(png)
rex.log(failed and "e2e: FAILED" or "e2e: passed")
rex.stop(failed and 1 or 0)
