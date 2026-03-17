proc jid {cmd args} {
    set pattern {^(?:([^@/?]+)@)?([^/@?]+)(?:/([^?]+))?(?:\?(.+))?$}

    switch -- $cmd {
        explode {lassign $args jid varName
            upvar $varName e
            if {![regexp $pattern $jid -> e(username) e(domain) e(resource) e(query)]} {
                error "Invalid JID: $jid"
            }
            if {$e(username) eq "" && ![string match *.* $e(domain)]} {
                error "Invalid JID: $jid"
            }
        }

        assemble {lassign $args varName
            upvar $varName e
            if {$e(username) ne ""} {
                set res $e(username)@$e(domain)
            } else {
                set res $e(domain)
            }
            if {[info exists e(resource)] && $e(resource) ne ""} {
                append res /$e(resource)
            }
            if {[info exists e(query)] && $e(query) ne ""} {
                append res ?$e(query)
            }
            return $res
        }

        bare {lassign $args jid
            jid explode $jid e
            if {$e(username) ne ""} {
                return $e(username)@$e(domain)
            }
            return $e(domain)
        }

        matches-bare {lassign $args a b
            string equal -nocase [jid bare $a] [jid bare $b]
        }

        forMe {lassign $args to myjid
            if {$to eq ""} {
                return 1
            }
            if {[jid resource $to] eq ""} {
                string equal -nocase $to [jid bare $myjid]
            } else {
                expr {$to eq $myjid}
            }
        }

        valid {lassign $args jid
            if {![regexp $pattern $jid -> username domain]} {
                return 0
            }
            if {$username eq "" && ![string match *.* $domain]} {
                return 0
            }
            return 1
        }

        default {lassign $args jid
            if {$cmd ni {username domain resource query}} {
                error "Unknown jid subcommand: $cmd"
            }
            jid explode $jid arr
            return $arr($cmd)
        }
    }
}
