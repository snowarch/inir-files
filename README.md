# iNiR Files

The file manager of the iNiR desktop. The interface is QML on qs-rs, the iNiR runtime. A small Rust process,
`inir-files-core`, does the file work off the interface thread: listing, thumbnails, copies, trash, devices and search.

## What it does

- Grid, list and columns views, tabs, a split view and windows that share one process.
- A side panel and a full-window quick look (Space) that show what a file holds: pictures at full size, films and
  songs that play, every page of a PDF, Markdown as a page, code in its language's colours, fonts, archive contents.
- Facts in place: picture size and camera data, film and sound streams with HDR10, HLG and Dolby Vision, PDF pages
  and author, folder sizes, checksums.
- Copy, move, link, duplicate, trash and restore as jobs with progress, conflict choices and undo.
- Rename one or many (find and replace, numbers, case), new files from templates, compress (zip, tar.zst, 7z, with a
  password) and extract.
- Places, bookmarks, recent files, the trash and every disk, with mount, unmount and eject.
- Search by name, or inside files with ripgrep.
- Open with any app, set the default app of a kind, a terminal here, paste an image or text as a file.
- Colours, accent and fonts follow iNiR, in light and dark.

## Run it

```sh
cargo build --release --manifest-path core/Cargo.toml
bin/inir-files [PATH]...
```

`bin/inir-files` finds the runtime at `~/.local/share/inir/runtime/current/bin/qs` or as `qs` on the `PATH`
(`INIR_FILES_QS` names another). A running instance opens each path in a new window.
`data/inir-files.desktop` makes it the app for folders.

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
