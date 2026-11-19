"""Episode-owned transport to Polyworld's bounded mailbox implementation."""

import os
import subprocess
from typing import Callable, Literal

from pydantic import BaseModel, ConfigDict, Field


class ChatOrder(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    target: int = Field(ge=-2, le=7)
    text: str = Field(max_length=1024)


class ChatMessage(ChatOrder):
    type: Literal["chat"]


class MailboxRead(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    type: Literal["mailbox"]
    count: int = Field(ge=0, le=101)


class MailboxEntry(BaseModel):
    id: int
    text: str


class Mailbox(BaseModel):
    last_id: int = -3
    messages: list[MailboxEntry] = Field(default_factory=list, max_length=100)


class PublicChat(BaseModel):
    tick: int
    player: int
    text: str


class PublicEvent(BaseModel):
    tick: int
    kind: Literal["capture", "victory", "draw"]
    player: int
    target: int
    text: str


class MessageCommand(BaseModel):
    op: Literal["new", "queue", "consume", "flush", "event"]
    names: list[str] = []
    slot: int = 0
    target: int = -2
    text: str = ""
    count: int = Field(default=0, ge=0, le=101)
    turn: int = 0
    kind: Literal["capture", "victory", "draw"] = "capture"


class MailboxUpdate(BaseModel):
    slot: int
    mailbox: Mailbox


class MessageReply(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    accepted: int
    mailboxes: list[MailboxUpdate]
    chats: list[PublicChat]
    events: list[PublicEvent]


class PolicyMessages:
    def __init__(self, names: list[str], record_chat: Callable[[PublicChat], None] | None = None):
        self.process = subprocess.Popen(
            [os.environ.get("GENERALS_BASIC_WORKER", "/usr/local/bin/generals-basic"), "--messages"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        self.chats: list[PublicChat] = []
        self.record_chat = record_chat
        self.recent_chats: list[PublicChat] = []
        self.events: list[PublicEvent] = []
        self.mailboxes = [Mailbox() for _ in names]
        self.command(MessageCommand(op="new", names=names))

    def command(self, command: MessageCommand) -> MessageReply:
        self.process.stdin.write(command.model_dump_json() + "\n")
        self.process.stdin.flush()
        reply = MessageReply.model_validate_json(self.process.stdout.readline())
        for update in reply.mailboxes:
            self.mailboxes[update.slot] = update.mailbox
        # Native replays append admitted public chat directly to their action stream.
        # The separately selectable JAX renderer retains its own JSON history.
        if self.record_chat is not None:
            for chat in reply.chats:
                self.record_chat(chat)
        else:
            self.chats.extend(reply.chats[:16384 - len(self.chats)])
        self.recent_chats = (self.recent_chats + reply.chats)[-128:]
        self.events = (self.events + reply.events)[-128:]
        return reply

    def close(self):
        self.process.stdin.close()
        self.process.stdout.close()
        if self.process.wait(timeout=5):
            raise RuntimeError("Polyworld mailbox broker failed")
