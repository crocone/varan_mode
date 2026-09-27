"""Creature modelling toolkit for Blender (run inside Blender's Python).

Coordinates: all helper inputs use GODOT space (x left, y up, z forward),
normalised to creature length 1. Conversion to Blender (z up, -y forward)
happens in `gv()`. The glTF exporter (Y-up) converts back, so exported
models land in Godot exactly in the space they were authored in.
"""
import bpy
import bmesh
import math
import numpy as np
from mathutils import Vector, Matrix


# ---------------------------------------------------------------- basics

def gv(p):
    """Godot (x, y, z) -> Blender Vector."""
    return Vector((p[0], -p[2], p[1]))


def bv(v):
    """Blender -> Godot tuple."""
    return (v[0], v[2], -v[1])


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for c in list(bpy.data.collections):
        bpy.data.collections.remove(c)


def new_object(name, bm):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def select_only(obs, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for o in obs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or obs[0]


def join(obs):
    obs = [o for o in obs if o is not None]
    if len(obs) == 1:
        return obs[0]
    select_only(obs, obs[0])
    bpy.ops.object.join()
    return bpy.context.view_layer.objects.active


def apply_mod(ob, mod):
    select_only([ob])
    bpy.ops.object.modifier_apply(modifier=mod.name)


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


# ---------------------------------------------------------------- primitives (bmesh, Godot coords)

def _frame(d, up_hint):
    d = d.normalized()
    up = up_hint - d * up_hint.dot(d)
    if up.length < 1e-6:
        up = Vector((1, 0, 0)) - d * d.x
    up.normalize()
    side = up.cross(d).normalized()
    return side, up, d


def loft(bm, centers, sections, up_hint=(0, 1, 0), ring=24, cap_start=True, cap_end=True, section_fn=None):
    """Loft rings along a polyline.
    centers: list of Godot points. sections: list of (half_width, half_height_top, half_height_bottom)
    section_fn(i, angle) -> (sx, sy) optional custom unit offsets.
    """
    C = [gv(p) for p in centers]
    uph = gv(up_hint)
    rings = []
    n = len(C)
    prev_side = None
    for i in range(n):
        a = C[max(i - 1, 0)]
        b = C[min(i + 1, n - 1)]
        d = (b - a)
        if d.length < 1e-9:
            d = Vector((0, -1, 0))
        d.normalize()
        if prev_side is None:
            side, up, _ = _frame(d, uph)
        else:
            # parallel transport: keep the previous side vector, re-orthogonalised
            side = prev_side - d * prev_side.dot(d)
            if side.length < 1e-6:
                side, up, _ = _frame(d, uph)
            side.normalize()
            up = d.cross(side).normalized()
        prev_side = side
        w, ht, hb = sections[i]
        verts = []
        for k in range(ring):
            th = 2 * math.pi * k / ring
            cs, sn = math.cos(th), math.sin(th)
            if section_fn:
                cs, sn = section_fn(i, th)
            y = sn * (ht if sn >= 0 else hb)
            verts.append(bm.verts.new(C[i] + side * (cs * w) + up * y))
        rings.append(verts)
    for i in range(n - 1):
        r0, r1 = rings[i], rings[i + 1]
        for k in range(ring):
            k2 = (k + 1) % ring
            bm.faces.new((r0[k], r0[k2], r1[k2], r1[k]))
    if cap_start:
        bm.faces.new(list(reversed(rings[0])))
    if cap_end:
        bm.faces.new(rings[-1])
    return rings


def tube(bm, pts, radii, ring=16, up_hint=(0, 1, 0), flat=1.0):
    """Round tube through points with per-point radius (flat scales vertical)."""
    secs = [(r, r * flat, r * flat) for r in radii]
    return loft(bm, pts, secs, up_hint, ring)


def ellipsoid(bm, center, radii, basis=None, seg=20, rings=12):
    """basis: optional (ax, ay, az) local axes given in GODOT coords."""
    cx, cy, cz = center
    rx, ry, rz = radii
    if basis is None:
        ax, ay, az = (1, 0, 0), (0, 1, 0), (0, 0, 1)
    else:
        ax, ay, az = basis
    grid = []
    for i in range(rings + 1):
        phi = math.pi * i / rings
        row = []
        for j in range(seg):
            th = 2 * math.pi * j / seg
            dx = math.sin(phi) * math.cos(th) * rx
            dy = math.cos(phi) * ry
            dz = math.sin(phi) * math.sin(th) * rz
            p = (cx + ax[0] * dx + ay[0] * dy + az[0] * dz,
                 cy + ax[1] * dx + ay[1] * dy + az[1] * dz,
                 cz + ax[2] * dx + ay[2] * dy + az[2] * dz)
            row.append(bm.verts.new(gv(p)))
        grid.append(row)
    for i in range(rings):
        for j in range(seg):
            j2 = (j + 1) % seg
            quad = [grid[i][j], grid[i][j2], grid[i + 1][j2], grid[i + 1][j]]
            uniq = []
            for v in quad:
                if all((v.co - u.co).length > 1e-9 for u in uniq):
                    uniq.append(v)
            if len(uniq) >= 3:
                try:
                    bm.faces.new(uniq)
                except ValueError:
                    pass


def cone(bm, base, tip, r, seg=8):
    b = gv(base)
    t = gv(tip)
    side, up, d = _frame(t - b, Vector((0, 0, 1)))
    ring = []
    for k in range(seg):
        th = 2 * math.pi * k / seg
        ring.append(bm.verts.new(b + side * math.cos(th) * r + up * math.sin(th) * r))
    tv = bm.verts.new(t)
    for k in range(seg):
        bm.faces.new((ring[k], ring[(k + 1) % seg], tv))
    bm.faces.new(list(reversed(ring)))


def fix_normals(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(ob.data)
    bm.free()


# ---------------------------------------------------------------- mesh processing

def remesh(ob, voxel, smooth_iters=8, smooth_factor=0.6):
    m = ob.modifiers.new("remesh", 'REMESH')
    m.mode = 'VOXEL'
    m.voxel_size = voxel
    m.adaptivity = 0.0
    m.use_smooth_shade = True
    apply_mod(ob, m)
    if smooth_iters > 0:
        s = ob.modifiers.new("smooth", 'LAPLACIANSMOOTH')
        s.iterations = smooth_iters
        s.lambda_factor = smooth_factor
        s.lambda_border = 0.0
        s.use_volume_preserve = True
        apply_mod(ob, s)


def decimate(ob, target_tris):
    t = tri_count(ob)
    if t <= target_tris:
        return
    m = ob.modifiers.new("dec", 'DECIMATE')
    m.decimate_type = 'COLLAPSE'
    m.ratio = target_tris / t
    m.use_collapse_triangulate = True
    apply_mod(ob, m)


def shade_smooth(ob):
    for p in ob.data.polygons:
        p.use_smooth = True


def displace_fn(ob, fn):
    """fn(godot_pos np.array Nx3, normals Nx3) -> offset along normal (N,)"""
    me = ob.data
    n = len(me.vertices)
    co = np.zeros(n * 3)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    me.calc_normals_split() if hasattr(me, "calc_normals_split") else None
    nr = np.zeros(n * 3)
    me.vertices.foreach_get("normal", nr)
    nr = nr.reshape(-1, 3)
    g = np.stack([co[:, 0], co[:, 2], -co[:, 1]], 1)
    gn = np.stack([nr[:, 0], nr[:, 2], -nr[:, 1]], 1)
    off = fn(g, gn)
    co += nr * off[:, None]
    me.vertices.foreach_set("co", co.ravel())
    me.update()


# ---------------------------------------------------------------- armature

def make_armature(bones, name="Armature"):
    """bones: list of dicts {name, head, tail, parent, roll_up (optional godot vec)} in Godot coords."""
    arm = bpy.data.armatures.new(name)
    ob = bpy.data.objects.new(name, arm)
    bpy.context.scene.collection.objects.link(ob)
    select_only([ob])
    bpy.ops.object.mode_set(mode='EDIT')
    eb = {}
    for b in bones:
        e = arm.edit_bones.new(b["name"])
        e.head = gv(b["head"])
        e.tail = gv(b["tail"])
        if "up" in b:
            e.align_roll(gv(b["up"]))
        e.use_deform = b.get("deform", True)
        eb[b["name"]] = e
    for b in bones:
        if b.get("parent"):
            eb[b["name"]].parent = eb[b["parent"]]
    bpy.ops.object.mode_set(mode='OBJECT')
    return ob


def bind_auto(mesh_ob, arm_ob):
    select_only([mesh_ob, arm_ob], arm_ob)
    bpy.ops.object.parent_set(type='ARMATURE_AUTO')


def bind_groups(mesh_ob, arm_ob):
    """Parent with an armature modifier using existing vertex groups."""
    mesh_ob.parent = arm_ob
    m = mesh_ob.modifiers.new("Armature", 'ARMATURE')
    m.object = arm_ob
    m.use_vertex_groups = True


def rigid_group(ob, group):
    vg = ob.vertex_groups.new(name=group)
    vg.add(list(range(len(ob.data.vertices))), 1.0, 'REPLACE')


def smooth_weights(ob, factor=0.5, repeat=4):
    select_only([ob])
    bpy.ops.object.mode_set(mode='WEIGHT_PAINT')
    bpy.ops.object.vertex_group_smooth(group_select_mode='ALL', factor=factor, repeat=repeat)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)
    bpy.ops.object.vertex_group_limit_total(limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)
    bpy.ops.object.mode_set(mode='OBJECT')


# ---------------------------------------------------------------- UV + texture baking (numpy)

def uv_unwrap(ob, margin=0.004, angle=66.0):
    select_only([ob])
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=margin, area_weight=0.0, correct_aspect=True, scale_to_bounds=False)
    bpy.ops.object.mode_set(mode='OBJECT')


def raster_maps(ob, res, attr_names=()):
    """Rasterise mesh data into UV space.
    Returns dict: mask (res,res bool), pos (res,res,3 godot rest coords), nrm, and any
    float point/corner attributes listed in attr_names (as res,res,k)."""
    me = ob.data
    me.calc_loop_triangles()
    uvl = me.uv_layers.active.data
    nl = len(me.loops)
    uv = np.zeros(nl * 2)
    uvl.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    nv = len(me.vertices)
    co = np.zeros(nv * 3)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    vn = np.zeros(nv * 3)
    me.vertices.foreach_get("normal", vn)
    vn = vn.reshape(-1, 3)
    lv = np.zeros(nl, dtype=np.int64)
    me.loops.foreach_get("vertex_index", lv)
    extra = {}
    for a in attr_names:
        at = me.attributes.get(a) or me.color_attributes.get(a)
        if at is None:
            continue
        if at.data_type in ('FLOAT_COLOR', 'BYTE_COLOR'):
            arr = np.zeros(len(at.data) * 4)
            at.data.foreach_get("color", arr)
            arr = arr.reshape(-1, 4)[:, :3]
        elif at.data_type == 'FLOAT':
            arr = np.zeros(len(at.data))
            at.data.foreach_get("value", arr)
            arr = arr.reshape(-1, 1)
        else:
            continue
        extra[a] = (at.domain, arr)
    tris = np.zeros(len(me.loop_triangles) * 3, dtype=np.int64)
    me.loop_triangles.foreach_get("loops", tris)
    tris = tris.reshape(-1, 3)
    pos = np.zeros((res, res, 3), np.float32)
    nrm = np.zeros((res, res, 3), np.float32)
    mask = np.zeros((res, res), bool)
    outs = {a: np.zeros((res, res, v[1].shape[1]), np.float32) for a, v in extra.items()}
    tuv = uv[tris] * res - 0.5            # (T,3,2)
    for ti in range(len(tris)):
        p = tuv[ti]
        x0 = int(max(math.floor(p[:, 0].min()), 0))
        x1 = int(min(math.ceil(p[:, 0].max()), res - 1))
        y0 = int(max(math.floor(p[:, 1].min()), 0))
        y1 = int(min(math.ceil(p[:, 1].max()), res - 1))
        if x1 < x0 or y1 < y0:
            continue
        xs, ys = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        a, b, c = p[0], p[1], p[2]
        v0 = b - a
        v1 = c - a
        den = v0[0] * v1[1] - v1[0] * v0[1]
        if abs(den) < 1e-12:
            continue
        px = xs - a[0]
        py = ys - a[1]
        w1 = (px * v1[1] - v1[0] * py) / den
        w2 = (v0[0] * py - px * v0[1]) / den
        w0 = 1 - w1 - w2
        e = -0.02
        inside = (w0 >= e) & (w1 >= e) & (w2 >= e)
        if not inside.any():
            continue
        yy = ys[inside]
        xx = xs[inside]
        W = np.stack([w0[inside], w1[inside], w2[inside]], 1)
        li = tris[ti]
        vi = lv[li]
        pos[yy, xx] = W @ co[vi]
        nrm[yy, xx] = W @ vn[vi]
        mask[yy, xx] = True
        for a_name, (dom, arr) in extra.items():
            src = arr[li] if dom == 'CORNER' else arr[vi]
            outs[a_name][yy, xx] = W @ src
    # Blender -> Godot coords
    gpos = np.stack([pos[..., 0], pos[..., 2], -pos[..., 1]], -1)
    gn = np.stack([nrm[..., 0], nrm[..., 2], -nrm[..., 1]], -1)
    ln = np.linalg.norm(gn, axis=-1, keepdims=True)
    gn = gn / np.maximum(ln, 1e-8)
    return {"mask": mask, "pos": gpos, "nrm": gn, **outs}


def dilate(img, mask, iters=12):
    img = img.copy()
    m = mask.copy()
    for _ in range(iters):
        acc = np.zeros_like(img)
        cnt = np.zeros(m.shape, np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
            sm = np.roll(np.roll(m, dy, 0), dx, 1)
            si = np.roll(np.roll(img, dy, 0), dx, 1)
            acc[sm] += si[sm]
            cnt[sm] += 1
        grow = (~m) & (cnt > 0)
        img[grow] = acc[grow] / cnt[grow][:, None]
        m = m | grow
    return img


def height_to_normal(h, mask, strength):
    """Tangent-space (OpenGL) normal map from a height map in UV space."""
    hp = h.copy()
    dx = (np.roll(hp, -1, 1) - np.roll(hp, 1, 1)) * 0.5
    dy = (np.roll(hp, -1, 0) - np.roll(hp, 1, 0)) * 0.5
    # suppress seams: only use neighbours inside the island
    mx = mask & np.roll(mask, -1, 1) & np.roll(mask, 1, 1)
    my = mask & np.roll(mask, -1, 0) & np.roll(mask, 1, 0)
    dx = np.where(mx, dx, 0.0)
    dy = np.where(my, dy, 0.0)
    n = np.stack([-dx * strength, -dy * strength, np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


def save_image(name, arr, res, path, non_color=False, alpha=None):
    img = bpy.data.images.new(name, res, res, alpha=alpha is not None, is_data=non_color)
    if non_color:
        img.colorspace_settings.name = 'Non-Color'
    rgba = np.ones((res, res, 4), np.float32)
    rgba[..., :3] = np.clip(arr, 0, 1)
    if alpha is not None:
        rgba[..., 3] = np.clip(alpha, 0, 1)
    img.pixels.foreach_set(rgba.ravel())
    img.update()
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    return img


def make_material(name, albedo_img, normal_img=None, rough_img=None, rough=0.7, normal_strength=1.0, spec=0.4):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = albedo_img
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    if normal_img is not None:
        nt2 = nt.nodes.new("ShaderNodeTexImage")
        nt2.image = normal_img
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nm.inputs["Strength"].default_value = normal_strength
        nt.links.new(nt2.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    if rough_img is not None:
        rt = nt.nodes.new("ShaderNodeTexImage")
        rt.image = rough_img
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(rt.outputs["Color"], sep.inputs["Color"])
        nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
        nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    else:
        bsdf.inputs["Roughness"].default_value = rough
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = spec
    mat.use_backface_culling = False
    return mat


def simple_material(name, color, rough=0.5, metallic=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*[c ** 2.2 for c in color], 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


def export_glb(path, objects):
    select_only(objects, objects[0])
    kw = dict(filepath=path, export_format='GLB', use_selection=True, export_yup=True,
              export_skins=True, export_animations=False, export_apply=False,
              export_texcoords=True, export_normals=True, export_tangents=False,
              export_materials='EXPORT', export_image_format='AUTO')
    try:
        bpy.ops.export_scene.gltf(**kw, export_def_bones=False, export_rest_position_armature=True)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)


# ---------------------------------------------------------------- noise helpers (numpy)

def hash3(ix, iy, iz, seed=0):
    h = (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791) ^ (seed * 2654435761)
    h = (h ^ (h >> 13)) * 1274126177
    h = h ^ (h >> 16)
    return (h & 0xFFFFFF).astype(np.float32) / float(0xFFFFFF)


def value_noise3(p, seed=0):
    """Smooth value noise, p: (N,3) float."""
    i = np.floor(p).astype(np.int64)
    f = p - i
    u = f * f * (3 - 2 * f)
    out = np.zeros(len(p), np.float32)
    for dz in (0, 1):
        for dy in (0, 1):
            for dx in (0, 1):
                w = (u[:, 0] if dx else 1 - u[:, 0]) * (u[:, 1] if dy else 1 - u[:, 1]) * (u[:, 2] if dz else 1 - u[:, 2])
                out += w * hash3(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz, seed)
    return out


def fbm3(p, octaves=4, seed=0):
    s = np.zeros(len(p), np.float32)
    a = 0.5
    q = p.copy()
    for o in range(octaves):
        s += a * value_noise3(q, seed + o * 17)
        q = q * 2.03
        a *= 0.5
    return s


def voronoi3(p, jitter=0.85, seed=0, chunk=250000):
    """Returns F1, F2 distances and cell id hash for points p (N,3) (cell size 1)."""
    N = len(p)
    F1 = np.full(N, 9.0, np.float32)
    F2 = np.full(N, 9.0, np.float32)
    CID = np.zeros(N, np.float32)
    for s0 in range(0, N, chunk):
        q = p[s0:s0 + chunk]
        base = np.floor(q).astype(np.int64)
        f1 = np.full(len(q), 9.0, np.float32)
        f2 = np.full(len(q), 9.0, np.float32)
        cid = np.zeros(len(q), np.float32)
        for dz in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    c = base + np.array([dx, dy, dz])
                    r = np.stack([hash3(c[:, 0], c[:, 1], c[:, 2], seed + k) for k in range(3)], 1)
                    fp = c + 0.5 + (r - 0.5) * jitter
                    d = np.linalg.norm(q - fp, axis=1).astype(np.float32)
                    closer = d < f1
                    f2 = np.where(closer, f1, np.minimum(f2, d))
                    cid = np.where(closer, r[:, 0], cid)
                    f1 = np.where(closer, d, f1)
        F1[s0:s0 + chunk] = f1
        F2[s0:s0 + chunk] = f2
        CID[s0:s0 + chunk] = cid
    return F1, F2, CID


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
