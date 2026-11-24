"""Check authoritative group snapshots and native fixed-step replay in separate local players."""
import argparse
from contextlib import ExitStack
import json
import re
from artifacts import ROOT, budget, create_job, job_lock, rotate_run
from godot_build import GODOT_PROJECT, resolve_godot
from unity_build import UNITY_PLAYER
from verify_yard import BUILD, Process, require


def play(output, host_engine, guest_engine, port, allow_reset=False):
    with ExitStack() as stack:
        peers = []
        for role,engine in (("host",host_engine),("join",guest_engine)):
            args = ["--puzzle-"+role, "--physics-island", "--port", str(port)]
            if allow_reset: args.append("--authority-reset")
            if engine == "cocos":
                exe = BUILD / "netcode-puzzle-cocos.exe"
                args = ["--headless", *args]
            elif engine == "godot":
                exe = resolve_godot()
                args = ["--headless","--path",str(GODOT_PROJECT),"res://verification/physics/island.tscn","--",*args]
            else:
                exe = UNITY_PLAYER
                args = ["-batchmode","-nographics","-logFile","-","--",*args]
            p = Process(output, f"{host_engine}-{guest_engine}-{role}", exe, args)
            stack.callback(p.close)
            p.await_line("island_open",seconds=40)
            peers.append(p)
        line = peers[1].await_line("island_pass",seconds=20)
        peers[0].await_line("island_confirmed")
        for p in peers: require(p.proc.wait(timeout=10)==0, "physics player failed")
        metrics = {key: float(value) for key, value in re.findall(
            r"(\w+)=([-+]?[0-9]+(?:\.[0-9]*)?(?:[eE][-+]?[0-9]+)?)", line)}
        require(metrics.get("bodies")==4 and metrics.get("checkpoint")==45 and metrics.get("steps")==25,
                "Incomplete group replay result")
        reset = metrics["reset"]
        require(reset in (0, 1) and (allow_reset or not reset), "Unexpected baseline reset")
        if reset:
            require(metrics["after_mm"] >= 59.99 and metrics["final_mm"] < 1, "Invalid authority reset")
        else:
            require(metrics["after_mm"] <= 60 and abs(metrics["final_mm"]-metrics["after_mm"]) < .02,
                    "Replay exceeded tolerance")
        return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port",type=int,default=43620)
    parser.add_argument("--engine", choices=["all","godot","unity","cocos"], default="all")
    parser.add_argument("--guest-engine", choices=["godot","unity","cocos"], help="Use a different solver for replay")
    parser.add_argument("--matrix", action="store_true", help="Run all nine host/guest combinations")
    parser.add_argument("--authority-reset", action="store_true", help="Restore the latest group when replay error reaches 60 mm")
    args=parser.parse_args()
    if args.matrix and (args.engine != "all" or args.guest_engine):
        parser.error("--matrix selects all hosts and guests")
    if not budget(ROOT,32*1024**2)["allowed"]: raise RuntimeError("Output budget exceeded")
    output=create_job(ROOT,"runs/current","run")
    ok=False
    with job_lock(output,"run"):
        try:
            engines = ["godot","unity","cocos"] if args.engine=="all" else [args.engine]
            metrics = {}
            for host in engines:
                guests = engines if args.matrix else [args.guest_engine or host]
                for guest in guests:
                    metrics[f"{host}-{guest}"] = play(output, host, guest, args.port+len(metrics), args.authority_reset)
            content=json.dumps(metrics,indent=2)
            (output/"metrics.json").write_text(content,encoding="utf-8")
            print(content)
            ok=True
        except Exception as e:
            (output/"failure.txt").write_text(str(e),encoding="utf-8")
            print(e)
    print("Run evidence",rotate_run(ROOT,ok))
    return 0 if ok else 1


if __name__=="__main__":
    raise SystemExit(main())
