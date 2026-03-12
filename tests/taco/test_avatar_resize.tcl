::tcltest::testConstraint hasMagick [expr {![catch {exec magick -version}]}]

test avatar-resize-for-publish {ResizeForPublish returns valid PNG} \
    -constraints hasMagick \
    -setup {
	tacky_type create tacky
	rename conn _real_conn
	rename mock_conn conn
	tacky account add -acc user@test
	set _client [tacky client user@test]
	$_client.conn configure -bound-jid user@test/res
	$_client.conn fire_ready 0
    } \
    -cleanup {
	rename conn mock_conn
	rename _real_conn conn
	tacky destroy
    } \
    -body {
	# Generate a 256x256 red PNG via magick pipe (binary-safe)
	set pipe [open |[list magick -size 256x256 xc:red png:-] rb]
	set big [chan read $pipe]
	chan close $pipe

	set result [$_client.avatar ResizeForPublish $big]

	# Check PNG magic bytes (89 50 4E 47)
	binary scan $result cu4 bytes
	set bytes
    } -result {137 80 78 71}
