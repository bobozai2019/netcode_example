"""Kill the active player host and verify continuation on the elected standby."""

import argparse
from contextlib import ExitStack
import json
import time

from artifacts import ROOT, budget, create_job, job_lock, rotate_run
from verify_yard import Process, require, values


def verify(output, exe, port, chain=False):
    with ExitStack() as stack:

        def launch(name, role):
            p = Process(output, name, exe, [role, str(port), str(port + 1)] + (["--chain"] if chain else []))
            stack.callback(p.close)
            return p

        a = launch("original", "host")
        a.await_line("migration_open host=1")
        b = launch("successor", "guest")
        b.await_line("migration_member player=2")
        c = launch("survivor", "guest")
        c.await_line("migration_member player=3")
        checkpoint = values(b.await_line("standby_current"))
        c.await_line("term=1 value=77")
        death = time.monotonic()
        a.proc.kill()
        a.proc.wait(timeout=5)
        b.await_line("migrated_host player=2 round=1 writer=3")
        grant = values(c.await_line("migrated_guest player=3"))
        require(grant["epoch"] >= 2, "old authority generation survived")
        b.await_line("migration_pass player=2 term=2 round=1 value=88")
        listing = values(c.await_line("migration_pass player=3 term=2 round=1 value=88"))
        require(listing["directory_port"] == port + 1, "room browser retained the old host endpoint")
        require(
            (listing["piece"], listing["height_mm"], listing["piece_ack"], listing["platform_ack"])
            == (7, 3000, 2, 2),
            "migrated model inputs did not resume independent sequences",
        )
        duration = round((time.monotonic() - death) * 1000)
        handoff = None
        if chain:
            handoff = values(c.await_line("handoff_pass player=3 term=3 restored=89 written=90"))
        for peer in (b, c):
            require(peer.proc.wait(timeout=5) == 0, "survivor failed")
        return {
            "graceful_handoff": handoff,
            "checkpoint_tick": checkpoint["tick"],
            "survivors": [2, 3],
            "term": 2,
            "round": 1,
            "restored_value": 77,
            "next_value": 88,
            "new_epoch": grant["epoch"],
            "directory_port": listing["directory_port"],
            "piece": listing["piece"],
            "platform_mm": listing["height_mm"],
            "model_confirmed": [listing["piece_ack"], listing["platform_ack"]],
            "resume_and_write_ms": duration,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=43490)
    parser.add_argument("--chain", action="store_true", help="The next host hands its last write to the single remaining player")
    args = parser.parse_args()
    if not budget(ROOT, 16 * 1024**2)["allowed"]:
        raise RuntimeError("Output budget exceeded")
    exe = ROOT / "build/win-x64/Debug/puzzle/Debug/netcode-migration.exe"
    output = create_job(ROOT, "runs/current", "run")
    ok = False
    with job_lock(output, "run"):
        try:
            metrics = verify(output, exe, args.port, args.chain)
            content = json.dumps(metrics, indent=2)
            print(content)
            (output / "metrics.json").write_text(content, encoding="utf-8")
            ok = True
        except Exception as exc:
            (output / "failure.txt").write_text(str(exc), encoding="utf-8")
            print(exc)
    print("Run evidence", rotate_run(ROOT, ok))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
