# rex-clip

Paste the Mac clipboard's image into any [Rex](https://www.superlogical.com/rex) pane, local or remote, as a file path.

Copy a screenshot, press Cmd+Shift+V in a pane, and the image's path is pasted there. When the pane runs on another Rex server, such as a Linux box, the image is copied to that machine first. Agents such as Claude Code treat a pasted image path as an attachment, so you can hand a remote agent a screenshot.

## How it works

Key actions run in the Mac's own Rex server, so the action can read the Mac clipboard. For a pane on another server (`ctx.server`), it calls that server over Rex's own connection:

1. It saves the clipboard's image. Screenshots, images copied from apps, and image files copied in Finder all work. Text is left to Rex's own Cmd+V.
2. It names the file after the image's SHA-256, so pasting the same image again reuses the earlier copy.
3. It opens a hidden terminal on the remote that runs `base64 -d` into `${TMPDIR:-/tmp}/rex-clip-<uid>/` (mode 0700), types the encoded image into it, and checks the remote file's SHA-256. Files older than a day are deleted on the next paste.
4. It pastes the path into the pane as a bracketed paste.

The remote needs only `sh` and `base64`. For a pane on the Mac, the image stays in `$TMPDIR/rex-clip/`.

## Install

```sh
git clone https://github.com/sfrieds3/rex-clip ~/code/rex-clip
```

In `~/.config/rex/init.lua`:

```lua
package.path = os.getenv("HOME") .. "/code/rex-clip/lua/?.lua;" .. package.path
require("rex_clip").setup()
rex.bind("cmd+shift+v", "clip_paste")
```

Then run `rex config reload`. Load it in your Mac's Rex config; the action refuses to run on a server that isn't a Mac, since it can only read its own clipboard.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `max_dimension` | `2000` | Shrink images whose long edge is larger, in pixels. `false` keeps the original. |
| `local_dir` | `$TMPDIR/rex-clip` | Where images are staged on the Mac. |
| `timeout` | `25` | Seconds to spend on one paste. Rex stops an action after 30. |
| `chunk_size` | `49152` | Bytes of base64 per terminal write. |

PNG, JPEG, GIF and WebP are kept as they are; other formats are converted to PNG with `sips`.

## Test

From a Rex terminal on the Mac:

```sh
rex do test/e2e.lua               # a local pane, plus the upload path against this server
rex do test/e2e.lua host=LABEL    # a pane on the Rex host LABEL
```

The test uses a private pasteboard, so your clipboard is untouched.

## Limits

- Large images are slow over high-latency links, since each write is one request.
- Only macOS clients; the clipboard is read with `osascript`.
