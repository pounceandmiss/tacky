# Unit tests for ::tacky::forms (XEP-0004 data forms)
package require tcltest
namespace import ::tcltest::*
package require libtacky
package require taco

set ::form_x [xmppreader string -zap yes {<x xmlns='jabber:x:data' type='form'>
 <title>Room config</title>
 <instructions>Configure</instructions>
 <field var='FORM_TYPE' type='hidden'><value>urn:example</value></field>
 <field var='name' type='text-single' label='Name'><required/><value>lobby</value></field>
 <field var='desc' type='fixed'><value>read only</value></field>
 <field var='langs' type='list-multi' label='Languages'>
  <value>en</value>
  <value>de</value>
  <option label='English'><value>en</value></option>
  <option label='German'><value>de</value></option>
 </field>
 <field var='ocr' type='text-single' label='Captcha'>
  <media xmlns='urn:xmpp:media-element'><uri type='image/png'>cid:abc@bob.xmpp.org</uri></media>
 </field>
</x>}]

proc form_vars {form} {
    lmap f [dict get $form fields] {dict get $f var}
}
proc form_field {form idx} {
    lindex [dict get $form fields] $idx
}

# -- parse -------------------------------------------------------------------

test form-parse-type {parse reads the form type} -body {
    dict get [::tacky::forms::parse $::form_x] type
} -result form

test form-parse-instructions {parse reads instructions} -body {
    string trim [dict get [::tacky::forms::parse $::form_x] instructions]
} -result Configure

test form-parse-field-order {fields keep document order, keyed by var} -body {
    form_vars [::tacky::forms::parse $::form_x]
} -result {FORM_TYPE name desc langs ocr}

test form-parse-single-value-is-list {a single value is a 1-element list} -body {
    dict get [form_field [::tacky::forms::parse $::form_x] 1] value
} -result lobby

test form-parse-multi-value {multi collects every <value> child} -body {
    dict get [form_field [::tacky::forms::parse $::form_x] 3] value
} -result {en de}

test form-parse-required {required flag is parsed} -body {
    dict get [form_field [::tacky::forms::parse $::form_x] 1] required
} -result 1

test form-parse-label-fallback {label falls back to var when absent} -body {
    dict get [form_field [::tacky::forms::parse $::form_x] 2] label
} -result desc

test form-parse-options {options are {label value} dicts} -body {
    dict get [form_field [::tacky::forms::parse $::form_x] 3] options
} -result {{label English value en} {label German value de}}

test form-parse-media {media is a {cid type} dict} -body {
    dict get [form_field [::tacky::forms::parse $::form_x] 4] media
} -result {cid abc@bob.xmpp.org type image/png}

# -- serialize ---------------------------------------------------------------

test form-serialize-submit-skips-fixed {serialize marks submit, drops fixed, keeps hidden} -body {
    set node [::tacky::forms::serialize [::tacky::forms::parse $::form_x]]
    list [xsearch $node -get @type] \
         [lmap f [xsearch $node field] {xsearch $f -get @var}]
} -result {submit {FORM_TYPE name langs ocr}}

test form-serialize-multi-values {serialize emits one <value> per element} -body {
    set node [::tacky::forms::serialize [::tacky::forms::parse $::form_x]]
    set out {}
    xsearch $node field -script fn {
        if {[xsearch $fn -get @var] eq "langs"} {
            set out [lmap v [xsearch $fn value] {string trim [xsearch $v -get body]}]
        }
    }
    set out
} -result {en de}

test form-roundtrip-multi {parse->serialize->parse preserves multi values} -body {
    set node [::tacky::forms::serialize [::tacky::forms::parse $::form_x]]
    dict get [form_field [::tacky::forms::parse $node] 2] value
} -result {en de}

test form-serialize-honors-type {serialize honors an explicit type} -body {
    set form [::tacky::forms::parse $::form_x]
    dict set form type cancel
    xsearch [::tacky::forms::serialize $form] -get @type
} -result cancel

# -- apply -------------------------------------------------------------------

test form-apply-single-keeps-spaces {a single value with spaces stays one element} -body {
    set form [::tacky::forms::apply [::tacky::forms::parse $::form_x] {name {new name}}]
    list [dict get $form type] [dict get [form_field $form 1] value]
} -result {submit {{new name}}}

test form-apply-multi-splits {a multi value is treated as a list} -body {
    set form [::tacky::forms::apply [::tacky::forms::parse $::form_x] {langs {en fr}}]
    dict get [form_field $form 3] value
} -result {en fr}

# -- restore -----------------------------------------------------------------

test form-restore-preserves-empty {restore fills a new empty field from the old form} -body {
    set old [::tacky::forms::apply [::tacky::forms::parse $::form_x] {ocr typed}]
    set new [::tacky::forms::parse $::form_x]
    dict get [form_field [::tacky::forms::restore $old $new] 4] value
} -result typed

test form-restore-no-clobber {restore never overwrites a value already in the new form} -body {
    set old [::tacky::forms::apply [::tacky::forms::parse $::form_x] {name old}]
    set new [::tacky::forms::apply [::tacky::forms::parse $::form_x] {name new}]
    dict get [form_field [::tacky::forms::restore $old $new] 1] value
} -result new

# -- mediaMap ----------------------------------------------------------------

test form-mediamap {mediaMap returns a cid->var lookup} -body {
    ::tacky::forms::mediaMap [::tacky::forms::parse $::form_x]
} -result {abc@bob.xmpp.org ocr}
