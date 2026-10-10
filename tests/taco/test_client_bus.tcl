# Unit tests for taco_client_bus
package require tcltest
namespace import ::tcltest::*
package require taco

test bus-subscribe-publish {subscribe and publish delivers to subscriber} \
    -setup { taco_client_bus create testbus } \
    -cleanup { testbus destroy } \
    -body {
        set got {}
        testbus subscribe _ <Foo> {apply {{args} { set ::got $args }}}
        testbus publish <Foo> -x 1
        set got
    } -result {-x 1}

test bus-unsubscribe-removes {unsubscribe stops delivery} \
    -setup { taco_client_bus create testbus } \
    -cleanup { testbus destroy } \
    -body {
        set got {}
        testbus subscribe t1 <Foo> {apply {{args} { lappend ::got $args }}}
        testbus publish <Foo> -a 1
        testbus unsubscribe t1
        testbus publish <Foo> -b 2
        llength $got
    } -result {1}

test bus-unsubscribe-by-tag-multiple {unsubscribe removes all events for that tag} \
    -setup { taco_client_bus create testbus } \
    -cleanup { testbus destroy } \
    -body {
        set got {}
        testbus subscribe t1 <A> {apply {{args} { lappend ::got A }}}
        testbus subscribe t1 <B> {apply {{args} { lappend ::got B }}}
        testbus publish <A>
        testbus publish <B>
        testbus unsubscribe t1
        testbus publish <A>
        testbus publish <B>
        set got
    } -result {A B}

test bus-multiple-subscribers {multiple subscribers on same event both fire} \
    -setup { taco_client_bus create testbus } \
    -cleanup { testbus destroy } \
    -body {
        set got {}
        testbus subscribe t1 <Foo> {apply {{args} { lappend ::got s1 }}}
        testbus subscribe t2 <Foo> {apply {{args} { lappend ::got s2 }}}
        testbus publish <Foo>
        set got
    } -result {s1 s2}

test bus-publish-no-subscribers {publish with no subscribers is a no-op} \
    -setup { taco_client_bus create testbus } \
    -cleanup { testbus destroy } \
    -body {
        testbus publish <NoSuchEvent> -data 123
    } -result {}

test bus-unsubscribe-nonexistent {unsubscribe unknown tag is a no-op} \
    -setup { taco_client_bus create testbus } \
    -cleanup { testbus destroy } \
    -body {
        testbus unsubscribe nosuchtag
    } -result {}

test bus-unsubscribe-preserves-others {unsubscribe one tag preserves other tags on same event} \
    -setup { taco_client_bus create testbus } \
    -cleanup { testbus destroy } \
    -body {
        set got {}
        testbus subscribe t1 <Foo> {apply {{args} { lappend ::got t1 }}}
        testbus subscribe t2 <Foo> {apply {{args} { lappend ::got t2 }}}
        testbus unsubscribe t1
        testbus publish <Foo>
        set got
    } -result {t2}

# A subscriber's error stays its own: the ones after it still get the event,
# publish returns normally, and the error goes to the background handler.
test bus-subscriber-error-isolated {a failing subscriber does not stop the next one or the publisher} \
    -setup {
        taco_client_bus create testbus
        set ::_busSavedBgerror [interp bgerror {}]
        interp bgerror {} {apply {{msg opts} { lappend ::_busBgerrors $msg }}}
    } \
    -cleanup {
        interp bgerror {} $::_busSavedBgerror
        unset ::_busSavedBgerror ::_busBgerrors
        testbus destroy
    } \
    -body {
        set got {}
        set ::_busBgerrors {}
        testbus subscribe t1 <Foo> {apply {{args} { error "store is locked" }}}
        testbus subscribe t2 <Foo> {apply {{args} { lappend ::got $args }}}
        set r [catch {testbus publish <Foo> -x 1}]
        list $r $got $::_busBgerrors
    } -result {0 {{-x 1}} {{store is locked}}}
