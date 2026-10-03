// The browser's WebSocket for lib/taco/modules/browserws.tcl, reached through
// zippy's ::em::call. Linked with --pre-js, like http.js.
//
//   tackyWsOpen(name, url, protocol..., ctx)   resolves "code {reason}" on close
//   tackyWsSend(name, text)                    throws unless the socket is open
//   tackyWsClose(name, code, reason)
//
// While open, events come as ctx.progress: connect <subprotocol>,
// text <message>, error <message>. Cancelling the open call closes the socket.

Module.zippyCalls = Module.zippyCalls || {};
const tackyWs = {};

Module.zippyCalls.tackyWsOpen = (name, url, ...rest) => {
    const ctx = rest.pop();
    return new Promise((resolve) => {
        let ws;
        try {
            ws = new WebSocket(url, rest);
        } catch (err) {
            resolve(`1006 {${String(err).replace(/[{}\\]/g, '')}}`);
            return;
        }
        ws.binaryType = 'arraybuffer';
        tackyWs[name] = ws;
        ws.onopen = () => ctx.progress('connect', ws.protocol);
        ws.onmessage = (ev) => ctx.progress('text', typeof ev.data === 'string'
            ? ev.data : new TextDecoder().decode(ev.data));
        ws.onerror = () => ctx.progress('error', 'websocket error');
        ws.onclose = (ev) => {
            delete tackyWs[name];
            resolve(`${ev.code} {${String(ev.reason).replace(/[{}\\]/g, '')}}`);
        };
        ctx.signal.addEventListener('abort', () => {
            delete tackyWs[name];
            ws.onopen = ws.onmessage = ws.onerror = ws.onclose = null;
            try { ws.close(1000); } catch (err) { /* already closing */ }
        });
    });
};

Module.zippyCalls.tackyWsSend = (name, text) => {
    const ws = tackyWs[name];
    if (!ws || ws.readyState !== 1) throw new Error('websocket not open');
    ws.send(text);
    return text.length;
};

Module.zippyCalls.tackyWsClose = (name, code, reason) => {
    const ws = tackyWs[name];
    if (ws) ws.close(Number(code) || 1000, reason);
};
