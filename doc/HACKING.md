# Hacking on Tacky

The external API is in [DOC.md](DOC.md). This file covers the internals.

## Contents

- [Layout](#layout)
- [Building and running from a checkout](#building-and-running-from-a-checkout)
- [Tests](#tests)
- [Writing XMPP code](#writing-xmpp-code)
  - [Nodes](#nodes)
  - [Building stanzas with `j`](#building-stanzas-with-j)
  - [Reading stanzas with `xsearch`](#reading-stanzas-with-xsearch)
- [Backend modules](#backend-modules)

## Layout

```
GUI (gui/)  <->  bridge (lib/libtacky)  <->  Backend (lib/taco/)  ->  XMPP
```

`taco` is the backend doing the actual work, whereas the `tacky` command in Tcl, or its equivalent functions in C, just provide a bridge. `taco` never surfaces in the API, nor should the GUI ever call it directly.

The native Tcl bridge supports three backend transports, all transparent to the GUI: `tacky_type` (in-process, default), `tacky_threaded_type`, `tacky_process_type`.

## Building and running from a checkout

`make` builds self-contained binaries for distribution, see [README](../README.md#building).

For development you want an interpreter instead. Rather than installing each dependency system-wide, you can get a self-contained one with all deps baked in:

```sh
make tools      # build/linux/tclsh and build/linux/wish, with every dep baked in
./build/linux/wish bin/tacky.tcl # start the gui
```

## Tests

```sh
make test                 # or: ./build/linux/tclsh test_all.tcl
make test-gui             # or: ./build/linux/wish test_gui.tcl, windows will pop up on screen
make test-gui-headless    # same suite under xvfb-run, identical results
```

To narrow a run:

```sh
./build/linux/wish test_gui.tcl -match chatview-*
```

`test_all.tcl` honours a few environment variables: `NO_THREADED=1` and
`NO_PROCESS=1` skip the alternate transports. Integration tests run from the same file
when started via `tests/servers/with_prosody.sh` and friends.

For the sake of keeping complexity bearable and at the cost of flakiness, most GUI tests are timing-sensitive, so a failure is worth rerunning, or running on its own with `-match`, before treating it as real.

## Writing XMPP code

### Nodes

An xml node is represented as a Tcl dict:

```tcl
{tag message body {} tail {} children {...} ns jabber:client attrs {to a@b type chat}}
```

This is used instead of tdom's dom to have the advantages of Tcl values over Tcl handles used in tdom: it's garbage collected, easy to pass around, zero memory headache.

### Building stanzas with `j`

Similar to tdom's `appendFromScript`:

`j tag ?-opt value ...? ?script?`.
The outermost call returns a node dict, nested calls magically append to the tree being built, so the Tcl code looks structurally close to the xml it produces, with the ability to use arbitrary Tcl commands inside - loops, conditions, etc.

```tcl
set cond yes
set iq [j iq -type set -id $id {
    j pubsub -ns http://jabber.org/protocol/pubsub {
        j publish -node urn:xmpp:bookmarks:1 {
            # The script runs in the topmost caller's frame,
            # so local variables are visible.
            if {$cond} {
                # this element only appears if $cond
                j item -id $jid
            }
        }
    }
}]
```

Option forms:

| Form                            | Effect                                                |
| ------------------------------- | ----------------------------------------------------- |
| `-ns URI`                       | sets the node's namespace                             |
| `-body text`                    | sets the element's text                               |
| `-name value`                   | sets attribute `name`                                 |
| `@name value`                   | same, for attribute names that collide with the above |
| `#as-is $node`                  | splices an already-built node in as a child           |

`-ns` and `-body` name node fields, every other `-name` is an attribute, and
`@name` is always an attribute. A key with neither prefix is an error rather
than a silent no-op.

The trailing script is optional.

The builder's accumulator lives in the calling frame, which means a `j` tree
cannot span a proc boundary. A helper proc gets its own frame, so it returns a
finished node and the caller splices it in with `j #as-is`, the way
`jinglesdp.tcl` composes larger stanzas.

`jab::write $node` serializes. `jab::write -pretty $node` indents.

### Reading stanzas with `xsearch`

`xsearch $node ?filter ...? ?-get fields? ?-gather fields? ?-script var body?` is quasi-xpath. Filters are applied left to right, each one
descending a level or narrowing the current set.

| Filter                               | Matches                            |
| ------------------------------------ | ---------------------------------- |
| `tagname`                            | children with that tag             |
| `*`                                  | all children                       |
| `3`                                  | the child at that index            |
| `@attr`                              | nodes carrying that attribute      |
| `@attr value`                        | nodes whose attribute equals value |
| `-body`/`-ns`/`-tag`/`-tail` `value` | nodes whose field equals value     |

Terminators:

- `-get fields` returns the fields of the first match. One field returns a bare
  value, several return a list. `node` yields the whole dict. A field may be
  spelled with or without the dash it carries as a filter, so `-get -body` and
  `-get body` are the same.
- `-gather fields` returns one entry per match.
- `-script varName body` runs the body per match with the node in `varName`.
- With none of them, the matching nodes are returned.

Examples:

```tcl
set type_ [xsearch $stanza -get @type]
set errText [xsearch $stanza error text -get body]
set hash [xsearch $stanza x -ns vcard-temp:x:update photo -get body]
set items [xsearch $stanza pubsub items item]
```

A miss returns empty rather than erroring, so a wrong path looks like an absent
element. When a lookup mysteriously yields nothing, check the namespace filter
first.

## Backend modules

Each subsystem in `lib/taco/modules/` is a `snit::type` named `taco_<thing>`,
taking `-client` and registering its handlers in the constructor. `taco.tcl`
sources every file in the directory at load time.

Most public methods should be declared with the `tackymethod` macro rather than
`method`. It gives every method the same completion contract: a synchronous
result when called plainly, a `-command` callback when one is passed, and errors
routed to `-onerror` or to an `error <MethodError>` event instead of escaping
into a background handler.
