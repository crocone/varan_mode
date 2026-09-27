"""Render preview images of an exported creature .glb (rest pose and a test pose).

blender -b --python tools/modelgen/preview_glb.py -- <species> [pose]
Writes tools/shots/model_<species>_<view>.png
"""
import sys
import os
import math
import bpy
from mathutils import Vector, Euler

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
species = argv[0] if argv else "monitor"
do_pose = "pose" in argv
path = os.path.join(ROOT, "game", "assets", "creatures", species + ".glb")
out = os.path.join(ROOT, "tools", "shots")
os.makedirs(out, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
scene = bpy.context.scene
meshes = [o for o in scene.objects if o.type == 'MESH']
arm = next((o for o in scene.objects if o.type == 'ARMATURE'), None)

# bounds
mn = Vector((1e9, 1e9, 1e9))
mx = Vector((-1e9, -1e9, -1e9))
for o in meshes:
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c)
        mn = Vector((min(mn[i], w[i]) for i in range(3)))
        mx = Vector((max(mx[i], w[i]) for i in range(3)))
center = (mn + mx) / 2
size = (mx - mn).length

if do_pose and arm is not None:
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='POSE')
    for pb in arm.pose.bones:
        n = pb.name
        pb.rotation_mode = 'XYZ'
        if n.startswith("sp"):
            i = int(n[2:])
            pb.rotation_euler = Euler((0.0, 0.0, 0.18 * math.sin(i * 0.7)))
        elif n == "jaw":
            pb.rotation_euler = Euler((0.6, 0, 0))
        elif n == "leg0_a":
            pb.rotation_euler = Euler((0.0, 0.0, 0.6))
        elif n == "leg3_b":
            pb.rotation_euler = Euler((0.5, 0.0, 0.0))
    bpy.ops.object.mode_set(mode='OBJECT')

# ground
bpy.ops.mesh.primitive_plane_add(size=size * 4, location=(center.x, center.y, mn.z))
ground = bpy.context.active_object
gm = bpy.data.materials.new("ground")
gm.use_nodes = True
gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.35, 0.18, 0.1, 1)
ground.data.materials.append(gm)
# lights
bpy.ops.object.light_add(type='SUN', rotation=(math.radians(50), math.radians(10), math.radians(30)))
bpy.context.active_object.data.energy = 3.5
bpy.ops.object.light_add(type='SUN', rotation=(math.radians(-60), 0, math.radians(200)))
bpy.context.active_object.data.energy = 0.8
world = bpy.data.worlds.new("w")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.62, 0.72, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6

scene.render.engine = 'BLENDER_EEVEE_NEXT' if 'BLENDER_EEVEE_NEXT' in [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties['engine'].enum_items] else 'BLENDER_EEVEE'
scene.render.resolution_x = 1280
scene.render.resolution_y = 720
scene.view_settings.view_transform = 'AgX' if 'AgX' in [i.identifier for i in scene.view_settings.bl_rna.properties['view_transform'].enum_items] else 'Filmic'

cam_data = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
cam_data.lens = 50
cam_data.clip_start = size * 0.001


def shoot(name, direction, dist_mul=1.0, target=None, lens=50):
    tgt = target if target is not None else center
    d = Vector(direction).normalized()
    cam.location = tgt + d * size * 0.95 * dist_mul
    cam.rotation_euler = (tgt - cam.location).to_track_quat('-Z', 'Y').to_euler()
    cam_data.lens = lens
    scene.render.filepath = os.path.join(out, "model_%s_%s%s.png" % (species, name, "_pose" if do_pose else ""))
    bpy.ops.render.render(write_still=True)


# Blender: -Y is the creature's forward (Godot +Z)
shoot("side", (1, 0, 0.25))
shoot("top", (0.001, 0.0, 1))
shoot("front34", (0.8, -1.0, 0.55), 0.8)
head = center
if arm is not None:
    hb = arm.pose.bones.get("head") or next((b for b in arm.pose.bones if "head" in b.name.lower()), None)
    if hb is not None:
        head = arm.matrix_world @ hb.head
shoot("head", (0.9, -0.9, 0.5), 0.2, head, 50)
shoot("head_low", (-0.3, -1.0, 0.15), 0.16, head, 50)
print("PREVIEW DONE")
