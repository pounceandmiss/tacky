/*
 * media-host.js under node, with the browser faked:
 *
 *   node wasm/test/media-host.mjs
 *
 * RTCPeerConnection, MediaStream, tracks and getUserMedia are fakes that
 * count and record. Checked: one camera however many pcs and previews want
 * it, a clone per pc, and who stops what when one goes.
 */
import { createMediaHost } from '../src/media-host.js';

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
    if (!ok) failures++;
};

// -- the browser ------------------------------------------------------------

let nextTrack = 0;
class FakeTrack {
    constructor(kind, source = null) {
        this.id = `t${nextTrack++}`;
        this.kind = kind;
        this.readyState = 'live';
        this.enabled = true;
        this.source = source;
    }
    clone() { return new FakeTrack(this.kind, this.source ?? this); }
    stop() { this.readyState = 'ended'; }
}

class FakeStream {
    constructor(tracks = []) { this.tracks = [...tracks]; }
    getTracks() { return [...this.tracks]; }
    getVideoTracks() { return this.tracks.filter((t) => t.kind === 'video'); }
    getAudioTracks() { return this.tracks.filter((t) => t.kind === 'audio'); }
}

class FakePeer {
    constructor() {
        this.transceivers = [];
        this.closed = false;
    }
    addTransceiver(kind, { direction }) {
        const transceiver = {
            kind, direction,
            sender: { track: null, async replaceTrack(t) { this.track = t; } },
        };
        this.transceivers.push(transceiver);
        return transceiver;
    }
    getSenders() { return this.transceivers.map((t) => t.sender); }
    getTransceivers() { return [...this.transceivers]; }
    // The sdp is just the m-line kinds, space-separated. Each gets a recvonly
    // transceiver and a peer track, as in a browser.
    async setRemoteDescription({ type, sdp }) {
        if (type !== 'offer') return;
        for (const kind of sdp.split(' ').filter(Boolean)) {
            const transceiver = this.addTransceiver(kind, { direction: 'recvonly' });
            transceiver.mid = String(this.transceivers.length - 1);
            this.ontrack?.({ track: new FakeTrack(kind), transceiver, streams: [] });
        }
    }
    close() { this.closed = true; }
}

// getUserMedia: counts video opens, can be held open until released, can
// refuse, and can refuse only an exact deviceId.
const gum = { video: 0, audio: 0, gate: null, refuse: false, refuseExact: false, cameras: [] };
function resetGum() {
    Object.assign(gum, { video: 0, audio: 0, gate: null, refuse: false, refuseExact: false, cameras: [] });
}
function holdGum() {
    let open;
    gum.gate = new Promise((r) => { open = r; });
    return () => { gum.gate = null; open(); };
}

globalThis.RTCPeerConnection = FakePeer;
globalThis.MediaStream = FakeStream;
Object.defineProperty(globalThis, 'navigator', {
    value: {
        mediaDevices: {
            async getUserMedia(constraints) {
                const kind = constraints.video ? 'video' : 'audio';
                gum[kind]++;
                if (gum.gate) await gum.gate;
                if (gum.refuse) throw Object.assign(new Error('Permission denied'), { name: 'NotAllowedError' });
                if (gum.refuseExact && constraints[kind]?.deviceId?.exact) {
                    throw Object.assign(new Error('no such device'), { name: 'OverconstrainedError' });
                }
                const track = new FakeTrack(kind);
                if (kind === 'video') gum.cameras.push(track);
                return new FakeStream([track]);
            },
        },
    },
    configurable: true,
});

// The host is fed without awaiting, as tacky-transport and index.html do; a
// case that holds getUserMedia open must not await the command behind it.

// -- the host ---------------------------------------------------------------

function makeHost() {
    resetGum();
    const sent = [];
    const previews = [];
    const locals = [];
    const host = createMediaHost({
        send: (frame) => sent.push(frame),
        onPreview: (name, stream) => previews.push([name, stream]),
        onLocalStream: (sid, stream, kind) => locals.push([sid, stream, kind]),
    });
    const events = (type) => sent.map((f) => f[2]).filter((e) => e.type === type);
    return { host, sent, previews, locals, events };
}

// Long enough for every queued command and the unawaited attaches behind them.
const settle = async () => {
    for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r));
};

// A pc with a video sender, as the backend sets one up.
async function videoPeer(host, pc, deviceId) {
    await host.command({ op: 'createPeer', pc, sid: `sid-${pc}` });
    await host.command({ op: 'addTrack', pc, track: 'v', kind: 'video' });
    await host.command({ op: 'attachVideoSender', pc, track: 'v', ...(deviceId ? { deviceId } : {}) });
}
const senderTrack = (host, pc) => host.peers.get(pc)?.conn.transceivers[0].sender.track;

// -- cases ------------------------------------------------------------------

{
    const { host, previews } = makeHost();
    for (const pc of ['pc1', 'pc2', 'pc3']) await videoPeer(host, pc);
    await host.command({ op: 'openPreview', pc: 'call' });
    await settle();

    check('three pcs and a preview open the camera once', gum.video === 1, `${gum.video} opens`);
    const clones = ['pc1', 'pc2', 'pc3'].map((pc) => senderTrack(host, pc));
    check('every sender has a clone of the camera',
        clones.every((t) => t && t.source === gum.cameras[0] && t !== gum.cameras[0]));
    check('and no two share one', new Set(clones).size === 3);
    const preview = previews.at(-1)?.[1]?.getVideoTracks()[0];
    check('the preview is a clone of its own', preview && preview.source === gum.cameras[0] && !clones.includes(preview));

    await host.command({ op: 'closePeer', pc: 'pc2' });
    check('closing a pc stops its clone', clones[1].readyState === 'ended');
    check('and only that one',
        clones[0].readyState === 'live' && clones[2].readyState === 'live' && preview.readyState === 'live'
        && gum.cameras[0].readyState === 'live');

    await host.command({ op: 'closePeer', pc: 'pc1' });
    await host.command({ op: 'closePeer', pc: 'pc3' });
    check('with every pc closed the preview still runs',
        preview.readyState === 'live' && gum.cameras[0].readyState === 'live');
    check('held by the preview alone', host.camera.users.size === 1 && host.camera.users.has('call'));

    await host.command({ op: 'closePreview', pc: 'call' });
    check('closing the preview stops the camera',
        preview.readyState === 'ended' && gum.cameras[0].readyState === 'ended' && host.camera.track === null);
    check('and says so with null', previews.at(-1)?.[0] === 'call' && previews.at(-1)?.[1] === null);
    check('nobody holds it', host.camera.users.size === 0);
}

{
    const { host } = makeHost();
    await host.command({ op: 'openPreview', pc: 'call' });
    await settle();
    await host.command({ op: 'closePreview', pc: 'call' });
    check('a preview with no pcs, closed, stops the camera', gum.cameras[0]?.readyState === 'ended');
    await videoPeer(host, 'pc1');
    await settle();
    check('the next to want it opens it afresh',
        gum.video === 2 && senderTrack(host, 'pc1')?.source === gum.cameras[1] && gum.cameras[1].readyState === 'live');
}

{
    const { host, locals } = makeHost();
    const release = holdGum();
    await videoPeer(host, 'pc1');
    await settle();
    await host.command({ op: 'closePeer', pc: 'pc1' });
    release();
    await settle();
    check('a pc closed while the camera opens does not leak it',
        gum.cameras[0]?.readyState === 'ended' && host.camera.track === null && host.camera.users.size === 0);
    check('nor reports a self-view for it', locals.length === 0);
}

{
    const { host, previews } = makeHost();
    const release = holdGum();
    await videoPeer(host, 'pc1');
    await videoPeer(host, 'pc2');
    void host.command({ op: 'openPreview', pc: 'call' });
    await settle();
    await host.command({ op: 'closePeer', pc: 'pc1' });
    release();
    await settle();
    check('askers while it opens share the one open', gum.video === 1, `${gum.video} opens`);
    check('the pc that left meanwhile holds nothing',
        !host.camera.users.has('pc1') && host.camera.users.has('pc2') && host.camera.users.has('call'));
    check('the rest have it', senderTrack(host, 'pc2')?.readyState === 'live'
        && previews.at(-1)?.[1]?.getVideoTracks()[0].readyState === 'live');
}

{
    const { host, previews } = makeHost();
    const release = holdGum();
    void host.command({ op: 'openPreview', pc: 'call' });
    await settle();
    await host.command({ op: 'closePreview', pc: 'call' });
    void host.command({ op: 'openPreview', pc: 'call' });
    release();
    await settle();
    const shown = previews.filter(([, s]) => s);
    check('a preview closed and reopened while opening shows once', shown.length === 1, `${shown.length} shown`);
    check('and holds the camera once', host.camera.users.size === 1 && gum.cameras.filter((t) => t.readyState === 'live').length === 1);
}

{
    const { host, events } = makeHost();
    gum.refuseExact = true;
    await videoPeer(host, 'pc1', 'gone-camera');
    await settle();
    const fb = events('deviceFallback');
    check('a camera that will not open falls back to the default', gum.video === 2 && senderTrack(host, 'pc1')?.readyState === 'live');
    check('and says so', fb.length === 1 && fb[0].pc === 'pc1' && fb[0].kind === 'camera' && fb[0].reason === 'OverconstrainedError',
        JSON.stringify(fb));
}

{
    const { host, events, previews } = makeHost();
    gum.refuse = true;
    await host.command({ op: 'openPreview', pc: 'call' });
    await videoPeer(host, 'pc1');
    await settle();
    const errors = events('error');
    const onPreview = errors.find((e) => e.pc === 'call');
    const onPc = errors.find((e) => e.pc === 'pc1');
    check('a refused camera is a fatal error on the preview',
        onPreview?.op === 'openPreview' && onPreview.fatal === 1, JSON.stringify(onPreview));
    check('and a non-fatal one on a pc', onPc?.op === 'attachVideoSender' && onPc.fatal === 0, JSON.stringify(onPc));
    check('no preview was shown', previews.length === 0);
    check('nobody is left holding it', host.camera.users.size === 0);
    gum.refuse = false;
    await host.command({ op: 'openPreview', pc: 'call' });
    await settle();
    check('a preview refused once can be opened again', previews.at(-1)?.[1]?.getVideoTracks()[0].readyState === 'live');
}

{
    const { host, previews } = makeHost();
    await videoPeer(host, 'pc1');
    await videoPeer(host, 'pc2');
    await host.command({ op: 'openPreview', pc: 'call' });
    await settle();
    const conns = [...host.peers.values()].map((s) => s.conn);
    const clones = ['pc1', 'pc2'].map((pc) => senderTrack(host, pc));
    await host.command({ op: 'close' });
    check('close ends every pc', host.peers.size === 0 && conns.every((c) => c.closed));
    check('every clone', clones.every((t) => t.readyState === 'ended'));
    check('the preview', previews.at(-1)?.[1] === null);
    check('and the camera', gum.cameras[0].readyState === 'ended' && host.camera.users.size === 0);
}

{
    const { host, previews } = makeHost();
    await videoPeer(host, 'pc1');
    await host.command({ op: 'openPreview', pc: 'call' });
    await settle();
    host.closeAll();
    check('closeAll does the same', host.peers.size === 0 && previews.at(-1)?.[1] === null
        && gum.cameras[0].readyState === 'ended');
}

{
    // The answerer as the backend drives it: no addTrack, then attaches
    // under the peer's track names.
    const { host, events } = makeHost();
    await host.command({ op: 'createPeer', pc: 'pc1', sid: 'sid-pc1' });
    await host.command({ op: 'setRemoteDescription', pc: 'pc1', sdpType: 'offer', sdp: 'audio video' });
    await settle();
    const tracks = events('track');
    check('an offer\'s tracks are named', tracks.map((t) => `${t.track}:${t.kind}`).join(' ') === 'remote-0:audio remote-1:video',
        JSON.stringify(tracks));
    const [audio, video] = host.peers.get('pc1').conn.transceivers;
    check('and their m-lines made sendrecv before the answer', audio.direction === 'sendrecv' && video.direction === 'sendrecv');
    await host.command({ op: 'attachAudio', pc: 'pc1', track: 'remote-0' });
    await host.command({ op: 'attachVideoSender', pc: 'pc1', track: 'remote-1' });
    await settle();
    check('the answerer sends its mic on the peer\'s audio m-line', audio.sender.track?.kind === 'audio');
    check('and its camera on the video one', video.sender.track?.source === gum.cameras[0]);
    host.setAudioEnabled('sid-pc1', false);
    await host.command({ op: 'setVideoEnabled', pc: 'pc1', on: 0 });
    await settle();
    check('mute and camera off reach them', audio.sender.track.enabled === false && video.sender.track.enabled === false);
    const sent = [audio.sender.track, video.sender.track];
    await host.command({ op: 'closePeer', pc: 'pc1' });
    check('and closing stops them', sent.every((t) => t.readyState === 'ended') && host.camera.users.size === 0);
}

{
    // A re-offer leaves a recvonly track of ours alone.
    const { host } = makeHost();
    await host.command({ op: 'createPeer', pc: 'pc1', sid: 'sid-pc1' });
    await host.command({ op: 'addTrack', pc: 'pc1', track: 'video', kind: 'video', direction: 'recvonly' });
    await host.command({ op: 'setRemoteDescription', pc: 'pc1', sdpType: 'offer', sdp: '' });
    await settle();
    check('a recvonly track tacky added stays recvonly', host.peers.get('pc1').conn.transceivers[0].direction === 'recvonly');
}

console.log(failures ? `${failures} failed` : 'all passed');
process.exit(failures ? 1 : 0);
