# Tacky

A desktop XMPP chat client built with Tcl/Tk. Pre-alpha.

## Screenshots

![Main window](doc/screenshots/main.png)
![Call](doc/screenshots/call.png)


## Core ideas
- Portable backend aiming for a very high level api: libtacky doesn't just help you form and send stanzas, it aims to take care of all the business logic, local caching and settings storage, now also calls, etc. The gui should stay as simple as possible, only concerning itself with displaying stuff. All methods and events are routed through a bridge ready to transparently be called either in the same thread or a different process, or even a different language via JSON.
- Lightweight, tries to be easily distributable - self-contained statically-linked executable with all dependencies including calls at ~15mb
- Advanced MAM handling: it's aware that the message history it has is not full. Lazy loads from server, aims to support server-side search.

## Key features support
- Modern calls compatible with Conversations and Dino
- OMEMO (only direct messages)
- Attachments

## Running

Download the executable from the releases page for Windows or Linux, click and run.
You can have the backend run in a separate thread by calling `tacky --backend threaded` - this will use slightly more RAM, but won't affect features.

## Building

### Linux
`make`

will download and build all the dependencies for you, and package them all into a single executable with the client: `./dist/tacky`.

`make linux`

will do the same in a debian docker 

### Windows
`make win`

on Linux will download and build all the dependencies for you, and package them all into a single cross-compiled executable with the client: `./dist/tacky.exe`.

### Run without building
If you have all the dependencies installed, call `wish ./bin/tacky.tcl`. You can get a `wish` with all dependencies easily: run `make wish` - result in `build/linux/wish`.


### Flatpak

Setup:

```sh
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.flatpak.Builder
```

Build, install and run (the runtime/SDK are pulled in on first build):

```sh
cd flatpak
flatpak run org.flatpak.Builder --user --install --install-deps-from=flathub --force-clean build-dir io.github.pounceandmiss.Tacky.yml
flatpak run io.github.pounceandmiss.Tacky
```

## Tests

```
make test
```

## Architecture

```
GUI (gui/)  <->  tacky bridge (lib/libtacky/)  <->  Backend (lib/taco/)  ->  XMPP
```

The bridge supports three backend transport modes, all transparent to the GUI:
`--backend MODE    Backend mode: direct (default), thread, process`