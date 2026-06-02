# Performs xmpp starttls with no dependencies (other than the function xesc to simply escape the hostname),
# no parsing, just looks for pattern

# Example: xmpp_starttls [socket -async draugr.de] draugr.de cmdPrefix
# And then it'll call {*}$cmdPrefix ok|error

# To feed it a certificate for testing set the SPOOF_SSL_CERT
# environment variable to the path to that certificate

proc xmpp_starttls {chan host cb} {
    puts -nonewline $chan "<?xml version='1.0'?><stream:stream to='[xesc $host]' xml:lang='en' version='1.0' xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
    if {[catch {flush $chan}]} {
        {*}$cb error $::errorCode
        return
    }
    fileevent $chan readable \
        [list _xmpp_starttls_readable_cb $chan $host $cb]
}

proc _xmpp_starttls_readable_cb {chan host cb} {
    if {[set chunk [read $chan]] eq ""} {
        fileevent $chan readable {}
        unset -nocomplain ::_xmpp_starttls_data($chan)
        {*}$cb error
        return
    }

    append ::_xmpp_starttls_data($chan) $chunk
    if {[regexp {<proceed.*>} $::_xmpp_starttls_data($chan)]} {
        unset ::_xmpp_starttls_data($chan)
        fileevent $chan readable {}

        # <for automated testing>
        set extraopts {}
        if {[info exists ::env(SPOOF_SSL_CERT)]} {
            lappend extraopts -cafile $::env(SPOOF_SSL_CERT)
        }
        # </for automated testing>
        if {[catch {mtls::import $chan -servername $host {*}$extraopts} tlschan]} {
            {*}$cb error $tlschan
            return
        }
        _xmpp_starttls_handshake $tlschan $cb
    }
}

# mtls::handshake returns 1 (done), 0 (in progress), or throws the mbedTLS
# failure reason, which we hand to $cb so callers can show it.
proc _xmpp_starttls_handshake {tlschan cb} {
    if {[catch {mtls::handshake $tlschan} res]} {
        fileevent $tlschan readable {}
        {*}$cb error $res
        return
    }
    if {$res} {
        fileevent $tlschan readable {}
        {*}$cb ok $tlschan
    } else {
        fileevent $tlschan readable \
            [list _xmpp_starttls_handshake $tlschan $cb]
    }
}
