"""Drive independent Godot FPS processes from the ordinary lobby and input entry points."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import time

from artifacts import ROOT, budget, create_job, job_lock, remove_owned, rotate_run
from godot_build import REPO, console_godot, resolve_godot
from prepare_godot_fps import SOURCE, prepare


class Peer:
    def __init__(self, name, project, work, godot, visible=False):
        self.name = name
        self.folder = work / name
        self.folder.mkdir()
        self.sequence = 0
        self.process = subprocess.Popen(
            [godot, *([] if visible else ["--headless"]), "--path", project, "--max-fps", "60",
             "--log-file", self.folder / "godot.log"],
            env={**os.environ, "SHIFTLINE_PROBE": str(self.folder)},
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

    def ask(self, op="snapshot", **params):
        self.sequence += 1
        inbox = self.folder / "command.json"
        partial = inbox.with_suffix(".tmp")
        partial.write_text(json.dumps({"id": self.sequence, "op": op, **params}), encoding="utf-8")
        partial.replace(inbox)
        reply = self.folder / f"answer-{self.sequence}.json"
        return until(lambda: self.answer(reply), 8, f"{self.name} {op}")

    def answer(self, path):
        if path.exists():
            try:
                result = json.loads(path.read_text(encoding="utf-8"))
                path.unlink()
            except (json.JSONDecodeError, FileNotFoundError, PermissionError):
                return None
            return result
        if self.process.poll() is not None:
            raise RuntimeError(f"{self.name} exited ({self.process.returncode})\n{self.log()}")
        return None

    def open(self, port, host=False, address="127.0.0.1"):
        return self.ask("open", nickname=self.name, host=host, port=port, address=address)

    def log(self):
        path = self.folder / "godot.log"
        return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""

    def stop(self, abrupt=False):
        if self.process.poll() is None:
            if not abrupt:
                self.ask("quit")
            else:
                self.process.kill()
            self.process.wait(timeout=6)

    def press(self, action, pressed=True):
        return self.ask("action", action=action, pressed=pressed)

    def tap(self, action):
        return self.ask("tap", action=action)

    def aim(self, direction):
        self.ask("aim", direction=direction)

    def place(self, player, position):
        self.ask("place", player=player, position=position)


def until(fn, timeout, label):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.035)
    raise AssertionError(f"Timed out: {label}")


def wait(peer, condition, label, timeout=12):
    def check():
        state = peer.ask()
        return state if condition(state) else None
    try:
        return until(check, timeout, f"{peer.name}: {label}")
    except AssertionError as error:
        raise AssertionError(f"{error}\nLast state: {peer.ask()}\n{peer.log()[-3500:]}") from error


def local(state):
    return member(state, state["id"])


def member(state, identity):
    return next((player for player in state.get("players", []) if player["id"] == identity), {})


def port_number():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Run:
    def __init__(self, work, project, godot, address, visible):
        self.work, self.project, self.godot = work, project, godot
        self.address, self.visible = address, visible
        self.peers = []

    def peer(self, name, visible=None):
        peer = Peer(name, self.project, self.work, self.godot, self.visible if visible is None else visible)
        self.peers.append(peer)
        return peer

    def start(self, name, port, host=False, visible=None):
        peer = self.peer(name, visible)
        peer.open(port, host, self.address)
        wait(peer, lambda s: s["ready"], "entered match")
        return peer

    def snapshot_image(self, peer, name, require_flash=False):
        if self.visible:
            result = peer.ask("capture", name=name, require_flash=require_flash)
            assert result["image"] == 0 and (not require_flash or result["captured_flash"])

    def walk(self, peer, x, z, test=None, direction=None, timeout=12):
        peer.ask("resume")
        if direction is None:
            here = local(peer.ask())["position"]
            direction = [x - here[0], 0, z - here[2]]
        peer.aim(direction)
        peer.press("walk_forward")
        try:
            return wait(peer, test or (lambda s: math.dist(
                [local(s)["position"][i] for i in (0, 2)], [x, z]) < 0.48), f"walk to {x}, {z}", timeout)
        finally:
            peer.press("walk_forward", False)

    def arena(self):
        port = port_number()
        host = self.start("MapHost", port, True)
        guest = self.start("MapGuest", port)
        for peer in (host, guest):
            state = peer.ask()
            sx = 1 if local(state)["team"] else -1
            self.walk(peer, sx * 21.7, 3.0)
            self.walk(peer, sx * 21.7, 11.25)
            self.walk(peer, sx * 17.45, 11.25)
            self.walk(peer, sx * 17.45, 2.6)
            self.walk(peer, sx * 19.5, 0)
            self.walk(peer, sx * 19.5, -11.25, lambda s: local(s)["position"][1] > 3.25 and local(s)["position"][2] < -10.3)
            self.walk(peer, sx * 11.0, -11.0, lambda s: abs(local(s)["position"][0] - sx * 11.0) < .62
                      and abs(local(s)["position"][2] + 11.0) < .62)
            self.walk(peer, sx * 11.0, -9.0, lambda s: local(s)["position"][1] < 0.2,
                      direction=[0, 0, 1], timeout=7)
            self.walk(peer, sx * 11.0, -10.0,
                      lambda s: local(s)["position"][1] > 3.23 and local(s)["position"][2] < -9.5,
                      direction=[0, 0, -1], timeout=7)
            peer.press("duck")
            wait(peer, lambda s: local(s)["pose"] == 2, "crouched")
            peer.press("duck", False)
        host.ask("resume")
        host.aim([1, -0.05, 0])
        self.snapshot_image(host, "catwalk")
        print("G2 map pass: both teams walked through dispatch rooms, up stairs, down and back up ladders, and crouched", flush=True)
        host.stop()
        guest.stop()

    def gameplay(self):
        port = port_number()
        host = self.start("Tide", port, True)
        guest = self.start("Ember", port)
        h = host.ask()["id"]
        b = guest.ask()["id"]
        host.ask("resume")
        guest.ask("resume")
        self.snapshot_image(host, "first-person")
        rig = guest.ask("inspect_bones")
        assert rig["arm_bones"] == 50 and math.dist(rig["wrist.l"], rig["wrist.r"]) > 0.15

        def duel():
            host.place(h, [-2, 0.035, 11.5])
            host.place(b, [2, 0.035, 11.5])
            guest.aim([-1, 0, 0])
            host.aim([1, 0, 0])
            wait(guest, lambda s: abs(local(s)["position"][0] - 2) < .1, "duel baseline")

        duel()
        self.snapshot_image(guest, "opponent")
        guest.press("fire")
        dead = wait(host, lambda s: not local(s)["alive"], "guest defeated host")
        guest.press("fire", False)
        assert dead["scores"] == [0, 1] and member(dead, b)["kills"] == 1
        due = local(dead)["respawn_at"]
        life = local(dead)["life"]
        wait(guest, lambda s: member(s, h)["animation"] == "Death", "remote death animation")
        alive = wait(host, lambda s: local(s)["life"] > life and str(h) in s["respawn_lateness"], "host respawn", timeout=5)
        late_by = alive["respawn_lateness"][str(h)]
        assert 0 <= late_by <= 0.020, late_by
        wait(guest, lambda s: member(s, h)["alive"], "remote respawn")
        print(f"V4 first kill: due {due:.3f}, host respawn delay {late_by * 1000:.2f} ms, guest kills 1", flush=True)

        guest.aim([0, 0.1, 1])
        guest.press("fire")
        wait(guest, lambda s: local(s)["mag"] == 0, "magazine exhausted")
        count = host.ask()["shots"]
        time.sleep(0.36)
        assert host.ask()["shots"] == count
        guest.press("fire", False)
        host.place(h, [-1, 0.035, 11.5])
        host.place(b, [1.7, 0.035, 11.5])
        host.aim([1, -0.055, 0])
        wait(guest, lambda s: abs(local(s)["position"][0] - 1.7) < .1, "two visible reload positions")
        guest.tap("reload")
        wait(guest, lambda s: local(s)["action"] == 2, "local reload animation")
        wait(host, lambda s: member(s, b)["action"] == 2, "remote reload action")
        wait(guest, lambda s: 0.7 < local(s)["until"] - s["time"] < 1.25, "magazine removed")
        self.snapshot_image(guest, "viewmodel-reload")
        self.snapshot_image(host, "soldier-reload")
        wait(guest, lambda s: local(s)["mag"] == 30 and local(s)["reserve"] == 60, "reload completed")
        guest.tap("fire")
        wait(guest, lambda s: local(s)["mag"] == 29, "rifle fired after reload")

        host.place(h, [-5, 0.035, -5])
        host.place(b, [-3, 0.035, -5])
        wait(guest, lambda s: abs(local(s)["position"][0] + 3) < .1, "contested supply placement")
        before = host.ask()
        with ThreadPoolExecutor(max_workers=2) as workers:
            for job in (workers.submit(host.tap, "pickup"), workers.submit(guest.tap, "pickup")):
                job.result()
        taken = wait(host, lambda s: not s["pickups"][0][1], "ammo pickup")
        assert sum(x["reserve"] for x in taken["players"]) == sum(x["reserve"] for x in before["players"]) + 45
        host.place(b, [0, 0.035, 3.8])
        wait(guest, lambda s: abs(local(s)["position"][2] - 3.8) < .1, "grenade supply placement")
        guest.tap("pickup")
        wait(host, lambda s: not s["pickups"][2][1] and member(s, b)["grenades"] == 2, "grenade pickup")
        host.place(b, [0, 0.035, 2.5])
        guest.aim([0, -0.24, -1])
        guest.press("fire")
        wait(host, lambda s: s["crates"][0] == [True, 0, 0], "crate broke and collision disabled")
        guest.press("fire", False)

        late = self.peer("Late", False)
        guest.aim([0, 0.13, 1])
        guest.tap("throw")
        flying = wait(host, lambda s: len(s["throws"]) == 1, "dynamic grenade spawned")
        if self.visible:
            eye = local(flying)["position"]
            eye[1] += 1.57
            point = flying["throws"][0][0]
            host.aim([p - q for p, q in zip(point, eye)])
        self.snapshot_image(host, "grenade-flight")
        late.open(port, False, self.address)
        arrived = wait(late, lambda s: s["ready"] and s["throws"] and s["throws"][0][3], "late flying grenade")
        assert arrived["crates"][0] == [True, 0, 0] and arrived["scores"] == [0, 1]
        assert member(arrived, b)["kills"] == 1 and member(arrived, h)["deaths"] == 1
        assert arrived["pickups"][0][1] is False and arrived["pickups"][2][1] is False
        # The host stores a double, while the replicated deadline is a 32-bit float.
        assert struct.pack("<f", arrived["throws"][0][1]) == struct.pack("<f", flying["throws"][0][1])
        assert local(arrived)["team"] == member(arrived, b)["team"]
        wait(late, lambda s: s["throws"] and s["throws"][0][0][1] < 0.26, "replicated grenade reached the floor")
        wait(late, lambda s: not s["throws"] and s["blasts"] == 1, "late blast and removal")

        c = arrived["id"]
        host.place(b, [2.8, 0.035, 2.55])
        host.place(c, [0, 0.035, 2.55])
        wait(late, lambda s: abs(local(s)["position"][2] - 2.55) < .1, "crate approach")
        self.walk(late, 0, -2.1, direction=[0, 0, -1])
        host.place(c, [0, 0.035, 4.65])
        wait(late, lambda s: abs(local(s)["position"][2] - 4.65) < .1, "fixed cover approach")
        late.aim([0, 0, 1])
        late.press("walk_forward")
        time.sleep(0.57)
        covered = local(late.ask())["position"]
        late.press("walk_forward", False)
        assert 5.5 < covered[2] < 6.3, covered
        host.place(b, [-3, 0.035, 11.5])
        host.place(c, [3, 0.035, 11.5])
        guest.aim([1, 0, 0])
        health = member(host.ask(), c)["hp"]
        guest.tap("fire")
        wait(host, lambda s: member(s, b)["action"] == 1, "same-team shot fired")
        assert member(host.ask(), c)["hp"] == health and host.ask()["scores"] == [0, 1]

        late.ask("resume")
        late.aim([0, 0.2, 1])
        late.tap("throw")
        wait(host, lambda s: s["throws"] and s["throws"][0][2] == c, "second grenade released")
        late.ask("leave")
        wait(host, lambda s: not member(s, c) and len(s["throws"]) == 1, "thrower departed but grenade persists")
        wait(host, lambda s: not s["throws"] and s["blasts"] == 2, "departed thrower's one blast")
        wait(guest, lambda s: s["pickups"][0][1] and s["pickups"][2][1], "both supplies refresh", timeout=15)
        late.open(port, False, self.address)
        rejoined = wait(late, lambda s: s["ready"], "late player rejoined after blast")
        assert rejoined["blasts"] == 0 and not rejoined["throws"]
        print("V4–V5 pass: empty/reload/shot, friendly fire blocked, one contested supply, two refreshes, broken crate and flying grenade in late snapshot, one blast after departure", flush=True)

        # Stage the last point. Its damage and all following transitions use normal input.
        flank = self.start("Flank", port, visible=False)
        flanker = flank.ask()["id"]
        assert local(flank.ask())["team"] == 1
        host.ask("set_score", a=0, b=29)
        duel()
        for health in (75, 50, 25):
            guest.tap("fire")
            wait(host, lambda s: local(s)["hp"] == health, f"final point preparation {health}")
            time.sleep(0.13)
        host.place(flanker, [1.5, 0.035, 13.2])
        flank.aim([-3.5, 0, -1.7])
        wait(flank, lambda s: abs(local(s)["position"][2] - 13.2) < .1, "flank shooter baseline")
        with ThreadPoolExecutor(max_workers=2) as workers:
            for job in (workers.submit(guest.press, "fire"), workers.submit(flank.press, "fire")):
                job.result()
        settled = wait(host, lambda s: s["phase"] == 1 and s["winner"] == 1, "30-point result")
        guest.press("fire", False)
        flank.press("fire", False)
        assert settled["scores"] == [0, 30]
        result_guest = self.start("ResultGuest", port, visible=False)
        joined_result = result_guest.ask()
        assert joined_result["phase"] == 1 and joined_result["result"] and joined_result["scores"] == [0, 30]
        result_guest.tap("toggle_interface")
        assert not result_guest.ask()["interface"]
        result_guest.tap("toggle_interface")
        assert result_guest.ask()["interface"] and result_guest.ask()["result"]
        guests = [host, guest, late, flank, result_guest]
        for peer in guests:
            new_round = wait(peer, lambda s: s["round"] == 2 and s["phase"] == 0 and len(s["players"]) == 5
                             and all(x["alive"] and x["mag"] == 30 and x["kills"] == x["deaths"] == 0 for x in s["players"])
                             and not s["crates"][0][0], "round two on original connection")
            assert new_round["scores"] == [0, 0] and not new_round["throws"]
            assert all(p[1] for p in new_round["pickups"]) and all(p["grenades"] == 1 for p in new_round["players"])
        assert guest.ask()["id"] == b
        print("V6 pass: two shooters on the final point, one winner, joined results, five members preserved in round 2", flush=True)

        guest.ask("resume")
        guest.tap("roster")
        assert guest.ask()["roster"]
        guest.tap("toggle_interface")
        s = guest.ask()
        assert not s["interface"] and not s["reticle"] and s["roster"]
        guest.tap("toggle_interface")
        assert guest.ask()["interface"] and guest.ask()["roster"]
        guest.tap("toggle_interface")
        guest.tap("room_menu")
        s = guest.ask()
        assert s["interface"] and s["menu"] and s["mouse"] == 0
        before = local(guest.ask())["mag"]
        guest.tap("fire")
        assert before == local(guest.ask())["mag"]
        guest.tap("room_menu")
        s = guest.ask()
        assert not s["menu"] and (not self.visible or s["mouse"] == 2)
        guest.tap("toggle_interface")
        host.ask("leave")
        wait(guest, lambda s: s["lobby"] and s["interface"] and not s["menu"], "restored hidden interface after disconnect")
        print("G5 pass: roster, F1 state restore, Esc recovery, menu click isolation and disconnect recovery", flush=True)

    def motion(self):
        port = port_number()
        host = self.start("Observer", port, True)
        guest = self.start("Shooter", port)
        host_id = host.ask()["id"]
        guest_id = guest.ask()["id"]
        host.place(host_id, [-2.2, 0.035, 10.0])
        host.place(guest_id, [0.4, 0.035, 11.6])
        host.ask("resume")
        guest.ask("resume")
        host.aim([3.4, -0.14, 1.6])
        guest.aim([0, 0, 1])
        wait(guest, lambda s: abs(local(s)["position"][0] - 0.4) < .1, "shooter in view")
        self.snapshot_image(guest, "hands-ready")

        def observed(state):
            return member(state, guest_id)

        guest.press("walk_left")
        running = observed(wait(host, lambda s: observed(s)["animation"] == "Run_Gun"
                                and observed(s)["rifle_visible"], "remote run with visible rifle"))
        self.snapshot_image(host, "remote-running")
        wait(host, lambda s:
            observed(s)["position"][0] > running["position"][0] + 0.65
            and observed(s)["animation_time"] != running["animation_time"], "running animation advances")
        guest.press("fire")
        wait(host, lambda s: observed(s)["animation"] == "Run_Shoot" and observed(s)["mag"] < 30
             and observed(s)["rifle_visible"],
             "remote running fire")
        self.snapshot_image(host, "remote-running-fire")
        guest.press("fire", False)
        released = wait(host, lambda s: observed(s)["action"] == 0 and observed(s)["animation"] == "Run_Gun",
                        "remote returns to running after fire release")
        guest.press("walk_left", False)
        stopped = wait(host, lambda s: observed(s)["pose"] == 0 and observed(s)["action"] == 0
                       and observed(s)["holding_aim"] and abs(observed(s)["animation_time"] - .025) < .001,
                       "remote stops moving")
        self.snapshot_image(host, "remote-stopped")
        time.sleep(0.25)
        settled = host.ask()
        assert settled["shots"] == released["shots"]
        assert math.dist(observed(settled)["position"], observed(stopped)["position"]) < 0.05
        assert abs(observed(settled)["animation_time"] - observed(stopped)["animation_time"]) < .001
        guest.press("fire")
        wait(host, lambda s: observed(s)["action"] == 1 and observed(s)["animation"] == "Idle_Shoot",
             "remote stationary fire")
        wait(guest, lambda s: s["recoil"] > 0, "first-person recoil")
        self.snapshot_image(guest, "hands-fire", require_flash=True)
        self.snapshot_image(host, "remote-stationary-fire")
        guest.press("fire", False)
        wait(guest, lambda s: local(s)["action"] == 0 and not s["flash"] and s["recoil"] == 0, "first-person settles")
        wait(host, lambda s: observed(s)["action"] == 0 and observed(s)["holding_aim"], "remote stops firing")
        self.snapshot_image(host, "remote-fire-released")
        host.place(guest_id, [0.7, 0.035, 11.6])
        wait(guest, lambda s: abs(local(s)["position"][0] - 0.7) < .1, "back in view for reload")
        guest.tap("reload")
        wait(guest, lambda s: s["magazine_offset"] > .24, "magazine visibly removed")
        self.snapshot_image(guest, "hands-magazine-out")
        self.snapshot_image(host, "remote-magazine-out")
        wait(guest, lambda s: local(s)["mag"] == 30 and s["magazine_offset"] < .001, "magazine reseated")
        self.snapshot_image(guest, "hands-magazine-seated")
        guest.tap("fire")
        wait(guest, lambda s: local(s)["mag"] == 29, "fire works after reload")
        host.place(guest_id, [0.7, 0.035, 14.15])
        wait(guest, lambda s: local(s)["position"][2] > 14.0, "near the warehouse wall")
        guest.press("walk_forward")
        wait(host, lambda s: observed(s)["position"][2] > 14.4 and observed(s)["pose"] == 0
             and observed(s)["holding_aim"], "remote stops running against the wall")
        guest.press("walk_forward", False)
        print("Motion pass: remote run, running fire, run after release, stationary fire and stop. "
              "Viewmodel recoil stops, magazine leaves and reseats, fire resumes after reload.", flush=True)

    def rooms(self):
        port = port_number()
        host = self.peer("Host")
        self.snapshot_image(host, "lobby")
        host.tap("toggle_interface")
        assert not host.ask()["interface"]
        host.tap("room_menu")
        assert host.ask()["interface"] and host.ask()["lobby"]
        assert "port" in host.open(0, True, self.address)["message"]
        assert "IPv4" in host.open(port, False, "broken")["message"]
        host.open(port, True, self.address)
        s = wait(host, lambda x: x["ready"] and x["seats"] == 1, "host solo")
        p0 = local(s)["position"]
        host.press("walk_forward")
        wait(host, lambda x: math.dist(local(x)["position"], p0) > 1.2, "solo input moved host")
        host.press("walk_forward", False)
        self.snapshot_image(host, "warehouse")
        guest = self.peer("Visitor", False)
        s = guest.open(port, True, self.address)
        assert s["lobby"] and s["message"] and not s["pending"], s
        assert guest.open(port_number(), False, self.address)["pending"]
        assert guest.ask("cancel")["lobby"]
        guest.open(port_number(), False, self.address)
        wait(guest, lambda x: x["lobby"] and "Could not join" in x["message"], "unreachable retry")
        guest.open(port, False, self.address)
        b = wait(guest, lambda x: x["ready"] and len(x["players"]) == 2, "two player baseline")
        first = b["id"]
        assert local(b)["team"] != local(s := host.ask())["team"]
        assert all(player["bones"] == 43 for player in b["players"]) and b["arm_bones"] == 50
        before = local(b)["position"]
        guest.press("walk_back")
        wait(host, lambda x: math.dist(member(x, first).get("position", before), before) > 1, "guest input replicated")
        guest.press("walk_back", False)
        guest.ask("leave")
        wait(host, lambda x: len(x["players"]) == 1, "guest normal leave")
        guest.open(port, False, self.address)
        b = wait(guest, lambda x: x["ready"], "guest rejoin")
        assert b["id"] != first
        first = b["id"]
        guest.stop(abrupt=True)
        wait(host, lambda x: len(x["players"]) == 1 and not member(x, first), "guest process killed")
        with ThreadPoolExecutor(max_workers=7) as workers:
            pending = [workers.submit(self.start, f"Player{i}", port, visible=False) for i in range(1, 8)]
            clients = [job.result() for job in pending]
        all_peers = [host, *clients]
        def full(state):
            return state.get("seats") == 8 and len(state["players"]) == 8
        full_states = [wait(peer, full, "eight occupied seats") for peer in all_peers]
        identities = {x["id"] for x in full_states[0]["players"]}
        for state in full_states:
            assert {x["id"] for x in state["players"]} == identities
            assert [sum(x["team"] == team for x in state["players"]) for team in (0, 1)] == [4, 4]
        host.tap("roster")
        self.snapshot_image(host, "full-roster")
        rejected = self.peer("Overflow", False)
        rejected.open(port, False, self.address)
        wait(rejected, lambda x: x["lobby"] and "Could not join" in x["message"], "ninth seat rejected")
        old_id = clients[-1].ask()["id"]
        clients[-1].stop(abrupt=True)
        wait(host, lambda x: x["seats"] == 7 and not member(x, old_id), "crashed seat recycled")
        rejected.open(port, False, self.address)
        replacement = wait(rejected, full, "replacement admitted")
        assert replacement["id"] not in identities and local(replacement)["kills"] == 0
        replacement_id = replacement["id"]
        host.place(replacement_id, [-4.0, 0.035, -6.05])
        wait(rejected, lambda x: abs(local(x)["position"][2] + 6.05) < 0.1, "replacement supply baseline")
        rejected.tap("pickup")
        wait(host, lambda x: member(x, replacement_id)["reserve"] == 135 and x["seats"] == 8, "full-room supply")
        self.walk(rejected, -5.0, -6.05, direction=[-1, 0, 0])
        rejected.tap("fire")
        wait(host, lambda x: member(x, replacement_id)["mag"] == 29 and x["seats"] == 8, "full-room shot")
        cycle = clients[0]
        old_id = cycle.ask()["id"]
        cycle.ask("leave")
        wait(host, lambda x: x["seats"] == 7 and not member(x, old_id), "second seat released")
        cycle.open(port, False, self.address)
        renewed = wait(cycle, full, "second seat rejoined")
        assert renewed["id"] != old_id and local(renewed)["reserve"] == 90
        host.ask("leave")
        for peer in [*clients[:-1], rejected]:
            wait(peer, lambda x: x["lobby"] and "host" in x["message"], "host orderly leave")
        host.open(port, True, self.address)
        wait(host, lambda x: x["ready"], "host reopen")
        rejected.open(port, False, self.address)
        wait(rejected, lambda x: x["ready"], "join after host reopen")
        host.stop(abrupt=True)
        wait(rejected, lambda x: x["lobby"] and "host" in x["message"], "host killed")
        rejected.open(port, True, self.address)
        wait(rejected, lambda x: x["ready"], "guest can host after disconnect")
        print(f"G1 pass: 8 seats, balanced 4/4, ninth rejected, replacement {replacement['id']}, "
              f"ping samples {[x['ping'] for x in full_states[0]['players']]}", flush=True)

    def close(self):
        for peer in self.peers:
            if peer.process.poll() is None:
                try:
                    peer.stop()
                except (AssertionError, RuntimeError, subprocess.TimeoutExpired):
                    peer.stop(abrupt=True)

    def check_logs(self):
        for peer in self.peers:
            log = peer.log()
            if "ERROR:" in log:
                raise RuntimeError(f"{peer.name} reported Godot errors:\n{log[-12000:]}")


def verify(godot, suite, address, visible, addon=None):
    if not budget(ROOT, 128 * 1024**2)["allowed"]:
        raise RuntimeError("Output budget exceeded")
    work = create_job(ROOT, "tmp/verify-godot-fps", "temp")
    passed = False
    evidence = None
    try:
        with job_lock(work, "temp"):
            project = work / "project"
            shutil.copytree(SOURCE, project, ignore=shutil.ignore_patterns(
                ".godot", "addons", "source", "Barrier_Fixed_Fence.png*", "arms_arm_albedo_pale.png*"))
            prepare(project, godot, addon)
            shutil.copyfile(REPO / "tests/godot/fps_probe.gd", project / "probe.gd")
            with (project / "project.godot").open("a", encoding="utf-8") as settings:
                settings.write('\n[autoload]\nFPSProbe="*res://probe.gd"\n')
            evidence = create_job(ROOT, "runs/current", "run")
            with job_lock(evidence, "run"):
                run = Run(evidence, project, console_godot(godot), address, visible)
                try:
                    if suite in ("rooms", "all"):
                        run.rooms()
                    if suite in ("arena", "all"):
                        run.arena()
                    if suite in ("gameplay", "all"):
                        run.gameplay()
                    if suite in ("motion", "all"):
                        run.motion()
                finally:
                    run.close()
                run.check_logs()
                passed = True
    finally:
        remove_owned(ROOT, work, "temp")
        if evidence:
            print(f"Run evidence: {rotate_run(ROOT, passed)}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot-exe", type=Path)
    parser.add_argument("--suite", choices=("all", "rooms", "arena", "gameplay", "motion"), default="all")
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--visible", action="store_true")
    parser.add_argument("--addon", type=Path, help="Verify a candidate addon ZIP in the isolated project")
    args = parser.parse_args()
    verify(resolve_godot(args.godot_exe), args.suite, args.address, args.visible, args.addon)
