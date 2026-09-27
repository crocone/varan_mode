"""Turn an exported procedural rig (tools/rig_export/<species>.json) into a
single smooth, textured, skinned model: game/assets/creatures/<species>.glb.

Every rigid part becomes one bone (named like the part) so the in-game
PartSkin binder can drive it with the existing procedural animation.

blender -b --python tools/modelgen/build_from_parts.py -- <species> [--quick]
"""
import sys
import os
import re
import json
import math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmodel as cm  # noqa: E402
import bpy  # noqa: E402
import bmesh  # noqa: E402
from mathutils import Vector, kdtree  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "game", "assets", "creatures")

CFG = {
    "dingo":       dict(kind="fur", voxel=0.0045, tris=9000, tex=1024, sep=r"^(jaw|ear)"),
    "wallaby":     dict(kind="fur", voxel=0.0045, tris=8000, tex=1024, sep=r"^(ear)"),
    "mouse":       dict(kind="fur", voxel=0.005, tris=5000, tex=1024, sep=r"^(ear)"),
    "turkey":      dict(kind="feather", voxel=0.0045, tris=7000, tex=1024, sep=r"^(wing|tar|foot|tail)"),
    "crow":        dict(kind="feather", voxel=0.0045, tris=6000, tex=1024, sep=r"^(wing|tar|foot|tail)"),
    "eagle":       dict(kind="feather", voxel=0.0045, tris=7000, tex=1024, sep=r"^(wing|tar|foot|tail)"),
    "frog":        dict(kind="frog", voxel=0.007, tris=5000, tex=512, sep=r"^$"),
    "grasshopper": dict(kind="insect", voxel=0.007, tris=3500, tex=512, sep=r"^(sleg|hleg1|hleg2)"),
    "fish":        dict(kind="fish", voxel=0.005, tris=4000, tex=512, sep=r"^(tail)"),
}


def _bm_colors(bm, layer):
    return [tuple(v[layer])[:3] for v in bm.verts]


def part_mesh(p):
    """Objects for one exported part (Godot rig space): main mesh plus small dark
    loose pieces (eyes, nose leather, pupils) that must stay crisp and separate."""
    v = np.array(p["v"], dtype=np.float64).reshape(-1, 3)
    col = np.array(p["c"], dtype=np.float64).reshape(-1, 3) if p["c"] else np.ones((len(v), 3)) * 0.5
    idx = p["i"]
    if not idx:
        idx = list(range(len(v)))
    bm = bmesh.new()
    clayer = bm.verts.layers.float_color.new("col")
    verts = []
    for q, c in zip(v, col):
        bv_ = bm.verts.new(cm.gv(q))
        bv_[clayer] = (c[0], c[1], c[2], 1.0)
        verts.append(bv_)
    bm.verts.ensure_lookup_table()
    for t in range(0, len(idx) - 2, 3):
        a, b, c = verts[idx[t]], verts[idx[t + 1]], verts[idx[t + 2]]
        if len({a, b, c}) < 3:
            continue
        try:
            bm.faces.new((a, b, c))
        except ValueError:
            pass
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # split off small dark loose components
    seen = set()
    extras = []
    size_ref = max((max(v[:, i]) - min(v[:, i])) for i in range(3))
    for sv in list(bm.verts):
        if sv.index in seen or not sv.is_valid:
            continue
        comp = []
        stack = [sv]
        seen.add(sv.index)
        while stack:
            x = stack.pop()
            comp.append(x)
            for e in x.link_edges:
                o = e.other_vert(x)
                if o.index not in seen:
                    seen.add(o.index)
                    stack.append(o)
        cs = np.array([tuple(x[clayer])[:3] for x in comp])
        lum = float((cs @ np.array([0.3, 0.55, 0.15])).mean())
        pos = np.array([tuple(x.co) for x in comp])
        ext = float((pos.max(0) - pos.min(0)).max()) if len(pos) else 0.0
        if lum < 0.16 and ext < max(0.06, size_ref * 0.18) and len(comp) >= 4:
            extras.append(comp)
    extra_obs = []
    for ei, comp in enumerate(extras):
        ebm = bmesh.new()
        ecl = ebm.verts.layers.float_color.new("col")
        vm = {}
        for x in comp:
            nv = ebm.verts.new(x.co)
            nv[ecl] = x[clayer]
            vm[x] = nv
        faces = set()
        for x in comp:
            for f in x.link_faces:
                faces.add(f)
        for f in faces:
            try:
                ebm.faces.new([vm[x] for x in f.verts])
            except (ValueError, KeyError):
                pass
        eo = cm.new_object(p["name"] + "_x%d" % ei, ebm)
        _pointcol_from_layer(eo)
        extra_obs.append(eo)
        bmesh.ops.delete(bm, geom=list(faces), context='FACES')
    loose = [x for x in bm.verts if not x.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context='VERTS')
    ob = cm.new_object(p["name"], bm)
    _pointcol_from_layer(ob)
    return ob, extra_obs


def _pointcol_from_layer(ob):
    """bmesh float_color layers become point colour attributes named 'col'."""
    me = ob.data
    if "col" not in me.color_attributes:
        me.color_attributes.new("col", 'FLOAT_COLOR', 'POINT')


def mesh_arrays(ob):
    me = ob.data
    n = len(me.vertices)
    co = np.zeros(n * 3)
    me.vertices.foreach_get("co", co)
    return co.reshape(-1, 3)


def point_colors(ob):
    at = ob.data.color_attributes.get("col")
    arr = np.zeros(len(at.data) * 4)
    at.data.foreach_get("color", arr)
    return arr.reshape(-1, 4)[:, :3]


def _assign_from_parts(ob, kd, SG, SC, names, vox, rigid_group=None):
    """Vertex weights (k nearest source part vertices) and colours for ob."""
    me = ob.data
    for vg0 in list(ob.vertex_groups):
        ob.vertex_groups.remove(vg0)
    for n in names:
        ob.vertex_groups.new(name=n)
    ucol = np.zeros((len(me.vertices), 3))
    group_w = {}
    for v in me.vertices:
        hits = kd.find_n(v.co, 10)
        wsum = 0.0
        acc = {}
        c = np.zeros(3)
        for (co, idx, d) in hits:
            w = 1.0 / (d + vox * 0.5) ** 2
            g = int(SG[idx])
            acc[g] = acc.get(g, 0.0) + w
            c += SC[idx] * w
            wsum += w
        ucol[v.index] = c / max(wsum, 1e-9)
        if rigid_group is None:
            for g, w in acc.items():
                group_w.setdefault(g, []).append((v.index, w / wsum))
    if rigid_group is not None:
        ob.vertex_groups[rigid_group].add(list(range(len(me.vertices))), 1.0, 'REPLACE')
    else:
        for g, lst in group_w.items():
            vg = ob.vertex_groups[names[g]]
            for vi, w in lst:
                if w > 0.02:
                    vg.add([vi], w, 'REPLACE')
    if "col" not in me.color_attributes:
        me.color_attributes.new("col", 'FLOAT_COLOR', 'POINT')
    at = me.color_attributes["col"]
    rgba = np.ones((len(ucol), 4))
    rgba[:, :3] = ucol
    at.data.foreach_set("color", rgba.ravel())


def _set_region(ob, value):
    at = ob.data.attributes.get("region") or ob.data.attributes.new("region", 'FLOAT', 'POINT')
    at.data.foreach_set("value", [float(value)] * len(ob.data.vertices))


def _lost_thin(union, vol_src_faces, vox):
    from mathutils.bvhtree import BVHTree
    ubvh = BVHTree.FromObject(union, bpy.context.evaluated_depsgraph_get())
    thin_bm = bmesh.new()
    thin_col, thin_grp = [], []
    for co, tris, cols, gname in vol_src_faces:
        cent = co[tris].mean(axis=1)
        lost = []
        for ti, c in enumerate(cent):
            h = ubvh.find_nearest(Vector(c))
            if h[0] is None or h[3] > vox * 1.8:
                lost.append(ti)
        vmap = {}
        for ti in lost:
            vs = []
            for vi in tris[ti]:
                if vi not in vmap:
                    vmap[vi] = thin_bm.verts.new(Vector(co[vi]))
                    thin_col.append(cols[vi])
                    thin_grp.append(gname)
                vs.append(vmap[vi])
            try:
                thin_bm.faces.new(vs)
            except ValueError:
                pass
    if len(thin_bm.verts) == 0:
        thin_bm.free()
        return None
    thin_ob = cm.new_object("thin", thin_bm)
    at = thin_ob.data.color_attributes.new("col", 'FLOAT_COLOR', 'POINT')
    rgba = np.ones((len(thin_col), 4))
    rgba[:, :3] = np.array(thin_col)
    at.data.foreach_set("color", rgba.ravel())
    for gname in set(thin_grp):
        thin_ob.vertex_groups.new(name=gname)
    for i, gname in enumerate(thin_grp):
        thin_ob.vertex_groups[gname].add([i], 1.0, 'REPLACE')
    _set_region(thin_ob, 0)
    return thin_ob


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    species = argv[0]
    quick = "--quick" in argv
    C = CFG[species]
    data = json.load(open(os.path.join(ROOT, "tools", "rig_export", species + ".json")))
    cm.clear_scene()
    parts = data["parts"]
    names = [p["name"] for p in parts]
    key_to_name = {}
    for p in parts:
        key_to_name.setdefault(p["key"], p["name"])
    sculpt_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sculpt")
    sys.path.insert(0, sculpt_dir)
    sculpt = None
    if os.path.exists(os.path.join(sculpt_dir, species + ".py")) and "--parts" not in argv:
        import importlib
        sculpt = importlib.import_module(species)
    sep_re = re.compile(C["sep"])
    vol_obs, sep_obs = [], []
    src_pts, src_grp, src_col = [], [], []
    part_obs = []
    for gi, p in enumerate(parts):
        ob, extras = part_mesh(p)
        key = p["key"]
        for o in [ob] + extras:
            vg = o.vertex_groups.new(name=p["name"])
            vg.add(list(range(len(o.data.vertices))), 1.0, 'REPLACE')
            _set_region(o, 14 if o in extras else 0)
        co = mesh_arrays(ob)
        src_pts.append(co)
        src_grp.append(np.full(len(co), gi))
        src_col.append(point_colors(ob))
        part_obs.append(ob)
        part_obs.extend(extras)
        sep_obs.extend(extras)
        if sep_re.match(key):
            sep_obs.append(ob)
        else:
            vol_obs.append(ob)
    SP = np.concatenate(src_pts)
    SG = np.concatenate(src_grp)
    SC = np.concatenate(src_col)
    kd = kdtree.KDTree(len(SP))
    for i, q in enumerate(SP):
        kd.insert(Vector(q), i)
    kd.balance()
    # --- armature: one parentless bone per part
    bones = []
    for p in parts:
        o = np.array(p["origin"])
        ay = np.array(p["axis_y"])
        n = np.linalg.norm(ay)
        ay = ay / n if n > 1e-6 else np.array([0, 1, 0])
        bones.append(dict(name=p["name"], head=tuple(o), tail=tuple(o + ay * 0.03)))
    arm = cm.make_armature(bones)
    vox = C["voxel"] * (1.6 if quick else 1.0)
    eyes = []
    if sculpt is not None:
        anchors = {p["key"]: p for p in parts}
        spec = sculpt.build(anchors)
        for o in part_obs:
            bpy.data.objects.remove(o, do_unlink=True)
        union = cm.join(spec["union"])
        cm.fix_normals(union)
        cm.remesh(union, vox, smooth_iters=spec.get("smooth", 3), smooth_factor=0.5)
        cm.decimate(union, C["tris"] // (2 if quick else 1))
        _assign_from_parts(union, kd, SG, SC, names, vox)
        _set_region(union, 0)
        cm.smooth_weights(union, 0.5, 3)
        rigid = []
        for ob, gkey, region in spec["rigid"]:
            cm.fix_normals(ob)
            grp = key_to_name.get(gkey) if gkey else None
            _assign_from_parts(ob, kd, SG, SC, names, vox, grp)
            _set_region(ob, region)
            rigid.append(ob)
        eyes = spec.get("eyes", [])
        final = cm.join([union] + rigid)
    else:
        vol_src_faces = []
        for ob in vol_obs:
            me = ob.data
            me.calc_loop_triangles()
            tri = np.zeros(len(me.loop_triangles) * 3, dtype=np.int64)
            me.loop_triangles.foreach_get("vertices", tri)
            vol_src_faces.append((mesh_arrays(ob), tri.reshape(-1, 3), point_colors(ob), ob.vertex_groups[0].name))
        union = cm.join(vol_obs)
        cm.remesh(union, vox, smooth_iters=5, smooth_factor=0.5)
        cm.decimate(union, C["tris"] // (2 if quick else 1))
        thin_ob = _lost_thin(union, vol_src_faces, vox)
        _assign_from_parts(union, kd, SG, SC, names, vox)
        _set_region(union, 0)
        cm.smooth_weights(union, 0.5, 3)
        final = cm.join([union] + sep_obs + ([thin_ob] if thin_ob else []))
    final.name = species
    for pl in final.data.polygons:
        pl.use_smooth = True
    cm.bind_groups(final, arm)
    # --- UV + textures
    cm.uv_unwrap(final, margin=0.004)
    res = C["tex"] // (2 if quick else 1)
    gid = np.zeros(len(final.data.vertices))
    gname_to_idx = {n: i for i, n in enumerate(names)}
    for v in final.data.vertices:
        best, bw = 0, -1
        for g in v.groups:
            if g.weight > bw:
                bw = g.weight
                best = gname_to_idx.get(final.vertex_groups[g.group].name, 0)
        gid[v.index] = best
    ga = final.data.attributes.get("gid") or final.data.attributes.new("gid", 'FLOAT', 'POINT')
    ga.data.foreach_set("value", gid)
    maps = cm.raster_maps(final, res, ["col", "gid", "region"])
    albedo, nmap, rmap = surface(species, C["kind"], maps, res, [p["key"] for p in parts], eyes)
    tdir = os.path.join(OUT, "tex")
    os.makedirs(tdir, exist_ok=True)
    ia = cm.save_image(species + "_albedo", albedo, res, os.path.join(tdir, species + "_albedo.png"))
    inn = cm.save_image(species + "_normal", nmap, res, os.path.join(tdir, species + "_normal.png"), non_color=True)
    ir = cm.save_image(species + "_rough", rmap, res, os.path.join(tdir, species + "_rough.png"), non_color=True)
    mat = cm.make_material(species + "_mat", ia, inn, ir)
    final.data.materials.clear()
    final.data.materials.append(mat)
    for a_ in ("gid", "region"):
        if a_ in final.data.attributes:
            final.data.attributes.remove(final.data.attributes[a_])
    if "col" in final.data.color_attributes:
        final.data.color_attributes.remove(final.data.color_attributes["col"])
    cm.export_glb(os.path.join(OUT, species + ".glb"), [final, arm])
    print("DONE", species, "tris", cm.tri_count(final), "sculpt" if sculpt else "parts")


# ---------------------------------------------------------------- surface detail

def surface(species, kind, maps, res, keys, eyes=()):
    mask = maps["mask"]
    P = maps["pos"][mask]
    N = maps["nrm"][mask]
    base = maps["col"][mask].astype(np.float64)
    gid = np.rint(maps["gid"][mask][:, 0]).astype(int)
    gkeys = np.array(keys)[np.clip(gid, 0, len(keys) - 1)]
    region = np.rint(maps["region"][mask][:, 0]).astype(int) if "region" in maps else np.zeros(len(P), int)
    lum = base @ np.array([0.3, 0.55, 0.15])
    grade = {"dingo": (0.78, 0.95), "wallaby": (0.9, 1.0), "turkey": (1.0, 1.1), "crow": (1.0, 1.15)}.get(species, (1.0, 1.0))
    base = (lum[:, None] + (base - lum[:, None]) * grade[0]) * grade[1]
    dark_spot = region == 14         # separate small dark pieces: eyes / nose leather
    height = np.zeros(len(P))
    rough = np.full(len(P), 0.85)
    metal = np.zeros(len(P))
    col = base.copy()
    is_leg = np.array([bool(re.match(r"^(fleg|hleg|leg|arm|tib|tar|foot|farm|sleg)", k)) for k in gkeys])

    if kind == "fur":
        K = 480.0
        # strands run backwards along the body, downwards on legs
        q_body = np.stack([P[:, 0] * K, P[:, 1] * K, P[:, 2] * K * 0.3], 1)
        q_leg = np.stack([P[:, 0] * K, P[:, 1] * K * 0.3, P[:, 2] * K], 1)
        q = np.where(is_leg[:, None], q_leg, q_body)
        strands = cm.fbm3(q, 3, 3)
        clumps = cm.fbm3(P * 45.0, 3, 9)
        patch = cm.fbm3(P * 9.0, 3, 21)
        s = (strands - 0.5) * 2.0
        col = col * (0.88 + 0.2 * strands[:, None]) * (0.92 + 0.16 * clumps[:, None]) * (0.94 + 0.12 * patch[:, None])
        # agouti tips: a little lighter where strands peak
        col = col + (strands[:, None] > 0.62) * 0.04
        height = strands * 0.5 + clumps * 0.5
        rough[:] = 0.93
        pink = (base[:, 0] > base[:, 1] * 1.35) & (base[:, 2] > base[:, 1] * 0.8) & (base[:, 0] > 0.4) & (lum < 0.6)
        rough[pink] = 0.6
        height[pink] *= 0.2
        strength = 1.2
    elif kind == "feather":
        # feather scallops: elongated cells overlapping front-to-back
        K = 55.0
        q = np.stack([P[:, 0] * K, P[:, 1] * K, P[:, 2] * K * 0.6], 1)
        F1, F2, CID = cm.voronoi3(q, 0.7, 7)
        edge = cm.smoothstep(0.0, 0.12, F2 - F1)
        # tip of each feather (towards -z) darker/lighter gradient
        grad = np.clip(0.5 + (q[:, 2] - np.floor(q[:, 2]) - 0.5) * 0.8, 0, 1)
        barbs = cm.fbm3(np.stack([P[:, 0] * 600, P[:, 1] * 600, P[:, 2] * 60], 1), 2, 4)
        wing = np.array([k.startswith("wing") or k.startswith("tail") for k in gkeys])
        # primaries / tail: long parallel feathers with barbs
        lx = np.abs(P[:, 0]) * 38.0
        flight_edge = 1.0 - np.abs(np.mod(lx, 1.0) - 0.5) * 2.0
        f_shade = np.where(wing, 0.78 + 0.25 * cm.smoothstep(0.1, 0.9, flight_edge), 0.8 + 0.25 * edge * grad)
        col = col * f_shade[:, None] * (0.9 + 0.2 * barbs[:, None]) * (0.95 + 0.1 * CID[:, None])
        height = np.where(wing, cm.smoothstep(0.1, 0.9, flight_edge) * 0.8 + barbs * 0.3, edge * 0.7 + grad * 0.3 + barbs * 0.2)
        rough[:] = 0.86
        if species == "crow":
            rough[:] = 0.62          # slightly glossy plumage with a blue sheen
            col = col + np.array([0.004, 0.008, 0.022])
        scaly = np.array([k in ("tar", "foot") for k in gkeys])
        if scaly.any():
            sF1, sF2, sC = cm.voronoi3(P[scaly] * 180.0, 0.8, 5)
            dome = cm.smoothstep(0.0, 0.3, sF2 - sF1)
            col[scaly] = base[scaly] * (0.75 + 0.3 * dome)[:, None]
            height[scaly] = dome
            rough[scaly] = 0.55
        beak = (lum > 0.35) & (np.array([k == "head" for k in gkeys])) & (np.abs(base[:, 0] - base[:, 1]) < 0.25) & (P[:, 2] > np.percentile(P[:, 2], 90))
        rough[beak] = 0.35
        strength = 2.0
    elif kind == "frog":
        F1, F2, CID = cm.voronoi3(P * 160.0, 0.9, 3)
        warts = cm.smoothstep(0.35, 0.0, F1) * (CID > 0.55)
        mottle = cm.fbm3(P * 30.0, 3, 8)
        col = col * (0.85 + 0.25 * mottle[:, None]) * (1.0 + 0.1 * warts[:, None])
        height = warts * 0.8 + mottle * 0.2
        rough[:] = 0.32
        strength = 2.5
    elif kind == "insect":
        grain = cm.fbm3(P * 400.0, 2, 2)
        seg = np.abs(np.sin(P[:, 2] * 90.0))
        col = col * (0.85 + 0.2 * grain[:, None]) * (0.88 + 0.12 * seg[:, None])
        height = grain * 0.5 + (seg < 0.15) * 0.5
        rough[:] = 0.5
        strength = 2.0
    else:  # fish
        K = 70.0
        u = P[:, 2] * K
        v = P[:, 1] * K + 0.5 * np.floor(u)
        fu = u - np.floor(u)
        fv = v - np.floor(v)
        d = np.sqrt((fu - 1.0) ** 2 + (fv - 0.5) ** 2)
        arc = cm.smoothstep(0.55, 0.45, d) * cm.smoothstep(0.3, 0.45, d)
        col = col * (0.85 + 0.25 * (1 - arc)[:, None])
        height = 1.0 - d
        rough[:] = 0.28
        metal[:] = 0.35
        strength = 2.0
    # eyes and nose leather: glossy, no hair
    col[dark_spot] = base[dark_spot]
    rough[dark_spot] = 0.12
    height[dark_spot] = 0.0
    metal[dark_spot] = 0.0
    # ---- sculpted special regions
    if (region == 5).any():   # nose leather: pebbled, dark, moist, nostrils
        m = region == 5
        idx_all = np.where(m)[0]
        F1, F2, _ = cm.voronoi3(P[m] * 900.0, 0.8, 13)
        peb = cm.smoothstep(0.0, 0.3, F2 - F1)
        col[m] = np.array([0.05, 0.043, 0.042]) * (0.8 + 0.4 * peb)[:, None]
        rough[m] = 0.3
        height[m] = peb * 0.6
        c = P[m].mean(axis=0)
        zmax = P[m][:, 2].max()
        for sx in (-1, 1):
            dn = np.sqrt(((P[m][:, 0] - c[0] - sx * 0.008) / 0.0045) ** 2 + ((P[m][:, 1] - c[1] + 0.002) / 0.004) ** 2)
            hole = (dn < 1.0) & (P[m][:, 2] > zmax - 0.01)
            col[idx_all[hole]] = [0.01, 0.01, 0.01]
            height[idx_all[hole]] = -0.8
    for r_, cc, rr in ((6, (0.16, 0.14, 0.12), 0.35), (9, (0.09, 0.08, 0.08), 0.8), (8, (0.07, 0.05, 0.05), 0.45)):
        m = region == r_
        if m.any():
            col[m] = np.array(cc) * (0.85 + 0.3 * cm.fbm3(P[m] * 300.0, 2, r_))[:, None]
            rough[m] = rr
            height[m] = cm.fbm3(P[m] * 500.0, 2, r_ + 1) * 0.3
            metal[m] = 0.0
    if (region == 2).any() and len(eyes) > 0:
        m = np.where(region == 2)[0]
        best = np.zeros(len(m), int)
        bd = np.full(len(m), 9e9)
        for ei, e in enumerate(eyes):
            d = np.linalg.norm(P[m] - np.asarray(e["center"]), axis=1)
            closer = d < bd
            bd[closer] = d[closer]
            best[closer] = ei
        cosang = np.zeros(len(m))
        for ei, e in enumerate(eyes):
            sel = best == ei
            dvec = P[m][sel] - np.asarray(e["center"])
            dvec /= np.maximum(np.linalg.norm(dvec, axis=1, keepdims=True), 1e-9)
            cosang[sel] = dvec @ np.asarray(e["axis"])
        iris_c = np.array(eyes[0].get("iris", (0.5, 0.33, 0.12)))
        ang = np.arccos(np.clip(cosang, -1, 1))
        ce = np.tile(np.array([0.04, 0.035, 0.03]), (len(m), 1))
        iris_m = ang < 0.62
        ce[iris_m] = iris_c * (0.75 + 0.5 * np.clip(ang[iris_m] / 0.62, 0, 1))[:, None]
        pupil = eyes[0].get("pupil", "round")
        if pupil == "slit":
            ce[ang < 0.3] = [0.01, 0.01, 0.01]
        else:
            ce[ang < 0.3] = [0.01, 0.01, 0.01]
        ce[(ang > 0.55) & (ang < 0.66)] *= 0.4
        col[m] = ce
        rough[m] = 0.04
        height[m] = 0.0
        metal[m] = 0.0
    albedo = np.zeros((res, res, 3), np.float32)
    albedo[mask] = np.clip(col, 0, 1)
    hmap = np.zeros((res, res), np.float32)
    hmap[mask] = height
    # R channel: fur length factor for the in-engine shell fur
    furlen = np.ones(len(P))
    for i, k in enumerate(gkeys):
        pass
    kk = gkeys
    furlen[np.char.startswith(kk.astype(str), "head")] = 0.28
    furlen[np.char.startswith(kk.astype(str), "jaw")] = 0.3
    furlen[np.char.startswith(kk.astype(str), "ear")] = 0.35
    furlen[np.char.startswith(kk.astype(str), "neck")] = 0.85
    furlen[np.char.startswith(kk.astype(str), "tail")] = 1.35
    legk = np.char.startswith(kk.astype(str), "fleg") | np.char.startswith(kk.astype(str), "hleg") | np.char.startswith(kk.astype(str), "arm")
    furlen[legk] = 0.55
    low = legk & (np.char.endswith(kk.astype(str), "1") | np.char.endswith(kk.astype(str), "2") | np.char.endswith(kk.astype(str), "1L") | np.char.endswith(kk.astype(str), "2L") | np.char.endswith(kk.astype(str), "1R") | np.char.endswith(kk.astype(str), "2R"))
    furlen[low] = 0.35
    furlen[region != 0] = 0.0
    rm = np.zeros((res, res, 3), np.float32)
    rm[mask, 0] = np.clip(furlen / 1.4, 0, 1)
    rm[mask, 1] = np.clip(rough, 0.03, 1)
    rm[mask, 2] = np.clip(metal, 0, 1)
    albedo = cm.dilate(albedo, mask, 10)
    rm = cm.dilate(rm, mask, 10)
    nmap = cm.height_to_normal(hmap, mask, strength * res / 1024.0)
    nmap = cm.dilate(nmap, mask, 10)
    return albedo, nmap, rm


main()
