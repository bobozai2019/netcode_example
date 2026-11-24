"""Verify delegated puzzle moves on three independent Windows processes."""

import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import time

from artifacts import ROOT, budget, create_job, job_lock, rotate_run
from verify_yard import Process, require, values


def send(player, line):
    player.proc.stdin.write(line + "\n")
    player.proc.stdin.flush()


def command(player, line, prefix, expected=None):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        start = len(player.lines)
        send(player, line)
        while time.monotonic() < deadline:
            unavailable = line.split()[0] + " unavailable"
            response = next((r for r in player.lines[start:] if r.startswith(prefix) or r == unavailable), None)
            if response is not None:
                record = values(response)
                if response.startswith(prefix) and (
                    expected is None or all(record.get(k) == v for k, v in expected.items())
                ):
                    return record
                break
            if player.proc.poll() is not None:
                raise RuntimeError(f"{player.name} exited while handling {line!r}")
            time.sleep(0.01)
        time.sleep(0.05)
    raise RuntimeError(f"{player.name} missed {line!r}, expected {prefix!r} {expected}: {player.lines[-5:]}")


def show(player, object_id, **expected):
    return command(player, f"show {object_id}", f"view object={object_id} ", expected)


def verify(executable, port, output):
    with ExitStack() as stack:
        def launch(name, role):
            p = Process(output, name, executable, [role, str(port)], interactive=True)
            stack.callback(p.close)
            return p

        a = launch("A", "host")
        a.await_line("listening")
        b = launch("B", "join")
        command(b, "status", "player=", {"player": 2})
        c = launch("C", "join")
        command(c, "status", "player=", {"player": 3})
        command(a, "start", "start ok")
        for peer in (a, b, c):
            show(peer, 1, cell=2, writer=1)
        command(a, "grant 1 2", "grant ok")
        command(a, "grant 2 3", "grant ok")
        show(b, 1, writer=2, epoch=1)
        show(c, 2, writer=3, epoch=1)
        command(b, "mute", "mute ok")
        command(b, "hold", "hold ok")
        command(b, "move 1 5 1", "move ok")
        local = show(b, 1, cell=5, public=2, facing=1, confirmed=0)
        command(a, "protect", "protect ok")
        command(b, "release", "release ok")
        command(c, "move 2 7", "move ok")
        show(a, 1, cell=5, confirmed=1, protected=1)
        show(c, 1, cell=5, protected=1)
        show(c, 2, cell=7, confirmed=1)
        command(b, "unmute", "unmute ok")
        show(b, 1, cell=5, public=5, confirmed=1, protected=1)
        command(b, "hold", "hold ok")
        command(b, "move 1 6 2", "move ok")
        show(b, 1, cell=6, public=5, confirmed=1)
        time.sleep(0.12)
        transfer_at = time.monotonic()
        command(a, "grant 1 3", "grant ok")
        show(c, 1, writer=3, epoch=2, cell=5, facing=1)
        handoff_ms = round((time.monotonic() - transfer_at) * 1000)
        command(c, "move 1 9 3", "move ok")
        show(c, 1, public=9, confirmed=1, protected=1)
        command(b, "release", "release ok")
        a.await_line("old_state object=1 epoch=1")
        show(b, 1, writer=3, epoch=2)
        command(b, "move 1 8 0", "move unavailable")
        final = {
            p.name: {
                "x": show(p, 1, cell=9, public=9, protected=1, facing=3, epoch=2, writer=3),
                "y": show(p, 2, cell=7, public=7, epoch=1, writer=3),
                "traffic": command(p, "traffic", "traffic "),
            }
            for p in (a, b, c)
        }
        command(a, "grant 1 1", "grant ok")
        for p in (a, b, c):
            show(p, 1, cell=9, writer=1, epoch=3)
        command(a, "scene", "scene ok")
        for p in (b, c):
            command(p, "visible 3", "visible object=3", {"present": 1, "scene": 20, "score": 16777217})
        command(a, "scope 2 10", "scope ok")
        command(b, "visible 3", "visible object=3", {"present": 0})
        command(a, "award", "award ok")
        command(c, "visible 3", "visible object=3", {"present": 1, "score": 16777219})
        command(a, "scope 2 20 3", "scope ok")
        command(b, "visible 2", "visible object=2", {"present": 0})
        command(b, "visible 3", "visible object=3", {"present": 0})
        command(b, "loading 20", "loading ok")
        before_return = len(b.lines)
        command(a, "scope 2 20 2 3", "scope ok")
        command(b, "visible 2", "visible object=2", {"present": 1})
        command(b, "visible 3", "visible object=3", {"present": 0})
        command(b, "loaded 20", "loaded ok")
        returned = command(b, "visible 3", "visible object=3", {"present": 1, "score": 16777219})
        on_return = b.lines[before_return:]
        require(on_return.index("ready object=2 scene=0") < on_return.index("ready object=3 scene=20"),
                "Dependent object became ready before its parent")
        require(any("score=16777219 name=South" in line for line in on_return), "Re-entry missed latest string")
        command(a, "classify 3 area 17 8", "classify ok")
        for p in (b, c):
            command(p, "visible 3", "visible object=3", {"present": 0})
        command(a, "subscribe 2 area 17", "subscribe ok")
        command(a, "subscribe 3 user 17", "subscribe ok")
        command(b, "visible 3", "visible object=3", {"present": 1, "score": 16777219})
        command(c, "visible 3", "visible object=3", {"present": 0})
        command(a, "classify 3 user 17 8", "classify ok")
        command(c, "visible 3", "visible object=3", {"present": 1})
        command(b, "visible 3", "visible object=3", {"present": 0})
        command(a, "scope 2 10", "scope ok")
        command(a, "retire", "retire ok")
        command(c, "visible 3", "visible object=3", {"present": 0})
        command(a, "scope 2 20", "scope ok")
        command(b, "visible 1", "visible object=1", {"present": 1})
        command(b, "visible 3", "visible object=3", {"present": 0})
        command(a, "scope 3 20 1", "scope ok")
        command(c, "visible 2", "visible object=2", {"present": 0})
        show(a, 2, cell=7, writer=1, epoch=2)
        command(a, "grant 2 3", "grant unavailable")
        command(a, "scope 3 20", "scope ok")
        show(c, 2, cell=7, writer=1, epoch=2)
        command(b, "claim 1", "claim ok")
        a.await_line("request object=1 requester=2")
        command(c, "claim 1", "claim ok")
        c.await_line("sequence=1 status=2")
        command(a, "allow 1", "allow ok")
        show(b, 1, writer=2, epoch=4)
        command(c, "claim 1", "claim ok")
        b.await_line("request object=1 requester=3")
        command(b, "deny 1", "deny ok")
        c.await_line("sequence=2 status=1")
        command(c, "claim 1", "claim ok")
        command(b, "allow 1", "allow ok")
        show(c, 1, writer=3, epoch=5)
        command(c, "drop 1", "drop ok")
        show(a, 1, writer=1, epoch=6)
        command(c, "claim 2", "claim ok")
        show(a, 2, writer=3, epoch=3)
        watcher = launch("watcher", "watch")
        command(watcher, "status", "player=", {"player": 4, "watching": 1, "round": 1})
        show(watcher, 1, public=9, writer=1)
        command(watcher, "claim 1", "claim ok")
        watcher.await_line("sequence=1 status=4")
        late = launch("late", "join")
        command(late, "status", "player=", {"player": 5, "watching": 0, "round": 1})
        show(late, 2, public=7, writer=3)
        clock = command(late, "clock", "clock ", {"synced": 1})
        host_clock = command(a, "clock", "clock ")
        clock_difference = abs(host_clock["ms"] - clock["ms"])
        require(clock_difference < 250, f"Round clock mismatch {host_clock} {clock}")
        full = launch("full", "join")
        command(full, "status", "player=", {"player": 0, "rejected": 3})
        command(a, "end", "end ok")
        for p in (b, c):
            command(p, "status", "player=", {"ended": 1, "round": 0})
        for p in (a, b, c, late, watcher, full):
            send(p, "quit")
            require(p.proc.wait(timeout=5) == 0, f"{p.name} returned an error")
        return {"local_without_downlink": local, "handoff_observed_ms": handoff_ms, "final": final,
                "interest_reentry": returned, "claim_epoch_after_release": 6, "interest_key_switch": True,
                "late_player": 5, "read_only_spectator": 4, "full_rejection": 3, "clock_difference_ms": clock_difference}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=43270)
    parser.add_argument("--exe", type=Path, default=ROOT / "build/win-x64/Debug/puzzle/Debug/netcode-puzzle.exe")
    args = parser.parse_args()
    if not budget(ROOT, 16 * 1024**2)["allowed"]:
        print("Output budget exceeded")
        return 1
    output = create_job(ROOT, "runs/current", "run")
    ok = False
    with job_lock(output, "run"):
        try:
            summary = json.dumps(verify(args.exe.resolve(), args.port, output), indent=2)
            (output / "metrics.json").write_text(summary, encoding="utf-8")
            print(summary)
            ok = True
        except Exception as error:
            (output / "failure.txt").write_text(str(error), encoding="utf-8")
            print(error)
    print(f"run evidence {rotate_run(ROOT, ok)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
