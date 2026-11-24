"""Run with Blender --background --factory-startup --python to rebuild the Shiftline props."""
from collections import defaultdict
from math import radians
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


ASSETS = Path(__file__).resolve().parents[1] / "shiftline/assets"
OUTPUT = ASSETS / "shiftline"
SOURCE = ASSETS / "source"


def import_gltf(path):
    bpy.ops.import_scene.gltf(filepath=str(path))
    return list(bpy.context.selected_objects)


def export(name, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(OUTPUT / f"{name}.glb"),
                              export_format="GLB", use_selection=True, export_animations=False)


def magazine_faces(rifle):
    polygons_by_point = defaultdict(set)
    points = {}
    for polygon in rifle.data.polygons:
        coordinates = [tuple(round(value, 4) for value in rifle.matrix_world @ rifle.data.vertices[i].co)
                       for i in polygon.vertices]
        points[polygon.index] = coordinates
        for coordinate in coordinates:
            polygons_by_point[coordinate].add(polygon.index)
    remaining = set(points)
    magazine = set()
    while remaining:
        pending = [remaining.pop()]
        component = set(pending)
        while pending:
            polygon = pending.pop()
            for coordinate in points[polygon]:
                neighbors = polygons_by_point[coordinate] & remaining
                component.update(neighbors)
                remaining.difference_update(neighbors)
                pending.extend(neighbors)
        cloud = [point for polygon in component for point in points[polygon]]
        if max(p[0] for p in cloud) < -0.24 and min(p[2] for p in cloud) < -0.16 and max(p[2] for p in cloud) < 0.08:
            magazine.update(component)
    if not 100 < len(magazine) < len(rifle.data.polygons) / 2:
        raise ValueError(f"Unexpected Quaternius magazine topology ({len(magazine)} faces)")
    return magazine


def remove_faces(mesh, faces):
    edit = bmesh.new()
    edit.from_mesh(mesh)
    bmesh.ops.delete(edit, geom=[face for face in edit.faces if face.index in faces], context="FACES")
    edit.to_mesh(mesh)
    edit.free()


def build_rifle():
    rifle, = [obj for obj in import_gltf(ASSETS / "quaternius/AK.gltf") if obj.type == "MESH"]
    rifle.name = "RifleReceiver"
    magazine = rifle.copy()
    magazine.data = rifle.data.copy()
    magazine.name = "Magazine"
    bpy.context.collection.objects.link(magazine)
    parts = magazine_faces(rifle)
    remove_faces(rifle.data, parts)
    remove_faces(magazine.data, set(range(len(magazine.data.polygons))) - parts)
    bpy.ops.object.select_all(action="DESELECT")
    magazine.select_set(True)
    bpy.context.view_layer.objects.active = magazine
    bpy.context.scene.cursor.location = Vector((-0.36, 0, 0.06))
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    export("rifle", [rifle, magazine])
    return rifle, magazine


def material(name, srgb):
    color = tuple(channel / 255 for channel in srgb)
    linear = tuple(channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4 for channel in color)
    surface = bpy.data.materials.new(name)
    surface.diffuse_color = (*linear, 1.0)
    if surface.node_tree is None:
        surface.use_nodes = True
    shader = surface.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = surface.diffuse_color
    shader.inputs["Roughness"].default_value = 0.85
    return surface


def block(name, center, size, surface, bevel=0.0, twist=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center, rotation=(0, 0, radians(twist)))
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(surface)
    if bevel:
        detail = obj.modifiers.new("Bevelled silhouette", "BEVEL")
        detail.width = bevel
        detail.segments = 1
        bpy.ops.object.modifier_apply(modifier=detail.name)
    return obj


def build_ammo():
    dark = material("Ammo shell", (29, 48, 56))
    edge = material("Ammo markings", (96, 218, 234))
    ammo = [block("AmmoPack", (0, 0, 0.27), (0.50, 0.36, 0.23), dark, 0.042)]
    for i, x in enumerate((-0.12, 0.0, 0.12)):
        ammo.append(block(f"AmmoMark{i}", (x, 0, 0.389), (0.065, 0.25, 0.024), edge, 0.01))
    export("ammo-pack", ammo)
    return ammo


def build_debris():
    pine = material("Pine faces", (190, 137, 76))
    grain = material("Pine edges", (135, 88, 46))
    debris = []
    for i, (x, y, twist) in enumerate(((-.48, -.22, 22), (.39, .47, -42), (-.32, .52, 11),
                                      (.52, -.36, 73), (-.67, .12, -22), (.24, -.54, 17))):
        plank = block(f"Splinter{i}", (x, y, 0.05), (0.6 - i * 0.036, 0.18, 0.09), pine, 0.026, twist)
        plank.data.materials.append(grain)
        for face in plank.data.polygons:
            if abs(face.normal.z) < 0.7:
                face.material_index = 1
        debris.append(plank)
    export("crate-debris", debris)
    return debris


def build_wall_trim():
    trim = material("Rail steel", (37, 57, 70))
    frame = material("Panel steel", (64, 93, 102))
    module = [block("WallPanel", (0, 0, 1.1), (3.74, 0.06, 2.2), frame, 0.025)]
    for x in (-1.66, -0.55, 0.55, 1.66):
        module.append(block("PanelFold", (x, -.04, 1.1), (.065, .07, 2.14), trim, 0.014))
    module.append(block("KickPlate", (0, -.045, 0.22), (3.74, .11, .32), trim, 0.025))
    export("wall-trim", module)
    return module


def main():
    OUTPUT.mkdir(exist_ok=True)
    SOURCE.mkdir(exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    rifle = build_rifle()
    ammo = build_ammo()
    debris = build_debris()
    wall = build_wall_trim()
    for objects, offset in ((rifle, (0, 0, 1)), (ammo, (1.6, 0, 0)), (debris, (3.1, 0, 0)), (wall, (5.6, 0, 0))):
        for obj in objects:
            obj.location += Vector(offset)
    arms = import_gltf(ASSETS / "wrad-arms/arms.glb")
    for arm in arms:
        if not arm.parent:
            arm.location += Vector((0, 5.5, 0))
    bpy.ops.file.pack_all()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE / "shiftline-kit.blend"), compress=True)


if __name__ == "__main__":
    main()
