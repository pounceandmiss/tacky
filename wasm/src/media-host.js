/*
 * The page's end of the `host` media backend (lib/media/media_host.tcl,
 * DOC.md "The host backend"): an RTCPeerConnection per pc, driven by
 * `media <HostCommand>` events, answering with `media hostEvent`.
 *
 * Backend-facing names are pcs and track handles; page-facing ones
 * (onRemoteStream, setAudioEnabled) are call sids, from createPeer. Tracks
 * the peer adds are named here and reported with a `track` event.
 *
 * An answerer gets no addTrack: it sends on the offer's m-lines, attaching to
 * the peer's track names. So those transceivers are made sendrecv before the
 * answer, and an attach naming a peer's track adopts its transceiver.
 *
 * Commands are serialized per pc: some await a promise, and a
 * setRemoteDescription must not overtake the createPeer before it.
 *
 * One camera for the page: every pc sends a clone of its track, and a preview
 * (openPreview) holds it for a self-view that outlives any one pc. The camera
 * stops once nobody holds it.
 */

export function createMediaHost({
    send, onRemoteStream = () => {}, onLocalStream = () => {}, onPreview = () => {}, log = () => {},
}) {
    /** pc name -> { conn, sid, queue, senders: Map, remotes: Map, nextRemote, camera } */
    const peers = new Map();
    /** sid -> pc name, for the page-facing calls */
    const pcOf = new Map();
    /** preview name -> the MediaStream handed to onPreview, or a symbol while it opens */
    const previews = new Map();
    /** The camera: its track once open, the pending open, and who holds it. */
    const camera = { track: null, opening: null, users: new Set() };

    const emit = (pc, type, fields = {}) =>
        send(['media', 'hostEvent', { pc, type, ...fields }]);

    const fail = (pc, op, reason, fatal = 0) => {
        log(`media: ${op} on ${pc}: ${reason}`);
        emit(pc, 'error', { op, reason, fatal });
    };

    // Queue one command for a pc.
    const serialize = (state, op, pc, work) => {
        state.queue = state.queue
            .then(work)
            .catch((err) => fail(pc, op, String(err?.message ?? err)));
    };

    function createPeer(pc, iceServers, sid) {
        const conn = new RTCPeerConnection({ iceServers: toIceServers(iceServers) });
        const state = {
            conn, sid, queue: Promise.resolve(),
            senders: new Map(), remotes: new Map(), nextRemote: 0,
        };
        peers.set(pc, state);
        if (sid) pcOf.set(sid, pc);

        conn.onicecandidate = (ev) => {
            // null = end of gathering; onicegatheringstatechange reports that
            if (!ev.candidate) return;
            emit(pc, 'iceCandidate', {
                candidate: ev.candidate.candidate,
                mid: ev.candidate.sdpMid ?? '',
            });
        };
        conn.onicegatheringstatechange = () =>
            emit(pc, 'gatheringState', { state: conn.iceGatheringState });
        conn.onconnectionstatechange = () =>
            emit(pc, 'connectionState', { state: conn.connectionState });
        conn.ontrack = (ev) => {
            // Ours to name; tacky uses it from here on.
            const name = `remote-${state.nextRemote++}`;
            state.remotes.set(name, ev);
            emit(pc, 'track', {
                track: name,
                kind: ev.track.kind,
                mid: ev.transceiver?.mid ?? '',
            });
            onRemoteStream(sid, ev.streams[0] ?? new MediaStream([ev.track]), ev.track.kind);
        };
        return state;
    }

    async function command(args) {
        const op = args.op;
        const pc = args.pc ?? '';

        if (op === 'close') {
            for (const [name] of peers) closePeer(name);
            for (const [name] of previews) closePreview(name);
            return;
        }
        if (op === 'openPreview') {
            await openPreview(pc, args.deviceId);
            return;
        }
        if (op === 'closePreview') {
            closePreview(pc);
            return;
        }
        if (op === 'createPeer') {
            // No queue exists yet, so its failure is caught here.
            try {
                if (!peers.has(pc)) createPeer(pc, args.iceServers, args.sid ?? '');
            } catch (err) {
                fail(pc, op, String(err?.message ?? err), 1);
            }
            return;
        }
        const state = peers.get(pc);
        if (!state) {
            // pc already gone
            return;
        }
        switch (op) {
        case 'closePeer':
            closePeer(pc);
            return;

        case 'addTrack':
            // A transceiver now; attachAudio/attachVideoSender supplies the track.
            serialize(state, op, pc, async () => {
                state.senders.set(args.track, state.conn.addTransceiver(args.kind, {
                    direction: args.direction || 'sendrecv',
                }));
            });
            return;

        case 'setLocalDescription':
            serialize(state, op, pc, async () => {
                // An empty sdp: the browser makes the offer or answer.
                if (args.sdp) {
                    await state.conn.setLocalDescription({
                        type: args.sdpType, sdp: args.sdp,
                    });
                } else {
                    await state.conn.setLocalDescription();
                }
                const local = state.conn.localDescription;
                emit(pc, 'localDescription', { sdp: local.sdp, sdpType: local.type });
            });
            return;

        case 'setRemoteDescription':
            serialize(state, op, pc, async () => {
                await state.conn.setRemoteDescription({ type: args.sdpType, sdp: args.sdp });
                if (args.sdpType !== 'offer') return;
                // Offered m-lines start recvonly here; the answer would say so.
                const ours = new Set(state.senders.values());
                for (const t of state.conn.getTransceivers()) {
                    if (!ours.has(t) && t.direction === 'recvonly') t.direction = 'sendrecv';
                }
            });
            return;

        case 'addRemoteCandidate':
            serialize(state, op, pc, async () => {
                if (!args.candidate) return;
                await state.conn.addIceCandidate({
                    candidate: args.candidate,
                    sdpMid: args.mid || null,
                });
            });
            return;

        // Queued so the transceiver from addTrack exists, but the device
        // prompt is not awaited there: the offer must not wait on it, and
        // replaceTrack works without renegotiation whenever the media comes.
        case 'attachAudio':
            serialize(state, op, pc, () => void attach(state, pc, op, args.track, args.input, 'audio'));
            return;

        case 'attachVideoSender':
            serialize(state, op, pc, () => void attachCamera(state, pc, op, args.track, args.deviceId));
            return;

        case 'attachVideoReceiver':
            // The page has the stream from ontrack already.
            return;

        case 'setVideoEnabled':
            serialize(state, op, pc, async () => {
                for (const transceiver of state.senders.values()) {
                    const track = transceiver.sender?.track;
                    if (track?.kind === 'video') track.enabled = !!Number(args.on);
                }
            });
            return;

        // Devices are the page's; the backend declares no capability for them.
        case 'setAudioDevice':
        case 'setAudioVolume':
        case 'setVideoDevice':
            return;

        default:
            fail(pc, op, 'unknown command');
        }
    }

    // The transceiver to send $trackName on: ours, or the one a peer's track
    // arrived on (the answerer's case).
    function senderOf(state, trackName) {
        const own = state.senders.get(trackName);
        if (own) return own;
        const transceiver = state.remotes.get(trackName)?.transceiver;
        if (transceiver) state.senders.set(trackName, transceiver);
        return transceiver;
    }

    // Put real media behind a track. No mic is fatal to the call; no camera
    // leaves it audio-only.
    async function attach(state, pc, op, trackName, deviceId, kind) {
        const transceiver = senderOf(state, trackName);
        if (!transceiver) return;
        if (transceiver.direction === 'recvonly') return;

        const wanted = deviceId ? { deviceId: { exact: deviceId } } : true;
        let stream;
        try {
            try {
                stream = await navigator.mediaDevices.getUserMedia({ [kind]: wanted });
            } catch (err) {
                if (!deviceId) throw err;
                // Device gone or refused: fall back to the default and say so.
                stream = await navigator.mediaDevices.getUserMedia({ [kind]: true });
                emit(pc, 'deviceFallback', {
                    kind: kind === 'video' ? 'camera' : 'capture',
                    id: '',
                    reason: String(err?.name ?? err),
                });
            }
        } catch (err) {
            fail(pc, op, String(err?.message ?? err), kind === 'audio' ? 1 : 0);
            return;
        }
        if (!peers.has(pc)) {
            for (const t of stream.getTracks()) t.stop();
            return;
        }
        const track = stream.getTracks().find((t) => t.kind === kind);
        if (track) await transceiver.sender.replaceTrack(track);
        onLocalStream(state.sid, stream, kind);
    }

    // The camera's own track for `user`, opened by the first to ask; later
    // askers share the open in progress. A device that will not open falls
    // back to the default and tells `user` so. Throws when nothing opens.
    async function holdCamera(user, deviceId) {
        camera.users.add(user);
        if (camera.track) return camera.track;
        if (!camera.opening) {
            camera.opening = (async () => {
                const wanted = deviceId ? { deviceId: { exact: deviceId } } : true;
                try {
                    return await navigator.mediaDevices.getUserMedia({ video: wanted });
                } catch (err) {
                    if (!deviceId) throw err;
                    emit(user, 'deviceFallback', { kind: 'camera', id: '', reason: String(err?.name ?? err) });
                    return navigator.mediaDevices.getUserMedia({ video: true });
                }
            })();
        }
        try {
            const stream = await camera.opening;
            const track = stream.getVideoTracks()[0];
            // Everyone left while it opened: nobody wants it now.
            if (camera.users.size === 0) {
                track?.stop();
                return null;
            }
            camera.track = track ?? null;
            return camera.track;
        } catch (err) {
            camera.users.delete(user);
            throw err;
        } finally {
            camera.opening = null;
        }
    }

    function releaseCamera(user) {
        if (!camera.users.delete(user) || camera.users.size > 0) return;
        camera.track?.stop();
        camera.track = null;
    }

    // Camera -> the pc: a clone of the one camera, so this pc's closing or
    // muting touches no other. No camera leaves the call audio-only.
    async function attachCamera(state, pc, op, trackName, deviceId) {
        const transceiver = senderOf(state, trackName);
        if (!transceiver || transceiver.direction === 'recvonly' || state.camera) return;
        let source;
        try {
            source = await holdCamera(pc, deviceId);
        } catch (err) {
            fail(pc, op, String(err?.message ?? err), 0);
            return;
        }
        if (!source) return;
        if (!peers.has(pc)) {
            releaseCamera(pc);
            return;
        }
        const clone = source.clone();
        state.camera = clone;
        await transceiver.sender.replaceTrack(clone);
        onLocalStream(state.sid, new MediaStream([clone]), 'video');
    }

    // A self-view under `name` while no pc need be sending: a group call's.
    async function openPreview(name, deviceId) {
        if (previews.has(name)) return;
        // Ours while it opens: a close and a fresh open meanwhile is another.
        const opening = Symbol(name);
        previews.set(name, opening);
        let source;
        try {
            source = await holdCamera(name, deviceId);
        } catch (err) {
            if (previews.get(name) === opening) previews.delete(name);
            fail(name, 'openPreview', String(err?.message ?? err), 1);
            return;
        }
        if (previews.get(name) !== opening) return;
        if (!source) {
            previews.delete(name);
            return;
        }
        const stream = new MediaStream([source.clone()]);
        previews.set(name, stream);
        onPreview(name, stream);
    }

    function closePreview(name) {
        if (!previews.has(name)) return;
        const stream = previews.get(name);
        previews.delete(name);
        releaseCamera(name);
        if (!(stream instanceof MediaStream)) return;
        for (const t of stream.getTracks()) t.stop();
        onPreview(name, null);
    }

    function closePeer(pc) {
        const state = peers.get(pc);
        if (!state) return;
        peers.delete(pc);
        if (state.sid && pcOf.get(state.sid) === pc) pcOf.delete(state.sid);
        // Our own tracks: the mic, and this pc's clone of the camera.
        for (const sender of state.conn.getSenders()) {
            sender.track?.stop();
        }
        if (state.camera || camera.users.has(pc)) {
            state.camera?.stop();
            releaseCamera(pc);
        }
        try { state.conn.close(); } catch { /* already closed */ }
    }

    // Mute: the mic track is the page's, so no backend command is involved.
    // Returns whether the call has a pc.
    function setAudioEnabled(sid, on) {
        const state = peers.get(pcOf.get(sid));
        if (!state) return false;
        for (const transceiver of state.senders.values()) {
            const track = transceiver.sender?.track;
            if (track?.kind === 'audio') track.enabled = !!on;
        }
        return true;
    }

    return {
        command,
        setAudioEnabled,
        /** By pc: `{ conn, sid, ... }`. Not contract. */
        peers,
        /** The camera's state. Not contract. */
        camera,
        closeAll() {
            for (const [name] of peers) closePeer(name);
            for (const [name] of previews) closePreview(name);
        },
    };
}

// iceServers arrives as an array or as an unschema'd Tcl list; URLs have no spaces.
// turn:user:pass@host:port, percent-encoded, as extdisco.tcl builds it and
// libdatachannel takes it. The browser wants the credentials as fields, as
// libwebrtc does; this is rtc-webrtc's ParseIceServer.
function toIceServers(value) {
    if (!value) return [];
    const urls = Array.isArray(value) ? value : String(value).split(/\s+/);
    return urls.filter(Boolean).map((url) => {
        const colon = url.indexOf(':');
        const at = url.lastIndexOf('@');
        if (colon < 0 || at < colon) return { urls: url };
        const userinfo = url.slice(colon + 1, at);
        const split = userinfo.indexOf(':');
        return {
            urls: url.slice(0, colon + 1) + url.slice(at + 1),
            username: decodeURIComponent(split < 0 ? userinfo : userinfo.slice(0, split)),
            credential: split < 0 ? '' : decodeURIComponent(userinfo.slice(split + 1)),
        };
    });
}
