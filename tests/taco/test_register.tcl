# Sample registration query with XEP-0004 form, media element, and inline BOB data
set ::sample_reg_query [xmppreader string -zap yes {<query xmlns='jabber:iq:register'>
 <x xmlns='jabber:x:data'
    type='form'>
  <instructions>Choose a username and password to register with this server
  </instructions>
  <field var='FORM_TYPE'
         type='hidden'>
   <value>jabber:iq:register</value>
  </field>
  <field var='username'
         type='text-single'
         label='User'>
   <required/>
  </field>
  <field var='password'
         type='text-private'
         label='Password'>
   <required/>
  </field>
  <field var='captcha-fallback-text'
         type='fixed'>
   <value>If you don't see the CAPTCHA image here, visit the web page.
   </value>
  </field>
  <field var='captcha-fallback-url'
         type='text-single'
         label='CAPTCHA web page'>
   <value>https://draugr.de:5281/captcha/11928599258038789393/image
   </value>
  </field>
  <field var='from'
         type='hidden'
         label="Attribute 'to' of stanza that triggered challenge">
   <value>draugr.de</value>
  </field>
  <field var='challenge'
         type='hidden'
         label='Challenge ID'>
   <required/>
   <value>11928599258038789393</value>
  </field>
  <field var='sid'
         type='hidden'
         label='Stanza ID'>
   <value>reg-1</value>
  </field>
  <field var='ocr'
         type='text-single'
         label='Enter the text you see'>
   <media xmlns='urn:xmpp:media-element'>
    <uri type='image/png'>cid:sha1+03a94f4e6d079dceb85fe21981dfb5563d2e051a@bob.xmpp.org
    </uri>
   </media>
   <required/>
  </field>
 </x>
 <data xmlns='urn:xmpp:bob'
       type='image/png'
       max-age='0'
       cid='sha1+03a94f4e6d079dceb85fe21981dfb5563d2e051a@bob.xmpp.org'>iVBORw0KGgoAAAANSUhEUgAAAABAAAAAIAAAACCAZ6AAAAJ0lEQVR42mJ0TzABIAwQBAB9iqYlAAAAAElFTkSuQmCC
 </data>
 <instructions>You need a client that supports x:data and CAPTCHA to register
 </instructions>
</query>}]

snit::type mock_bareconn {
    variable written
    variable writtenRaw

    option -onready -default ""
    option -ondisconnect -default ""
    option -onstanza -default ""
    option -header-command -default ""
    option -footer-command -default ""
    option -starttls -default true
    option -ondebugstanza -default ""

    constructor {args} {
        $self configurelist $args
        set written {}
        set writtenRaw {}
        set ::_mock_conn $self
    }

    method connect {host port} {
        if {$options(-onready) ne ""} {
            {*}$options(-onready)
        }
    }

    method writeStanza {stanza} {
        lappend written $stanza
    }

    method write {data} {
        lappend writtenRaw $data
    }

    method close {} {}

    # -- test helpers --

    method inject {stanza} {
        if {$options(-onstanza) ne ""} {
            {*}$options(-onstanza) $stanza
        }
    }

    method fire_disconnect {msg} {
        if {$options(-ondisconnect) ne ""} {
            {*}$options(-ondisconnect) $msg
        }
    }

    method get_written {} {
        return $written
    }

    method get_written_raw {} {
        return $writtenRaw
    }

    method clear {} {
        set written {}
        set writtenRaw {}
    }
}

proc make_reg_features {} {
    j features {
        j register -ns http://jabber.org/features/iq-register
    }
}

proc make_noreg_features {} {
    j features {
        j mechanisms -ns urn:ietf:params:xml:ns:xmpp-sasl {
            j mechanism .body PLAIN
        }
    }
}

proc make_reg_result {} {
    j iq -type result -id reg-1 {
        j /as-is $::sample_reg_query
    }
}

proc make_reg_success {} {
    j iq -type result -id reg-2
}

proc make_reg_error {txt} {
    j iq -type error -id reg-2 {
        j error -type cancel {
            j not-allowed -ns urn:ietf:params:xml:ns:xmpp-stanzas
            j text -ns urn:ietf:params:xml:ns:xmpp-stanzas .body $txt
        }
    }
}

proc make_reg_error_bare {} {
    j iq -type error -id reg-1 {
        j error -type cancel {
            j not-allowed -ns urn:ietf:params:xml:ns:xmpp-stanzas
        }
    }
}

proc drive_to_form {} {
    $::_mock_conn inject [make_reg_features]
    $::_mock_conn inject [make_reg_result]
}

set common {
    -setup {
        set ::_events {}
        tacky_type create tacky
        rename bareconn _real_bareconn
        rename mock_bareconn bareconn
        tacky listen register <Form>       {apply {{ev} {lappend ::_events [list <Form> {*}$ev]}}}
        tacky listen register <MediaReady> {apply {{ev} {lappend ::_events [list <MediaReady> {*}$ev]}}}
        tacky listen register <Success>    {apply {{ev} {lappend ::_events [list <Success> {*}$ev]}}}
        tacky listen register <Error>      {apply {{ev} {lappend ::_events [list <Error> {*}$ev]}}}
    }
    -cleanup {
        tacky destroy
        rename bareconn mock_bareconn
        rename _real_bareconn bareconn
    }
}

# -- Connection & features -------------------------------------------------

test reg-connect-writes-header {connect writes stream header} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        set raw [$::_mock_conn get_written_raw]
        expr {[llength $raw] >= 1 && [string match "*<stream:stream*" [lindex $raw 0]]}
    } -result 1

test reg-features-sends-query {features stanza triggers registration query} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        $::_mock_conn clear
        $::_mock_conn inject [make_reg_features]
        set written [$::_mock_conn get_written]
        set iq [lindex $written 0]
        list [xsearch $iq -get @type] [xsearch $iq query -get ns]
    } -result {get jabber:iq:register}

test reg-no-register-fires-error {missing register feature fires <Error>} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        $::_mock_conn inject [make_noreg_features]
        set ev [lindex $::_events 0]
        list [lindex $ev 0] [dict get [lrange $ev 1 end] -message]
    } -result {<Error> {Server does not support in-band registration}}

# -- Form parsing ----------------------------------------------------------

test reg-form-event {drive_to_form fires <Form> event} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        set ev [lindex $::_events end]
        list [lindex $ev 0] [dict get [lrange $ev 1 end] -token]
    } -result {<Form> {}}

test reg-form-fields {form returns expected field list} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        array set form [tacky register form]
        set form(fields)
    } -result {FORM_TYPE username password captcha-fallback-text captcha-fallback-url from challenge sid ocr}

test reg-form-instructions {form dump contains instructions} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        array set form [tacky register form]
        expr {[info exists form(instructions)] && $form(instructions) ne ""}
    } -result 1

# -- Media -----------------------------------------------------------------

test reg-media-ready-event {drive_to_form fires <MediaReady> for ocr field} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        set found 0
        foreach ev $::_events {
            if {[lindex $ev 0] eq "<MediaReady>"} {
                set found [dict get [lrange $ev 1 end] -var]
                break
            }
        }
        set found
    } -result ocr

test reg-media-returns-data {media returns non-empty base64 data} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        set data [tacky register media -var ocr]
        expr {$data ne ""}
    } -result 1

# -- Submit ----------------------------------------------------------------

test reg-submit-sends-iq {submit sends IQ set with registration query} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        $::_mock_conn clear
        tacky register submit -values {username alice password secret}
        set written [$::_mock_conn get_written]
        set iq [lindex $written 0]
        list [xsearch $iq -get @type] [xsearch $iq query -get ns]
    } -result {set jabber:iq:register}

test reg-submit-success {IQ result after submit fires <Success>} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        tacky register submit -values {username alice password secret}
        set ::_events {}
        $::_mock_conn inject [make_reg_success]
        set ev [lindex $::_events 0]
        lindex $ev 0
    } -result {<Success>}

test reg-submit-error-text {IQ error after submit fires <Error> with message} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        drive_to_form
        tacky register submit -values {username alice password secret}
        set ::_events {}
        $::_mock_conn inject [make_reg_error "Username taken"]
        set ev [lindex $::_events 0]
        list [lindex $ev 0] [dict get [lrange $ev 1 end] -message]
    } -result {<Error> {Username taken}}

# -- Error paths -----------------------------------------------------------

test reg-iq-error-bare {IQ error without text uses child tag name} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        $::_mock_conn inject [make_reg_features]
        set ::_events {}
        $::_mock_conn inject [make_reg_error_bare]
        set ev [lindex $::_events 0]
        list [lindex $ev 0] [dict get [lrange $ev 1 end] -message]
    } -result {<Error> not-allowed}

test reg-disconnect {disconnect fires <Error> with message} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        $::_mock_conn fire_disconnect "conn lost"
        set ev [lindex $::_events 0]
        list [lindex $ev 0] [dict get [lrange $ev 1 end] -message]
    } -result {<Error> {conn lost}}

test reg-form-not-ready {form before connect errors} \
    {*}$common \
    -body {
        tacky register form
    } -returnCodes error -match glob -result {No registration session*}

# -- Cancel ----------------------------------------------------------------

test reg-cancel {cancel destroys session so form errors} \
    {*}$common \
    -body {
        tacky register connect -host example.com
        tacky register cancel
        tacky register form
    } -returnCodes error -match glob -result {No registration session*}
