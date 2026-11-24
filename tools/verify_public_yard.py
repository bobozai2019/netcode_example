"""Exercise the Unity IPv4 forwarding path with two local Windows Players."""

import asyncio
from contextlib import closing, suppress
import json
import socket
from types import SimpleNamespace

from artifacts import ROOT, RUN_LIMIT, budget, create_job, job_lock, rotate_run
from unity_build import UNITY_PLAYER
from verify_yard import execute, require


HOST = "127.0.0.1"
ENTRY = "127.0.0.2"
TRANSLATED_SOURCE = "127.0.0.3"
PORT = 43263


async def copy_stream(reader, writer, record, direction):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()
        record[direction] += len(data)
    writer.write_eof()


async def relay_tcp(guest_reader, guest_writer, sessions):
    host_writer = None
    try:
        host_reader, host_writer = await asyncio.open_connection(
            HOST, PORT, local_addr=(TRANSLATED_SOURCE, 0)
        )
        session = {"guest_port": guest_writer.get_extra_info("peername")[1],
                   "host_facing_port": host_writer.get_extra_info("sockname")[1],
                   "to_host": 0, "to_guest": 0}
        sessions.append(session)
        await asyncio.gather(copy_stream(guest_reader, host_writer, session, "to_host"),
                             copy_stream(host_reader, guest_writer, session, "to_guest"))
    except ConnectionError:
        # The scripted disconnect may close a stream while it is being relayed.
        pass
    finally:
        guest_writer.close()
        if host_writer:
            host_writer.close()


async def relay_udp_replies(entry_socket, upstream, guest, record):
    loop = asyncio.get_running_loop()
    while True:
        try:
            data, sender = await loop.sock_recvfrom(upstream, 65536)
        except ConnectionResetError:
            return
        if sender == (HOST, PORT):
            await loop.sock_sendto(entry_socket, data, guest)
            record["to_guest"] += len(data)


async def relay_udp(entry_socket, sessions):
    loop = asyncio.get_running_loop()
    mappings = {}
    try:
        while True:
            data, guest = await loop.sock_recvfrom(entry_socket, 65536)
            if guest not in mappings:
                upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                upstream.setblocking(False)
                upstream.bind((TRANSLATED_SOURCE, 0))
                session = {"guest_port": guest[1], "host_facing_port": upstream.getsockname()[1],
                           "to_host": 0, "to_guest": 0}
                sessions.append(session)
                replies = asyncio.create_task(relay_udp_replies(entry_socket, upstream, guest, session))
                mappings[guest] = upstream, session, replies
            upstream, session, _ = mappings[guest]
            await loop.sock_sendto(upstream, data, (HOST, PORT))
            session["to_host"] += len(data)
    finally:
        for upstream, _, replies in mappings.values():
            replies.cancel()
            upstream.close()
        await asyncio.gather(*(replies for _, _, replies in mappings.values()), return_exceptions=True)


async def run_case(output, faults):
    tcp_sessions, udp_sessions = [], []
    server = await asyncio.start_server(lambda reader, writer: relay_tcp(reader, writer, tcp_sessions), ENTRY, PORT)
    with closing(socket.socket(socket.AF_INET, socket.SOCK_DGRAM)) as entry_socket:
        async with server:
            entry_socket.setblocking(False)
            entry_socket.bind((ENTRY, PORT))
            udp = asyncio.create_task(relay_udp(entry_socket, udp_sessions))
            try:
                args = SimpleNamespace(mode="play", platform="unity", guest_platform=None, port=PORT,
                                       seconds=10, local_address=HOST, unity_player=UNITY_PLAYER,
                                       fault=faults, capture=True)
                result = await asyncio.to_thread(execute, args, output, join_address=ENTRY)
            finally:
                udp.cancel()
                with suppress(asyncio.CancelledError):
                    await udp
    for lane, sessions in (("TCP", tcp_sessions), ("UDP", udp_sessions)):
        active = [item for item in sessions if item["to_host"] and item["to_guest"]]
        require(len({item["host_facing_port"] for item in active}) >= 2,
                f"Expected bidirectional {lane} traffic on the original connection and the rejoin")
    require(all(item["guest_port"] != item["host_facing_port"] for item in udp_sessions),
            "UDP source port was not translated")
    require(all(tcp["host_facing_port"] != udp["host_facing_port"]
                for tcp in tcp_sessions for udp in udp_sessions), "TCP and UDP source ports must differ")
    result["forwarding"] = {"host": f"{HOST}:{PORT}", "translated_source": TRANSLATED_SOURCE,
                            "tcp": tcp_sessions, "udp": udp_sessions}
    return result


def main():
    require(budget(ROOT, RUN_LIMIT)["allowed"], "Output budget exceeded")
    output = create_job(ROOT, "runs/current", "run")
    passed = False
    with job_lock(output, "run"):
        try:
            for name, faults in (("normal", False), ("fault", True)):
                case = output / name
                case.mkdir()
                result = asyncio.run(run_case(case, faults))
                data = json.dumps(result, indent=2)
                (case / "metrics.json").write_text(data, encoding="utf-8")
                print(data, flush=True)
            passed = True
        except Exception as error:
            (output / "failure.txt").write_text(str(error), encoding="utf-8")
            print(error, flush=True)
    print(f"run evidence {rotate_run(ROOT, passed)}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
