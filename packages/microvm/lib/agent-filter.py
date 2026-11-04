# cspell:ignore AGENTC SSHS SSHSIG
"""Pass Git's SSH signatures from the guest door to one ssh-agent socket.

The guest connection is stdin/stdout; the agent socket is argv[1]. Only
SSH_AGENTC_REQUEST_IDENTITIES and SSH_AGENTC_SIGN_REQUEST whose data is an
SSHSIG envelope (what `ssh-keygen -Y sign` asks Git's signatures for) reach
the agent. Every other request, including adding, removing or locking keys,
extensions and sign requests over any other data, gets SSH_AGENT_FAILURE
without contacting the agent. Refusals go to stderr, the launcher's door log.

An SSH user-authentication signature (RFC 4252 section 7) signs data that
starts with the session identifier as an SSH string: a uint32 length, then a
hash. Read as a length, "SSHS" is 0x53534853, about 1.4 GB, while session
identifiers are hash outputs of at most 64 bytes, so a login challenge can
never begin with the SSHSIG magic.
"""

import os
import socket
import struct
import sys

FAILURE = 5
REQUEST_IDENTITIES = 11
SIGN_REQUEST = 13
# OpenSSH's own agent message cap (AGENT_MAX_LEN).
MAX_LENGTH = 256 * 1024
MAGIC = b"SSHSIG"


def log(message):
    print(f"sandbox-agent-filter: {message}", file=sys.stderr, flush=True)


def read_exact(fd, count):
    data = b""
    while len(data) < count:
        chunk = os.read(fd, count - len(data))
        if not chunk:
            return None if not data else data
        data += chunk
    return data


def read_message(fd, source):
    header = read_exact(fd, 4)
    if header is None:
        return None
    if len(header) != 4:
        raise ValueError(f"truncated length from {source}")
    (length,) = struct.unpack(">I", header)
    if length < 1 or length > MAX_LENGTH:
        raise ValueError(f"message length {length} from {source} outside 1..{MAX_LENGTH}")
    body = read_exact(fd, length)
    if body is None or len(body) != length:
        raise ValueError(f"truncated message from {source}")
    return body


def write_message(fd, body):
    data = struct.pack(">I", len(body)) + body
    while data:
        data = data[os.write(fd, data):]


def string_at(body, offset):
    if offset + 4 > len(body):
        raise ValueError("truncated string length")
    (length,) = struct.unpack_from(">I", body, offset)
    end = offset + 4 + length
    if end > len(body):
        raise ValueError("truncated string")
    return body[offset + 4:end], end


def sign_data(body):
    """Return the data of a well-formed sign request: string key, string data, uint32 flags."""
    _, offset = string_at(body, 1)
    data, offset = string_at(body, offset)
    if offset + 4 != len(body):
        raise ValueError("sign request is not key, data and flags")
    return data


def allowed(body):
    kind = body[0]
    if kind == REQUEST_IDENTITIES:
        if len(body) != 1:
            raise ValueError("identities request carries a payload")
        return True
    if kind == SIGN_REQUEST:
        if sign_data(body).startswith(MAGIC):
            return True
        log("refused a sign request whose data is not an SSHSIG envelope")
        return False
    log(f"refused agent message type {kind}")
    return False


def main():
    if len(sys.argv) != 2 or not sys.argv[1].startswith("/"):
        log("usage: agent-filter.py <absolute agent socket>")
        return 2
    guest_in, guest_out = sys.stdin.fileno(), sys.stdout.fileno()
    agent = None
    try:
        while (request := read_message(guest_in, "guest")) is not None:
            if not allowed(request):
                write_message(guest_out, bytes([FAILURE]))
                continue
            if agent is None:
                agent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                agent.connect(sys.argv[1])
            write_message(agent.fileno(), request)
            reply = read_message(agent.fileno(), "agent")
            if reply is None:
                raise ValueError("agent closed the connection")
            write_message(guest_out, reply)
    except (OSError, ValueError) as error:
        log(f"closed the connection: {error}")
        return 1
    finally:
        if agent is not None:
            agent.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
