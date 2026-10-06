package require tcltest
namespace import ::tcltest::*
package require taco

# PBKDF2 comes from mtls; builds without it (wasm) have no SCRAM.
testConstraint mtls [scram::available]

# RFC 5802 section 5
set rfc5802_bare {n=user,r=fyko+d2lbbFgONRv9qkxdawL}
set rfc5802_first {r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096}

test scram-sha1-rfc5802 {SCRAM-SHA-1 reproduces the RFC 5802 exchange} -constraints mtls -body {
    lassign [scram::client_first user fyko+d2lbbFgONRv9qkxdawL n] gs2 bare
    lassign [scram::client_final sha1 pencil $gs2 "" $bare $rfc5802_first] \
        final sig
    scram::check_server_final $sig v=rmF9pqV8S7suAoZWja4dJRkFsKQ=
    list $gs2 $bare $final
} -result {n,, n=user,r=fyko+d2lbbFgONRv9qkxdawL c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=}

test scram-username-escaped {= and , in the username are escaped} -constraints mtls -body {
    lindex [scram::client_first a=b,c nonce n] 1
} -result {n=a=3Db=2Cc,r=nonce}

test scram-channel-binding-in-c {c= carries the gs2 header and the binding data} -constraints mtls -body {
    lassign [scram::client_final sha1 pencil p=tls-exporter,, \
        [string repeat \x01 4] $rfc5802_bare $rfc5802_first] final
    lindex [split $final ,] 0
} -result c=cD10bHMtZXhwb3J0ZXIsLAEBAQE=

test scram-rejects-foreign-nonce {a server nonce not extending ours is refused} -constraints mtls -body {
    scram::client_final sha1 pencil n,, "" $rfc5802_bare \
        r=somethingelse,s=QSXCR+Q6sek8bf92,i=4096
} -returnCodes error -result {server nonce does not extend the client nonce}

test scram-rejects-mandatory-extension {m= is refused} -constraints mtls -body {
    scram::client_final sha1 pencil n,, "" $rfc5802_bare m=ext,$rfc5802_first
} -returnCodes error -result {server requires an unsupported SCRAM extension}

test scram-rejects-bad-iterations {a non-positive iteration count is refused} -constraints mtls -body {
    scram::client_final sha1 pencil n,, "" $rfc5802_bare \
        r=fyko+d2lbbFgONRv9qkxdawLx,s=QSXCR+Q6sek8bf92,i=0
} -returnCodes error -result {bad iteration count: 0}

test scram-server-error {e= in the server-final message is reported} -constraints mtls -body {
    scram::check_server_final x e=invalid-proof
} -returnCodes error -result {server rejected the authentication: invalid-proof}

test scram-server-signature-mismatch {a wrong v= is refused} -constraints mtls -body {
    scram::check_server_final x v=[binary encode base64 y]
} -returnCodes error -result {server signature mismatch}

test scram-rejects-missing-salt {a server-first without s= is refused} -constraints mtls -body {
    scram::client_final sha1 pencil n,, "" $rfc5802_bare \
        r=fyko+d2lbbFgONRv9qkxdawLx,i=4096
} -returnCodes error -result {server-first-message lacks s=}

test scram-rejects-bad-salt {a salt that is not base64 is refused} -constraints mtls -body {
    scram::client_final sha1 pencil n,, "" $rfc5802_bare \
        r=fyko+d2lbbFgONRv9qkxdawLx,s=not*base64,i=4096
} -returnCodes error -result {bad salt}

test scram-rejects-huge-iterations {an iteration count above the cap is refused before any hashing} -constraints mtls -body {
    scram::client_final sha1 pencil n,, "" $rfc5802_bare \
        r=fyko+d2lbbFgONRv9qkxdawLx,s=QSXCR+Q6sek8bf92,i=1000000000
} -returnCodes error -result {iteration count too high: 1000000000}

test scram-sha1-mechanisms {both SCRAM-SHA-1 names map to sha1, both SHA-256 names to sha256} -body {
    lmap m {SCRAM-SHA-1 SCRAM-SHA-1-PLUS SCRAM-SHA-256 SCRAM-SHA-256-PLUS} {
        scram::digest $m
    }
} -result {sha1 sha1 sha256 sha256}

test scram-unknown-mechanism {a mechanism that is not SCRAM is an error} -body {
    scram::digest PLAIN
} -returnCodes error -result {not a supported SCRAM mechanism: PLAIN}
