"""
Smoke test: encrypt a "ping" to the OMEMO echo bot, await the encrypted
reply, decrypt it, assert plaintext round-trip.

Configuration is read from environment variables:

    TESTER_JID, TESTER_PASSWORD - account to log in as
    BOT_JID                     - JID of the echo bot to message
    XMPP_HOST, XMPP_PORT        - server address
    CA_PATH                     - path to the CA cert that signs the server's cert

Exits 0 on success, non-zero on any failure (including the 30s overall timeout).
"""

import asyncio
import logging
import os
import sys
import traceback
from typing import Any, Dict, FrozenSet, Optional

from omemo.storage import Just, Maybe, Nothing, Storage
from omemo.types import DeviceInformation, JSONType

from slixmpp.clientxmpp import ClientXMPP
from slixmpp.jid import JID
from slixmpp.plugins import register_plugin  # type: ignore[attr-defined]
from slixmpp.stanza import Message
from slixmpp.xmlstream.handler import CoroutineCallback
from slixmpp.xmlstream.matcher import MatchXPath

from slixmpp_omemo import TrustLevel, XEP_0384


PING = "ping"
OVERALL_TIMEOUT_SECONDS = 30.0

log = logging.getLogger("omemo_smoke")


class StorageImpl(Storage):
    def __init__(self) -> None:
        super().__init__()
        self.__data: Dict[str, JSONType] = {}

    async def _load(self, key: str) -> Maybe[JSONType]:
        if key in self.__data:
            return Just(self.__data[key])
        return Nothing()

    async def _store(self, key: str, value: JSONType) -> None:
        self.__data[key] = value

    async def _delete(self, key: str) -> None:
        self.__data.pop(key, None)


class XEP_0384Impl(XEP_0384):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.__storage: Storage

    def plugin_init(self) -> None:
        self.__storage = StorageImpl()
        super().plugin_init()

    @property
    def storage(self) -> Storage:
        return self.__storage

    @property
    def _btbv_enabled(self) -> bool:
        return True

    async def _devices_blindly_trusted(
        self,
        blindly_trusted: FrozenSet[DeviceInformation],
        identifier: Optional[str],
    ) -> None:
        log.info("[%s] devices blindly trusted: %s", identifier, blindly_trusted)

    async def _prompt_manual_trust(
        self,
        manually_trusted: FrozenSet[DeviceInformation],
        identifier: Optional[str],
    ) -> None:
        session_manager = await self.get_session_manager()
        for device in manually_trusted:
            await session_manager.set_trust(
                device.bare_jid,
                device.identity_key,
                TrustLevel.TRUSTED.value,
            )


register_plugin(XEP_0384Impl)


class SmokeClient(ClientXMPP):
    def __init__(self, jid: str, password: str, bot_jid: str) -> None:
        super().__init__(jid, password)
        self.bot_jid = JID(bot_jid)
        self.reply_future: "asyncio.Future[str]" = asyncio.get_event_loop().create_future()
        self.add_event_handler("session_start", self._on_session_start)
        self.register_handler(CoroutineCallback(
            "Messages",
            MatchXPath(f"{{{self.default_ns}}}message"),
            self._on_message,
        ))

    async def _on_session_start(self, _event: Any) -> None:
        self.send_presence()
        self.get_roster()
        xep_0384: XEP_0384 = self["xep_0384"]
        session_manager = await xep_0384.get_session_manager()
        # Fetch the bot's devicelist explicitly: PEP+ pushes may not have
        # arrived yet when we initiate the first send.
        await session_manager.refresh_device_lists(self.bot_jid.bare)
        await self._send_encrypted_ping()

    async def _send_encrypted_ping(self) -> None:
        xep_0384: XEP_0384 = self["xep_0384"]
        msg = self.make_message(mto=self.bot_jid, mtype="chat")
        msg["body"] = PING
        msg.set_to(self.bot_jid)
        msg.set_from(self.boundjid)

        messages, encryption_errors = await xep_0384.encrypt_message(msg, self.bot_jid)
        if encryption_errors:
            log.warning("non-critical encryption errors: %s", encryption_errors)

        for namespace, message in messages.items():
            message["eme"]["namespace"] = namespace
            message["eme"]["name"] = self["xep_0380"].mechanisms[namespace]
            message.send()
        log.info("sent encrypted '%s' to %s", PING, self.bot_jid)

    async def _on_message(self, stanza: Message) -> None:
        xep_0384: XEP_0384 = self["xep_0384"]
        if stanza["type"] not in {"chat", "normal"}:
            return
        if xep_0384.is_encrypted(stanza) is None:
            return
        try:
            plaintext, _device_info = await xep_0384.decrypt_message(stanza)
        except Exception:
            if not self.reply_future.done():
                self.reply_future.set_exception(
                    RuntimeError(f"decrypt failed:\n{traceback.format_exc()}")
                )
            return

        # Skip oldmemo empty key-transport messages (no <payload> element);
        # python-omemo emits one to "complete" a freshly-established session.
        body = plaintext["body"]
        if body == "":
            return
        if not self.reply_future.done():
            self.reply_future.set_result(body)


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"FATAL: env var {name} is required", file=sys.stderr)
        sys.exit(2)
    return value


async def run() -> int:
    jid = _required_env("TESTER_JID")
    password = _required_env("TESTER_PASSWORD")
    bot_jid = _required_env("BOT_JID")
    host = _required_env("XMPP_HOST")
    port = int(os.environ.get("XMPP_PORT", "5222"))
    ca_path = _required_env("CA_PATH")

    xmpp = SmokeClient(jid, password, bot_jid)
    xmpp.register_plugin("xep_0380")
    xmpp.register_plugin("xep_0384", module=sys.modules[__name__])
    xmpp.ca_certs = ca_path

    xmpp.connect((host, port), force_starttls=True)

    try:
        reply_body = await asyncio.wait_for(xmpp.reply_future, OVERALL_TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        print(
            f"FAIL: no reply within {OVERALL_TIMEOUT_SECONDS:.0f}s",
            file=sys.stderr,
        )
        return 1
    finally:
        xmpp.disconnect()

    if reply_body != PING:
        print(f"FAIL: expected {PING!r}, got {reply_body!r}", file=sys.stderr)
        return 1

    print(f"OK: round-trip {PING!r} decrypted match")
    return 0


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    sys.exit(asyncio.get_event_loop().run_until_complete(run()))


if __name__ == "__main__":
    main()
