# Shared by the GUI tests that need a real backend behind the thing under
# test: an in-process account whose connection is the mock, so stanzas can be
# fed in and written ones inspected.
#
# Sourced before the test_*.tcl files (the runner globs *.tcl in sorted order),
# so every file below can call these.

proc mock_backend_up {{acc user@test.example.com}} {
    rename conn _real_conn
    rename mock_conn conn
    tacky_type create tacky
    tk_avatarcache create avatarcache
    tacky account add -acc $acc
    set ::_client [tacky client $acc]
    $::_client.conn configure -bound-jid $acc/res1
    $::_client.conn fire_ready 0
    $::_client.conn clear
}

proc mock_backend_down {} {
    avatarcache destroy
    rename conn mock_conn
    rename _real_conn conn
    tacky destroy
}
