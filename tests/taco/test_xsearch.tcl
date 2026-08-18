# Filter and extraction spell a field the same way, and an attribute value is
# free to start with a dash - only a keyword ends the filter early.
package require tcltest
namespace import ::tcltest::*
package require taco

proc _xsDoc {} {
    j r {
        j a @id 1 -body hello
        j a @id -2 -ns urn:example -body world
    }
}

test xsearch-get-accepts-dashed-field {-get -body and -get body agree} -body {
    set d [_xsDoc]
    list [xsearch $d a -get body] [xsearch $d a -get -body] \
        [xsearch $d a -gather -tag] [xsearch $d a @id -2 -get -ns]
} -result {hello hello {a a} urn:example}

test xsearch-attr-value-may-start-with-dash \
    {a leading dash in an attribute value is a value, not a keyword} -body {
        set d [_xsDoc]
        list [xsearch $d a @id -2 -get body] [llength [xsearch $d a @id]]
    } -result {world 2}

test xsearch-attr-existence-still-ends-at-keyword \
    {@attr followed by a keyword stays an existence filter} -body {
        set d [_xsDoc]
        list [xsearch $d a @id -get body] [llength [xsearch $d a @id -ns urn:example]]
    } -result {hello 1}
