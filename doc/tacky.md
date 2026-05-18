The tacky command acts as a bridge between the GUI and the backend. All method calls go through it — internally it usually dispatches them by -acc to appropriate internal client objects. Internals can in turn emit tacky events which will reach the frontend. Having a single bridge allows to transparently have the backend run in the same or different thread or process, with no special handling on the frontend.

## events

Backend → gui. The gui registers listeners, tacky dispatches to matching ones.

### listen / unlisten

    tacky listen ?-tag $tag? $module $event ?-field $value ...? $command

Returns a tag id (auto-assigned unless specified). Several listeners can share the same tag. field filters (e.g. `-acc`, `-jid`) narrow which events fire the callback.

    tacky unlisten $tag

Removes all listeners for that tag.

## Calling tacky

general form:

    tacky $module $method  ?...args? ?-tag $tag? ?-command $cb? ?-onerror $errcb?

All args are keyword args. Some args are special and intercepted by tacky, including -command, -tag, -onerror. -command and -onerror are command prefixes that will be called on result or error. 

### cancellation
-tag when supplied to a command can be used in two ways:
Passively stop listening for result from frontend:
    tacky unlisten $tag
Notify backend that we're no longer interested in a result - module-specific.
    tacky $module cancel -acc $acc -tag $tag

E.g. if a widget called a method and asks for a result, but the destructor is called before the result is received, it *must* call tacky unlisten $tag to make sure tacky doesn't try to call it. It *should* also call the module-specific cancel to maybe save some work.

### Event examples

**account**

    account <Added>       -acc $jid
    account <Enabled>     -acc $jid
    account <Disabled>    -acc $jid
    account <Removed>     -acc $jid

**message**

    message <Received>    -acc $acc -jid $chatJid -message $msgDict
    message <Sent>        -acc $acc -jid $chatJid -message $msgDict
    message <Patch>       -jid $chatJid -messages $patchList
    message <CatchupDone> -acc $acc -count $n

**chatlist**

    chatlist <Changed>
    chatlist <RecentTop>  -jid $jid -name $name -source $source ?-autojoin $val? ?-muc-status $s?
    chatlist <RecentDrop> -jid $jid
    chatlist <MucStatus>  -jid $jid -muc-status joined|error|""

**setting**

    setting <Changed>     -key $key -value $value

## Method examples

### account

    tacky account list ?-enabled 1? ?-command $cb?
    tacky account exists -acc $jid ?-command $cb?
    tacky account get -acc $jid ?-field username|password|domain|enabled? ?-command $cb?
    tacky account add -acc $jid ?-password $pw? ?-domain $d? ?-username $u?
    tacky account set -acc $jid ?-password $pw? ?-domain $d? ?-username $u? ?-enabled 1?
    tacky account remove -acc $jid
    tacky account enable -acc $jid
    tacky account disable -acc $jid
    tacky account changePassword -acc $jid -password $new ?-command $cb?

### message

    tacky message send -acc $acc -chat $jid -body $text ?-command $cb?
    tacky message history -acc $acc -chat $jid -limit 50 ?-before $ts? ?-after $ts? ?-tag $tag? ?-command $cb?
    tacky message goto -acc $acc -chat $jid -date $timestamp -source local|remote -limit 50 ?-tag $tag? ?-command $cb?
    tacky message cancel -acc $acc -tag $tag
    tacky message rawxml -acc $acc -chat $jid -timestamp $id ?-command $cb?
