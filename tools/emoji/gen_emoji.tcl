#!/usr/bin/env tclsh
# Generates lib/emojipicker/emoji/emojitable.tcl. Re-run only to bump the
# Unicode/CLDR data; the generated table is committed and ships as-is.
#
#   inputs : emoji-test.txt   Unicode emoji 16.0 (UTS#51 - groups + names)
#            cldr-en.xml       CLDR en annotations (search keywords)
#            both committed beside this script; refresh from
#              https://unicode.org/Public/emoji/16.0/emoji-test.txt
#              https://github.com/unicode-org/cldr -> common/annotations/en.xml
#   output : a Tcl `set ::emoji::table {...}` block on stdout
#
# One record per emoji:  { <char> <name> <keywords> <category> }
# Skin-tone variants (modifiers U+1F3FB..U+1F3FF) are dropped.
#
# Regenerate (run from tools/emoji/):
#   tclsh gen_emoji.tcl emoji-test.txt cldr-en.xml > ../../lib/emojipicker/emoji/emojitable.tcl

lassign $argv testFile cldrFile
if {$testFile eq "" || $cldrFile eq ""} {
    puts stderr "usage: gen_emoji.tcl emoji-test.txt cldr-en.xml > emojitable.tcl"
    exit 1
}

proc slurp {path} {
    set fh [open $path r]
    fconfigure $fh -encoding utf-8
    set data [read $fh]
    close $fh
    return $data
}

proc unescape {s} {
    string map {&amp; & &lt; < &gt; > &quot; \" &#39; ' &apos; '} $s
}

# Tcl list literals can't contain bare braces; remap them to parens.
proc esc {s} {
    string map [list \\ \\\\ \{ ( \} )] $s
}

# --- CLDR keywords: char -> "kw1 kw2 ..." (source separates with ' | ') ---
array set kw {}
set re {<annotation cp="(.*?)"( type="tts")?>(.*?)</annotation>}
foreach {whole cp tts body} [regexp -all -inline $re [slurp $cldrFile]] {
    if {$tts ne ""} continue   ;# tts form is the long name, not keywords
    set cp [unescape $cp]
    set words [lmap w [split [unescape $body] |] {string trim $w}]
    set kw($cp) [join $words " "]
}

# --- emoji-test.txt: ordered, grouped, fully-qualified, no skin tones ---
set records {}
set group ""
set subgroup ""
foreach line [split [slurp $testFile] \n] {
    if {[string match "# group:*" $line]} {
        set group [string trim [string range $line 8 end]]
        continue
    }
    if {[string match "# subgroup:*" $line]} {
        set subgroup [string trim [string range $line 11 end]]
        continue
    }
    if {$line eq "" || [string match "#*" $line]} continue

    lassign [split $line ";"] codes rest
    if {![regexp {^\s*fully-qualified\s*#\s*(.*)$} $rest -> after]} continue

    # Tk's text engine does no emoji shaping: it draws one glyph per code
    # point, so ZWJ sequences, regional-indicator flags and keycaps come out
    # as 2-5 separate glyphs. Keep only what renders as a single glyph - one
    # emoji code point, optionally followed by the VS16 presentation selector.
    set cps {}
    foreach c $codes { scan $c %x cp; lappend cps $cp }
    set single [expr {[llength $cps] == 1
        || ([llength $cps] == 2 && [lindex $cps 1] == 0xFE0F)}]
    if {!$single} continue

    set char [lindex $after 0]                     ;# rendered glyph sits first
    regexp {^\S+\s+E[\d.]+\s+(.*)$} $after -> name  ;# strip "<glyph> E1.0 "
    set keywords [string trim "[expr {[info exists kw($char)] ? $kw($char) : {}}] [string map {- { }} $subgroup]"]
    lappend records [list $char $name $keywords $group]
}

puts "# [llength $records] emoji - GENERATED from Unicode emoji 16.0 + CLDR en. Do not edit by hand."
puts "# regenerate: cd tools/emoji && tclsh gen_emoji.tcl emoji-test.txt cldr-en.xml > ../../lib/emojipicker/emoji/emojitable.tcl"
puts "namespace eval ::emoji {}"
puts "set ::emoji::table \{"
foreach rec $records {
    lassign $rec char name keywords group
    puts "    {[esc $char] {[esc $name]} {[esc $keywords]} {[esc $group]}}"
}
puts "\}"
puts stderr "[llength $records] records"
