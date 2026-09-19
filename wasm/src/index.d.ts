// The surface of dist/wasm. A change here is a version bump in package.json.
// Frames are the JSON protocol in doc/DOC.md, typed loosely: the backend
// defines them, not this package.

/** `["module","method",{args}]`, with a token as a fourth element for a reply. */
export type OutboundFrame = [module: string, method: string, args: Record<string, unknown>, token?: number];

/** `["result",token,data]`, `["error",token,message]` or `["event",module,name,{args}]`. */
export type InboundFrame =
    | ['result', number, unknown]
    | ['error', number, string]
    | ['event', string, string, Record<string, unknown>];

/** Where the backend keeps its store, as the worker chose it. */
export type StorageMode = 'opfs' | 'idbfs' | 'memory';

export interface ClientOptions {
    /** The XMPP endpoint, when the server does not follow `wss://$host/xmpp-websocket`. */
    ws?: string;
    /** Keep the store in memory whatever the browser offers. */
    transient?: boolean;
    /** Where the store lives in the backend's filesystem. Default `/store`. */
    store?: string;
    /** A jlog level (`debug`, `info`, ...) for the backend's own log. */
    debug?: string;
    /** Every frame the backend sends, as it arrives. Also settable afterwards. */
    onEvent?: (frame: InboundFrame) => void;
    /** The Worker script, if it is not the worker.js beside index.js. */
    worker?: URL | string;
}

export interface Client {
    /** Settles `true` once the backend is up, `false` if it could not start (see `fatal`). */
    readonly ready: Promise<boolean>;
    /** Why it could not start, or why it died; null while it runs. */
    fatal: string | null;
    /** The store the worker chose; null before it said. */
    storage: StorageMode | null;
    /** True once a `stop` finished cleanly. */
    stopped: boolean;
    /** Every frame the backend sends, as it arrives. */
    onEvent: ((frame: InboundFrame) => void) | null;

    /** Post one frame. A request with a token is answered through `onEvent` and `until`. */
    send(frame: OutboundFrame): void;
    /** Send a request (token chosen here) and wait for its reply, or null after `ms` (30 s). */
    request(frame: OutboundFrame, ms?: number): Promise<InboundFrame | null>;
    /** Wait for an event of `module` and `name` whose args satisfy `match`, or null after `ms`. */
    event(
        module: string,
        name: string,
        match?: (args: Record<string, unknown>) => boolean,
        ms?: number,
    ): Promise<InboundFrame | null>;
    /** Wait for a frame `want` accepts, looking back over recent ones first, or null after `ms`. */
    until(want: (frame: InboundFrame) => boolean, ms?: number): Promise<InboundFrame | null>;
    /** Shut down, wait up to `ms` (15 s), terminate the worker; true if the stop was clean. */
    stop(ms?: number): Promise<boolean>;

    /** The Worker itself, for a page that wants to listen to it directly. */
    readonly worker: Worker;
    /** The most recent frames, bounded; what `until` looks back over. */
    readonly messages: InboundFrame[];
}

/** Start a backend in a Web Worker. */
export function createClient(options?: ClientOptions): Client;

/** Add an account and wait for its session to be up: the `conn <State>` frame, or null. */
export function connect(client: Client, jid: string, password: string, ms?: number): Promise<InboundFrame | null>;

export interface MediaHostOptions {
    /** Post one frame to the backend: the `media hostEvent` requests this makes. */
    send: (frame: OutboundFrame) => void;
    /** A peer's media arrived on call `sid`; `kind` is `audio` or `video`. */
    onRemoteStream?: (sid: string, stream: MediaStream, kind: string) => void;
    /** This side's mic or camera is on the call `sid`, for a self-view. */
    onLocalStream?: (sid: string, stream: MediaStream, kind: string) => void;
    /** Where to say what went wrong; the same is reported to the backend. */
    log?: (line: string) => void;
}

/** The arguments of one `media <HostCommand>` event: `op`, `pc`, and the op's own keys. */
export type HostCommand = { op: string; pc?: string } & Record<string, unknown>;

export interface MediaHost {
    /** Carry out one command from the backend. Never throws; failures go back as `error` events. */
    command(args: HostCommand): Promise<void>;
    /** Mute (`false`) or unmute the mic on a call; false if the call has no pc here. */
    setAudioEnabled(sid: string, on: boolean): boolean;
    /** Close every peer connection. */
    closeAll(): void;
    /** Live peer connections by pc. Not contract. */
    readonly peers: Map<string, { conn: RTCPeerConnection; sid: string }>;
}

/** An RTCPeerConnection per pc the backend names; feed it every `media <HostCommand>`. */
export function createMediaHost(options: MediaHostOptions): MediaHost;
