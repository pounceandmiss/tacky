/*
 * The page's end of the `host` media backend (lib/media/media_host.tcl,
 * DOC.md "The host backend"): an RTCPeerConnection per pc, driven by
 * `media <HostCommand>` events, answering with `media hostEvent`.
 * `onRemoteStream(pc, stream, kind)` hands the page a peer's media.
 *
 * Names are pcs and track handles, tacky's; tracks the peer adds are named
 * here and reported with a `track` event.
 *
 * Commands are serialized per pc: some await a promise, and a
 * setRemoteDescription must not overtake the createPeer before it.
 */

// The browser's ICE gathering states are not quite tacky's vocabulary.
const GATHERING = { new: 'new', gathering: 'inprogress', complete: 'complete' };

export function createMediaHost({ send, onRemoteStream = () => {}, log = () => {} }) {
    /** pc name -> { conn, queue, senders: Map, remotes: Map, nextRemote } */
    const peers = new Map();

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

    function createPeer(pc, iceServers) {
        const conn = new RTCPeerConnection({ iceServers: toIceServers(iceServers) });
        const state = {
            conn, queue: Promise.resolve(),
            senders: new Map(), remotes: new Map(), nextRemote: 0,
        };
        peers.set(pc, state);

        conn.onicecandidate = (ev) => {
            // null = end of gathering; onicegatheringstatechange reports that
            if (!ev.candidate) return;
            emit(pc, 'iceCandidate', {
                candidate: ev.candidate.candidate,
                mid: ev.candidate.sdpMid ?? '',
            });
        };
        conn.onicegatheringstatechange = () =>
            emit(pc, 'gatheringState', { state: GATHERING[conn.iceGatheringState] ?? 'new' });
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
            onRemoteStream(pc, ev.streams[0] ?? new MediaStream([ev.track]), ev.track.kind);
        };
        return state;
    }

    async function command(args) {
        const op = args.op;
        const pc = args.pc ?? '';

        if (op === 'close') {
            for (const [name] of peers) closePeer(name);
            return;
        }
        if (op === 'createPeer') {
            // No queue exists yet, so its failure is caught here.
            try {
                if (!peers.has(pc)) createPeer(pc, args.iceServers);
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
            serialize(state, op, pc, () => state.conn.setRemoteDescription({
                type: args.sdpType, sdp: args.sdp,
            }));
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

        case 'attachAudio':
            serialize(state, op, pc, () => attach(state, pc, args.track, args.input, 'audio'));
            return;

        case 'attachVideoSender':
            serialize(state, op, pc, () => attach(state, pc, args.track, args.deviceId, 'video'));
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

    // Put real media behind a track tacky added. A peer-added track name
    // means the receiving side, which already has its stream.
    async function attach(state, pc, trackName, deviceId, kind) {
        const transceiver = state.senders.get(trackName);
        if (!transceiver) return;
        if (transceiver.direction === 'recvonly') return;

        const wanted = deviceId ? { deviceId: { exact: deviceId } } : true;
        let stream;
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
        const track = stream.getTracks().find((t) => t.kind === kind);
        if (track) await transceiver.sender.replaceTrack(track);
    }

    function closePeer(pc) {
        const state = peers.get(pc);
        if (!state) return;
        peers.delete(pc);
        for (const sender of state.conn.getSenders()) {
            sender.track?.stop();
        }
        try { state.conn.close(); } catch { /* already closed */ }
    }

    return {
        command,
        /** For a page that wants to look: the live RTCPeerConnections. */
        peers,
        closeAll() { for (const [name] of peers) closePeer(name); },
    };
}

// iceServers arrives as an array or as an unschema'd Tcl list; URLs have no spaces.
function toIceServers(value) {
    if (!value) return [];
    const urls = Array.isArray(value) ? value : String(value).split(/\s+/);
    return urls.filter(Boolean).map((url) => ({ urls: url }));
}
