"""
OMEMO echo bot.

Adapted from https://github.com/Syndace/slixmpp-omemo/blob/main/examples/echo_client.py
via ~/.local/src/picomemo/test/bot-omemo.py.

slixmpp_omemo 1.0.0 only wires the oldmemo backend into its SessionManager
(see xep_0384.py:482-486), so this bot publishes a devicelist under the
eu.siacs.conversations.axolotl namespace and never under urn:xmpp:omemo:2.

Configuration is read from environment variables so the same image can run
in different harnesses:

    BOT_JID, BOT_PASSWORD     - account to log in as
    XMPP_HOST, XMPP_PORT      - server address (resolvable from the container)
    CA_PATH                   - path to the CA cert that signs the server's cert
"""

import asyncio
import logging
import os
import sys
import traceback
from typing import Any, Dict, FrozenSet, Literal, Optional, Union

from omemo.storage import Just, Maybe, Nothing, Storage
from omemo.types import DeviceInformation, JSONType

from slixmpp.clientxmpp import ClientXMPP
from slixmpp.jid import JID
from slixmpp.plugins import register_plugin  # type: ignore[attr-defined]
from slixmpp.stanza import Message
from slixmpp.xmlstream.handler import CoroutineCallback
from slixmpp.xmlstream.matcher import MatchXPath

from slixmpp_omemo import TrustLevel, XEP_0384


log = logging.getLogger("omemo_bot")


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


class OmemoEchoBot(ClientXMPP):
    def __init__(self, jid: str, password: str) -> None:
        super().__init__(jid, password)
        self.add_event_handler("session_start", self._on_session_start)
        self.register_handler(CoroutineCallback(
            "Messages",
            MatchXPath(f"{{{self.default_ns}}}message"),
            self._on_message,
        ))

    async def _on_session_start(self, _event: Any) -> None:
        self.send_presence()
        self.get_roster()
        # get_session_manager() resolves once slixmpp_omemo has set up the
        # SessionManager and published our devicelist/bundle to PEP. That is
        # exactly the readiness signal the harness probes for.
        try:
            await self["xep_0384"].get_session_manager()
        except Exception:
            log.error("session manager init failed:\n%s", traceback.format_exc())
            return
        log.info("OMEMO bot online")

    async def _on_message(self, stanza: Message) -> None:
        xep_0384: XEP_0384 = self["xep_0384"]
        mto = stanza["from"]
        mtype = stanza["type"]
        log.info("RX message from=%s type=%s", mto, mtype)
        if mtype not in {"chat", "normal"}:
            log.info("  skip: type not in chat/normal")
            return

        namespace = xep_0384.is_encrypted(stanza)
        log.info("  encrypted ns=%s", namespace)
        if namespace is None:
            return

        try:
            plaintext, _device_info = await xep_0384.decrypt_message(stanza)
        except Exception:
            log.error("decrypt failed:\n%s", traceback.format_exc())
            return

        try:
            await self._encrypted_reply(mto, mtype, plaintext)
        except Exception:
            log.error("encrypted reply failed:\n%s", traceback.format_exc())

    async def _encrypted_reply(
        self,
        mto: JID,
        mtype: Literal["chat", "normal"],
        reply: Union[Message, str],
    ) -> None:
        xep_0384: XEP_0384 = self["xep_0384"]
        if isinstance(reply, str):
            body = reply
            reply = self.make_message(mto=mto, mtype=mtype)
            reply["body"] = body

        log.info("echo: %s", reply["body"])

        reply.set_to(mto)
        reply.set_from(self.boundjid)

        messages, encryption_errors = await xep_0384.encrypt_message(reply, mto)
        if encryption_errors:
            log.info("non-critical encryption errors: %s", encryption_errors)

        for namespace, message in messages.items():
            message["eme"]["namespace"] = namespace
            message["eme"]["name"] = self["xep_0380"].mechanisms[namespace]
            message.send()


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"FATAL: env var {name} is required", file=sys.stderr)
        sys.exit(2)
    return value


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stdout,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    jid = _required_env("BOT_JID")
    password = _required_env("BOT_PASSWORD")
    host = _required_env("XMPP_HOST")
    port = int(os.environ.get("XMPP_PORT", "5222"))
    ca_path = _required_env("CA_PATH")

    xmpp = OmemoEchoBot(jid, password)
    xmpp.register_plugin("xep_0380")
    xmpp.register_plugin("xep_0384", module=sys.modules[__name__])
    xmpp.ca_certs = ca_path

    xmpp.connect((host, port), force_starttls=True)
    asyncio.get_event_loop().run_forever()


if __name__ == "__main__":
    main()
