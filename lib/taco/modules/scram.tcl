# SCRAM client (RFC 5802, RFC 7677) for SCRAM-SHA-1 and SCRAM-SHA-256, with
# optional tls-exporter channel binding (RFC 9266). Builds and checks the
# messages; conn drives the exchange. PBKDF2 comes from mtls, so SCRAM is
# only available where mtls is.
#
#   scram::available
#   scram::digest mech                  -> sha1 | sha256
#   scram::client_first user nonce flag -> {gs2header bare}
#   scram::client_final digest password gs2header cbdata bare serverFirst
#                                       -> {message serverSignature}
#   scram::check_server_final serverSignature serverFinal
#
# flag is the gs2 channel binding flag: n, y or p=tls-exporter. Strings in
# and out are Tcl strings; their UTF-8 bytes go on the wire. No SASLprep.

package require sha1
package require sha256

namespace eval scram {
    # Cap on the server's iteration count (PBKDF2 rounds), so a hostile
    # server cannot stall us.
    variable MAX_ITERATIONS 1000000
}

proc scram::available {} {
    expr {![catch {package require mtls}]
        && [llength [info commands ::mtls::pbkdf2]]}
}

proc scram::digest {mech} {
    switch -glob -- $mech {
        SCRAM-SHA-1 - SCRAM-SHA-1-PLUS { return sha1 }
        SCRAM-SHA-256 - SCRAM-SHA-256-PLUS { return sha256 }
    }
    error "not a supported SCRAM mechanism: $mech"
}

proc scram::nonce {} {
    binary encode base64 [::mtls::randombytes 18]
}

proc scram::client_first {user nonce flag} {
    set name [string map {= =3D , =2C} $user]
    list "$flag,," "n=$name,r=$nonce"
}

proc scram::client_final {digest password gs2header cbdata bare serverFirst} {
    variable MAX_ITERATIONS
    set attrs [scram::Parse $serverFirst]
    if {[dict exists $attrs m]} {
        error "server requires an unsupported SCRAM extension"
    }
    foreach a {r s i} {
        if {![dict exists $attrs $a]} {
            error "server-first-message lacks $a="
        }
    }
    set nonce [dict get $attrs r]
    set ours [dict get [scram::Parse $bare] r]
    if {[string first $ours $nonce] != 0 || $nonce eq $ours} {
        error "server nonce does not extend the client nonce"
    }
    set iter [dict get $attrs i]
    if {![string is entier -strict $iter] || $iter < 1} {
        error "bad iteration count: $iter"
    }
    if {$iter > $MAX_ITERATIONS} {
        error "iteration count too high: $iter"
    }
    if {[catch {binary decode base64 -strict [dict get $attrs s]} salt]} {
        error "bad salt"
    }

    set len [dict get {sha1 20 sha256 32} $digest]
    set salted [::mtls::pbkdf2 $digest [encoding convertto utf-8 $password] \
        $salt $iter $len]
    set withoutProof "c=[binary encode base64 \
        [encoding convertto utf-8 $gs2header]$cbdata],r=$nonce"
    set authMessage [encoding convertto utf-8 \
        "$bare,$serverFirst,$withoutProof"]

    set clientKey [scram::Hmac $digest $salted "Client Key"]
    set storedKey [scram::Hash $digest $clientKey]
    set clientSignature [scram::Hmac $digest $storedKey $authMessage]
    set proof [scram::Xor $clientKey $clientSignature]
    set serverKey [scram::Hmac $digest $salted "Server Key"]
    list "$withoutProof,p=[binary encode base64 $proof]" \
        [scram::Hmac $digest $serverKey $authMessage]
}

proc scram::check_server_final {serverSignature serverFinal} {
    set attrs [scram::Parse $serverFinal]
    if {[dict exists $attrs e]} {
        error "server rejected the authentication: [dict get $attrs e]"
    }
    if {![dict exists $attrs v]
            || [catch {binary decode base64 -strict [dict get $attrs v]} v]
            || $v ne $serverSignature} {
        error "server signature mismatch"
    }
}

proc scram::Parse {message} {
    set attrs {}
    foreach part [split $message ,] {
        if {[regexp {^([A-Za-z])=(.*)$} $part -> k v]} {
            dict set attrs $k $v
        }
    }
    return $attrs
}

proc scram::Hash {digest data} {
    switch -- $digest {
        sha1 { ::sha1::sha1 -bin -- $data }
        sha256 { ::sha2::sha256 -bin -- $data }
    }
}

proc scram::Hmac {digest key data} {
    switch -- $digest {
        sha1 { ::sha1::hmac -bin -key $key -- $data }
        sha256 { ::sha2::hmac -bin -key $key -- $data }
    }
}

proc scram::Xor {a b} {
    binary scan $a c* x
    binary scan $b c* y
    binary format c* [lmap p $x q $y {expr {$p ^ $q}}]
}
