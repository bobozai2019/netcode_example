"""Install the distributable addon and exercise its editor panel and runtime replication."""
from pathlib import Path
import shutil
import subprocess
from zipfile import ZipFile

from artifacts import ROOT, budget, create_job, job_lock, remove_owned
from godot_build import REPO, console_godot, import_project, resolve_godot
from sdk_inputs import release_archive


def main():
    if not budget(ROOT, 24 * 1024**2)["allowed"]:
        raise RuntimeError("Output budget exceeded")
    work = create_job(ROOT, "tmp/verify-godot-addon", "temp")
    passed = False
    try:
        with job_lock(work, "temp"):
            project = work / "project"
            with ZipFile(release_archive("godot")) as archive:
                for name in archive.namelist():
                    path = Path(name)
                    if path.parts[:2] != ("addons", "netcode") or ".." in path.parts or path.drive:
                        raise ValueError(f"Unexpected addon entry: {name}")
                archive.extractall(project)
            settings = project / "project.godot"
            settings.write_text('config_version=5\n[application]\nconfig/name="Addon verification"\n'
                                '[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf-8")
            sync = project / "sync"
            sync.mkdir()
            sample_sync = REPO / "yard/godot/sync"
            for name in ("switch_panel.gd", "switch_panel.gd.uid", "panel_stats.gd", "panel_stats.gd.uid"):
                shutil.copyfile(sample_sync / name, sync / name)
            fixture_sync = project / "verification/sync"
            fixture_sync.mkdir(parents=True)
            shutil.copyfile(REPO / "puzzle/godot/sync/switch_panel.gd", fixture_sync / "switch_panel.gd")
            (project / "example.tscn").write_text(
                '[gd_scene load_steps=3 format=3]\n'
                '[ext_resource type="Script" path="res://verification/sync/switch_panel.gd" id="1"]\n'
                '[ext_resource type="Script" path="res://addons/netcode/scene_replicator.gd" id="2"]\n'
                '[node name="Panel" type="Node2D"]\nscript = ExtResource("1")\n'
                '[node name="Light" type="Node2D" parent="."]\n'
                '[node name="Network" type="Node" parent="."]\n'
                '[node name="Sync" type="Node" parent="Network"]\nscript = ExtResource("2")\n'
                'root_path = NodePath("../..")\nroot_mode = 0\n',
                encoding="utf-8")
            godot = resolve_godot()
            import_project(godot, project)
            probe = project / "addons/probe"
            probe.mkdir()
            shutil.copyfile(REPO / "tests/godot/addon_picker_probe.gd", probe / "probe.gd")
            (probe / "plugin.cfg").write_text(
                '[plugin]\nname="Inspector test"\ndescription=""\nauthor="Test"\nversion="1"\nscript="probe.gd"\n',
                encoding="utf-8")
            with settings.open("a", encoding="utf-8") as file:
                file.write('\n[editor_plugins]\nenabled=PackedStringArray("res://addons/netcode/plugin.cfg", '
                           '"res://addons/probe/plugin.cfg")\n')
            result = subprocess.run([console_godot(godot), "--headless", "--editor", "--path", project,
                                     "--quit-after", "800", "--max-fps", "60"], capture_output=True,
                                    text=True, encoding="utf-8", errors="replace", timeout=45)
            output = result.stdout + result.stderr
            if result.returncode or "ERROR:" in output or "picker_pass" not in output:
                raise RuntimeError(output)
            print(next(line for line in output.splitlines() if "picker_pass" in line))
            for name in ("sync_panel.tscn", "sync_preview.tscn", "sync_preview.gd"):
                shutil.copyfile(sample_sync / name, sync / name)
            probe_script = REPO / "tests/godot/scene_root_probe.gd"
            result = subprocess.run([console_godot(godot), "--headless", "--path", project, "--script", probe_script],
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=25)
            output = result.stdout + result.stderr
            if result.returncode or "ERROR:" in output or "scene_root_pass" not in output:
                raise RuntimeError(output)
            print(next(line for line in output.splitlines() if "scene_root_pass" in line))
            passed = True
    finally:
        if passed:
            remove_owned(ROOT, work, "temp")
        else:
            print("Failed verification project:", work)


if __name__ == "__main__":
    main()
