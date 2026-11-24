# iNiR Files

The file manager of the iNiR desktop. The interface is QML on qs-rs, the iNiR runtime. A small Rust process,
`inir-files-core`, does the file work off the interface thread: listing, thumbnails, copies, trash, devices and search.

## What it does

- Start page (greeting over the wallpaper, places, bookmarks, recent files and drives), plus grid, list, columns and
  gallery views, tabs, a split view and windows that share one process.
- A side panel and a full-window quick look (Space) that show what a file holds: pictures at full size, films and
  songs that play, every page of a PDF, Markdown as a page, code in its language's colours, fonts, archive contents.
- Facts in place: picture size and camera data, film and sound streams with HDR10, HLG and Dolby Vision, PDF pages
  and author, folder sizes, checksums.
- Copy, move, link, duplicate, trash and restore as jobs with progress, conflict choices and undo/redo.
- Rename one or many (find and replace, numbers, case), select by name, new files from templates, compress (zip,
  tar.zst, 7z, with a password) and extract.
- Places, bookmarks, recent files, the trash, every disk (mount, unmount, eject) and remote servers over GVfs (SFTP,
  SMB, FTP, WebDAV, NFS).
- Serves `org.freedesktop.FileManager1` on D-Bus so browsers and other apps open "Show in folder" directly in it.
- Search by name, or inside files with ripgrep.
- Open with any app, set the default app of a kind, a terminal here, paste an image or text as a file.
- Set a picture or a film as the iNiR wallpaper.
- Colours, accent and fonts follow iNiR, in light and dark.

## Build and install

Build and run from a checkout:

```sh
make build
bin/inir-files [PATH]...
```

Install into `~/.local` (no root required) or `/usr/local`:

```sh
make install PREFIX="$HOME/.local"
xdg-mime default inir-files.desktop inode/directory   # optional: folders open in it
```

`make install` places the launcher in `$(PREFIX)/bin/inir-files`, the Rust engine in `$(PREFIX)/libexec/inir-files-core`,
the QML files in `$(PREFIX)/share/inir-files/`, the desktop entry in `$(PREFIX)/share/applications/`, and the D-Bus
activation service in `$(PREFIX)/share/dbus-1/services/inir-files.FileManager1.service` with `Exec=` pointing at the
installed launcher. Standard `DESTDIR` is supported for packaging.

`make dist` builds a self-contained release tarball and SHA-256 checksum under `dist/`.

`bin/inir-files` requires `qs-rs` (the iNiR runtime) at `~/.local/share/inir/runtime/current/bin/qs` or on `PATH`
(`INIR_FILES_QS` names another). A running instance opens each path in a new window.

## What it uses when present

| Tool | For |
|---|---|
| `ffmpeg`, `ffprobe` or `ffmpegthumbnailer` | film thumbnails and stream facts |
| `pdftoppm`, `pdfinfo` (poppler) | PDF pages and facts |
| `magick` (ImageMagick) | pictures Qt cannot read: AVIF, HEIC, JPEG XL, RAW |
| `rg` (ripgrep) | search inside files |
| `7z`, `bsdtar` | archives |
| `udisksctl`, `gio` | disks and mounts |
| `wl-copy`, `wl-paste` | the clipboard |

## License

GPL-3.0-or-later. See `LICENSE`.
