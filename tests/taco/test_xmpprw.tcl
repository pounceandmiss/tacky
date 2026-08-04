package require tcltest
namespace import ::tcltest::*
package require xmpprw

# Tag and attribute names are written raw, so jwrite has to refuse a name
# that would break out of the markup rather than emit it.

test xmpprw-xname-accepts-real-names {names xmpp actually uses pass} \
    -body {
        set ok {}
        foreach n {message body x-vcard a.b a-b _x stream:features xml:lang} {
            lappend ok [catch {xname $n}]
        }
        set ok
    } -result {0 0 0 0 0 0 0 0}

test xmpprw-xname-rejects-markup {a name carrying markup is refused} \
    -body {
        set rejected {}
        foreach n [list "q></query><message" "a b" "a'b" "a\"b" "a<b" "&x" \
                {} "1abc" "-x" ".x" "a/b" "a=b" "?pi" "!doctype" "a\nb"] {
            lappend rejected [catch {xname $n}]
        }
        set rejected
    } -result {1 1 1 1 1 1 1 1 1 1 1 1 1 1 1}

test xmpprw-jwrite-rejects-injected-tag {jwrite refuses a tag name with markup} \
    -body {
        set node [j iq -type set {
            j query -ns jabber:iq:register {
                j {q></query></iq><message to='v@x'><body>pwned</body></message><iq><x }
            }
        }]
        catch {jwrite $node} err
        string match "Invalid XML name:*" $err
    } -result 1

test xmpprw-jwrite-rejects-injected-attr {jwrite refuses an attribute name with markup} \
    -body {
        set node [dict create tag message ns jabber:client body {} tail {} \
            children {} attrs [dict create {a='b'/><evil} v]]
        catch {jwrite $node} err
        string match "Invalid XML name:*" $err
    } -result 1

# A namespaced attribute key is {ns localname}; the local half is what
# lands next to the generated prefix.
test xmpprw-jwrite-rejects-injected-prefixed-attr \
    {jwrite refuses a namespaced attribute whose local name carries markup} \
    -body {
        set node [dict create tag message ns jabber:client body {} tail {} \
            children {} attrs [dict create [list urn:x {a='b'/><evil}] v]]
        catch {jwrite $node} err
        string match "Invalid XML name:*" $err
    } -result 1

test xmpprw-jwrite-roundtrips-parsed-stanza {a parsed stanza still serialises} \
    -body {
        set node [xmppreader string {<message from='a@b/c' type='chat'><body>hi &amp; bye</body></message>}]
        jwrite $node
    } -result {<message from='a@b/c' type='chat'><body>hi &amp; bye</body></message>}
