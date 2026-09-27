"""Build skinned reptile models (monitor, croc, skink) for VaranMod.

Run:  blender -b --python tools/modelgen/build_reptile.py -- <species> [--quick]
Outputs game/assets/creatures/<species>.glb and <species>.rig.json
(bone rest frames used by the in-game procedural animation).
Rest pose replicates ReptileRig's neutral standing pose exactly.
"""
import sys
import os
import json
import math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmodel as cm  # noqa: E402
import bpy  # noqa: E402
import bmesh  # noqa: E402
from mathutils import Vector  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "game", "assets", "creatures")

SPECIES = {
    "monitor": dict(
        t=[0.0, 0.03, 0.065, 0.1, 0.135, 0.17, 0.215, 0.26, 0.31, 0.36, 0.41, 0.46, 0.52, 0.6, 0.69, 0.79, 0.89, 1.0],
        w=[0.011, 0.022, 0.03, 0.031, 0.03, 0.033, 0.047, 0.06, 0.066, 0.064, 0.055, 0.041, 0.031, 0.024, 0.018, 0.012, 0.007, 0.0015],
        h=[0.008, 0.017, 0.025, 0.029, 0.03, 0.032, 0.039, 0.045, 0.048, 0.046, 0.042, 0.038, 0.033, 0.028, 0.022, 0.015, 0.008, 0.0015],
        sh=6, pv=10, hb=3, upper=0.072, lower=0.066, lr=0.018, clearance=0.026, head_up=0.024,
        tex=2048, tris=18000, voxel=0.0021,
    ),
    "croc": dict(
        t=[0.0, 0.05, 0.1, 0.14, 0.18, 0.22, 0.29, 0.36, 0.43, 0.5, 0.58, 0.67, 0.76, 0.85, 0.93, 1.0],
        w=[0.018, 0.028, 0.036, 0.05, 0.055, 0.07, 0.085, 0.088, 0.075, 0.052, 0.04, 0.03, 0.022, 0.014, 0.008, 0.002],
        h=[0.01, 0.015, 0.02, 0.03, 0.04, 0.048, 0.054, 0.055, 0.05, 0.05, 0.046, 0.04, 0.032, 0.024, 0.014, 0.004],
        sh=5, pv=8, hb=4, upper=0.055, lower=0.048, lr=0.027, clearance=0.02, head_up=0.0,
        tex=2048, tris=16000, voxel=0.0024, claw=0.7,
    ),
    "skink": dict(
        t=[0.0, 0.03, 0.07, 0.1, 0.14, 0.2, 0.28, 0.36, 0.44, 0.52, 0.62, 0.72, 0.82, 0.91, 1.0],
        w=[0.02, 0.04, 0.05, 0.05, 0.058, 0.066, 0.07, 0.07, 0.066, 0.058, 0.045, 0.034, 0.022, 0.012, 0.003],
        h=[0.015, 0.03, 0.04, 0.045, 0.05, 0.054, 0.056, 0.056, 0.052, 0.05, 0.04, 0.03, 0.02, 0.012, 0.003],
        sh=4, pv=8, hb=2, upper=0.045, lower=0.04, lr=0.016, clearance=0.012, head_up=0.01,
        tex=1024, tris=6000, voxel=0.004, claw=0.4,
    ),
}


def v3(x, y, z):
    return np.array([x, y, z], dtype=np.float64)


def norm(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def rotate_about(v, axis, ang):
    axis = norm(axis)
    return v * math.cos(ang) + np.cross(axis, v) * math.sin(ang) + axis * np.dot(axis, v) * (1 - math.cos(ang))


# ------------------------------------------------------------------ rest pose (mirrors ReptileRig)

def rest_pose(S):
    t = np.array(S["t"])
    w = np.array(S["w"], dtype=np.float64)
    h = np.array(S["h"], dtype=np.float64)
    sh, pv, hb = S["sh"], S["pv"], S["hb"]
    # the rig shrinks the tube inside the skull
    rw = w.copy()
    rh = h.copy()
    rw[:hb] *= 0.45
    rh[:hb] *= 0.45
    n = len(t)
    pts = np.zeros((n, 3))
    for i in range(n):
        belly = rh[i] * 0.62
        l2 = S["clearance"]
        if i > pv:
            l2 *= min(max(1.0 - (i - pv) / 3.0, 0.0), 1.0)
        y = belly + l2
        if i < sh:
            fr = (sh - i) / sh
            y += S["head_up"] * fr
        pts[i] = v3(0.0, y, t[sh] - t[i])
    up = v3(0, 1, 0)
    side = v3(1, 0, 0)  # _vis_side on flat ground: UP x FWD
    f = v3(0, 0, 1)
    reach = S["upper"] + S["lower"]
    legs = []
    for k in range(4):
        gi = sh if k < 2 else pv
        s = -1.0 if k % 2 == 0 else 1.0
        front = k < 2
        hip = pts[gi] + side * (rw[gi] * 0.62 * s) - up * rh[gi] * 0.18
        foot = pts[gi] + side * (rw[gi] * 0.62 * s + reach * 0.82 * s) + f * ((0.22 if front else -0.08) * reach)
        foot[1] = 0.0
        lr = S["lr"]
        wrist = foot + up * lr * 0.9
        a, b = S["upper"], S["lower"]
        hf = wrist - hip
        d = min(max(np.linalg.norm(hf), 0.001), (a + b) * 0.995)
        dr = norm(hf)
        sd2 = side * s
        pole = norm(sd2 + up * 0.7 + f * (-0.3 if front else 0.3))
        along = (a * a - b * b + d * d) / (2 * d)
        hgt = math.sqrt(max(0.0, a * a - along * along))
        pp = norm(pole - dr * np.dot(pole, dr))
        knee = hip + dr * along + pp * hgt
        wrist = hip + dr * d
        toe_dir = norm(f * (1.0 if front else 0.45) + sd2 * (0.45 if front else 0.7))
        palm = wrist + toe_dir * lr * 0.9 - up * lr * 0.45
        legs.append(dict(hip=hip, knee=knee, wrist=wrist, palm=palm, toe_dir=toe_dir, s=s, front=front, sd2=sd2))
    # head frame (rig: head_mi)
    hpos = pts[hb]
    hdir = pts[0] - hpos
    hl = np.linalg.norm(hdir)
    hdir = hdir / hl
    hup = norm(up - hdir * np.dot(hdir, up))
    hsd = norm(np.cross(hup, hdir))
    head_origin = hpos - hup * rh[hb] * 0.2
    return dict(pts=pts, rw=rw, rh=rh, legs=legs, hdir=hdir, hup=hup, hsd=hsd, hl=hl,
                head_origin=head_origin, hpos=hpos)


def head_to_world(R, u, x, y):
    """head-local unit coords (x lateral, y up, u along 0..1) -> Godot rest coords"""
    return R["head_origin"] + R["hsd"] * (x * R["hl"]) + R["hup"] * (y * R["hl"]) + R["hdir"] * (u * R["hl"])


# ------------------------------------------------------------------ geometry

def interp(ts, vals, t):
    return float(np.interp(t, ts, vals))


def body_loft(bm, S, R, species):
    t = np.array(S["t"])
    w = np.array(S["w"])
    h = np.array(S["h"])
    sh, pv, hb = S["sh"], S["pv"], S["hb"]
    pts = R["pts"]
    sh_t, pv_t = t[sh], t[pv]
    t0 = t[hb] - 0.012
    ts = np.concatenate([np.linspace(t0, 0.9, 230), np.linspace(0.9, 0.9995, 30)[1:]])
    ring = 48
    centers = []
    secs = []
    for tt in ts:
        # chain centre (rest chain is straight in z; interpolate y)
        y = np.interp(tt, t, pts[:, 1])
        z = t[sh] - tt
        centers.append((0.0, y, z))
    rings = []
    C = [cm.gv(c) for c in centers]
    for i, tt in enumerate(ts):
        ww = interp(t, w, tt)
        hh = interp(t, h, tt)
        if tt < t[hb] + 0.02:
            # blend into the skull size
            k = (t[hb] + 0.02 - tt) / 0.032
            ww *= 1.0 - 0.08 * k
        ww *= 1.0 + 0.1 * math.exp(-((tt - sh_t) / 0.025) ** 2) + 0.12 * math.exp(-((tt - pv_t) / 0.025) ** 2)
        hb_scale = 0.62
        if species == "monitor" and tt < sh_t:
            hb_scale = 0.62 + 0.28 * math.exp(-((tt - 0.12) / 0.04) ** 2)   # baggy throat
        tail = 0.0
        if tt > pv_t + 0.03:
            tail = min(max((tt - pv_t - 0.03) / 0.17, 0.0), 1.0)
            tail = tail * tail * (3 - 2 * tail)
        verts = []
        for kk in range(ring):
            th = 2 * math.pi * kk / ring
            cs, sn = math.cos(th), math.sin(th)
            x = cs * ww
            if sn >= 0:
                yy = sn * hh * (1.0 + 0.08 * sn ** 6)
                x *= 1.0 + 0.07 * (1.0 - sn)
            else:
                yy = sn * hh * hb_scale
                x *= 1.0 + 0.05 * (1.0 + sn)
            x *= 1.0 - (0.28 if species != "croc" else 0.1) * tail
            if sn > 0:
                keel = 0.3 if species != "croc" else 0.9
                yy *= 1.0 + keel * tail * sn ** 8
            verts.append(bm.verts.new(C[i] + Vector((x, 0, 0)) + Vector((0, 0, yy))))
        rings.append(verts)
    for i in range(len(rings) - 1):
        r0, r1 = rings[i], rings[i + 1]
        for k in range(ring):
            k2 = (k + 1) % ring
            bm.faces.new((r0[k], r1[k], r1[k2], r0[k2]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))


def superellipse_loft_head(bm, R, stations, top_fn, bot_fn, ring=40, exp=2.4):
    """stations: list of (u, half_width, top, bottom); head-local coords."""
    rings = []
    for (u, hw, top, bot) in stations:
        verts = []
        for k in range(ring):
            th = 2 * math.pi * k / ring
            cs, sn = math.cos(th), math.sin(th)
            # superellipse
            sx = math.copysign(abs(cs) ** (2.0 / exp), cs)
            sy = math.copysign(abs(sn) ** (2.0 / exp), sn)
            x = sx * hw
            y = sy * (top if sn >= 0 else bot)
            x, y = top_fn(u, x, y, sn)
            p = head_to_world(R, u, x, y)
            verts.append(bm.verts.new(cm.gv(p)))
        rings.append(verts)
    for i in range(len(rings) - 1):
        r0, r1 = rings[i], rings[i + 1]
        for k in range(ring):
            k2 = (k + 1) % ring
            bm.faces.new((r0[k], r1[k], r1[k2], r0[k2]))
    # caps
    bm.faces.new(rings[0])
    tip = head_to_world(R, stations[-1][0] + 0.012, 0, 0.0)
    tv = bm.verts.new(cm.gv(tip))
    last = rings[-1]
    for k in range(ring):
        bm.faces.new((last[k], tv, last[(k + 1) % ring]))


HEADS = {
    "monitor": dict(
        skull=[(0.0, 0.30, 0.30, 0.04), (0.1, 0.31, 0.32, 0.04), (0.2, 0.305, 0.315, 0.04), (0.3, 0.285, 0.29, 0.04),
               (0.42, 0.25, 0.235, 0.035), (0.55, 0.21, 0.195, 0.035), (0.68, 0.172, 0.162, 0.03), (0.8, 0.142, 0.137, 0.028),
               (0.9, 0.115, 0.112, 0.025), (0.96, 0.085, 0.082, 0.02), (0.99, 0.045, 0.045, 0.012)],
        jaw=[(0.0, 0.27, 0.02, 0.21), (0.15, 0.27, 0.02, 0.2), (0.35, 0.235, 0.02, 0.155), (0.55, 0.195, 0.02, 0.115),
             (0.75, 0.15, 0.02, 0.085), (0.88, 0.11, 0.02, 0.065), (0.96, 0.06, 0.018, 0.035)],
        eye=(0.3, 0.232, 0.175, 0.062), nostril=(0.87, 0.085, 0.085), teeth=0.1,
    ),
    "croc": dict(
        skull=[(0.0, 0.34, 0.22, 0.04), (0.12, 0.34, 0.25, 0.04), (0.25, 0.3, 0.2, 0.035), (0.4, 0.23, 0.12, 0.03),
               (0.55, 0.18, 0.095, 0.03), (0.7, 0.16, 0.085, 0.025), (0.82, 0.155, 0.085, 0.025), (0.9, 0.17, 0.09, 0.025),
               (0.96, 0.15, 0.08, 0.02), (0.995, 0.08, 0.05, 0.015)],
        jaw=[(0.0, 0.31, 0.02, 0.17), (0.2, 0.3, 0.02, 0.14), (0.45, 0.2, 0.02, 0.09), (0.7, 0.155, 0.02, 0.07),
             (0.88, 0.16, 0.02, 0.06), (0.97, 0.09, 0.02, 0.03)],
        eye=(0.17, 0.14, 0.25, 0.055), nostril=(0.95, 0.035, 0.09), teeth=0.16,
    ),
    "skink": dict(
        skull=[(0.0, 0.47, 0.42, 0.05), (0.25, 0.47, 0.42, 0.05), (0.5, 0.4, 0.34, 0.045), (0.72, 0.31, 0.26, 0.04),
               (0.88, 0.22, 0.18, 0.035), (0.98, 0.1, 0.08, 0.02)],
        jaw=[(0.0, 0.44, 0.02, 0.3), (0.35, 0.4, 0.02, 0.25), (0.7, 0.28, 0.02, 0.15), (0.95, 0.08, 0.02, 0.04)],
        eye=(0.45, 0.37, 0.22, 0.1), nostril=(0.93, 0.08, 0.1), teeth=0.0,
    ),
}


def build_head(R, species):
    H = HEADS[species]
    bm = bmesh.new()

    def skull_shape(u, x, y, sn):
        if species == "monitor":
            # flattened crown, brow ridge over the eye, slight canthal ridge
            if sn > 0:
                ey = H["eye"]
                brow = 0.045 * math.exp(-((u - ey[0]) / 0.1) ** 2) * math.exp(-((abs(x) - ey[1] * 0.85) / 0.07) ** 2)
                y += brow
                y -= 0.03 * math.exp(-(x / 0.1) ** 2) * math.exp(-((u - 0.25) / 0.15) ** 2)  # frontal depression
        if species == "croc" and sn > 0:
            ey = H["eye"]
            y += 0.08 * math.exp(-((u - ey[0]) / 0.07) ** 2) * math.exp(-((abs(x) - ey[1]) / 0.06) ** 2)
            y += 0.03 * math.exp(-((u - 0.96) / 0.03) ** 2) * math.exp(-(x / 0.06) ** 2)  # nostril bump
        return x, y

    superellipse_loft_head(bm, R, H["skull"], skull_shape, None)
    skull = cm.new_object("skull", bm)
    # jaw: in jaw-local coordinates the hinge is at u=0.04 (rig: jaw offset z 0.04)
    bm = bmesh.new()

    def jaw_shape(u, x, y, sn):
        return x, y

    superellipse_loft_head(bm, R, [(u + 0.04, hw, tp, bt) for (u, hw, tp, bt) in H["jaw"]], jaw_shape, None, ring=32)
    jaw = cm.new_object("jaw", bm)
    # eyes
    bm = bmesh.new()
    ey = H["eye"]
    for s in (-1, 1):
        c = head_to_world(R, ey[0], ey[1] * s, ey[2])
        r = ey[3] * R["hl"]
        cm.ellipsoid(bm, tuple(c), (r, r * 0.92, r), seg=24, rings=14)
    eyes = cm.new_object("eyes", bm)
    # teeth
    teeth = None
    jteeth = None
    if H["teeth"] > 0:
        bm = bmesh.new()
        bmj = bmesh.new()
        u = 0.18
        sk = H["skull"]
        jw = H["jaw"]
        us = [s[0] for s in sk]
        ws = [s[1] for s in sk]
        jus = [s[0] + 0.04 for s in jw]
        jws = [s[1] for s in jw]
        while u < 0.95:
            for s in (-1, 1):
                wi = interp(us, ws, u) * (0.78 if species == "monitor" else 0.9)
                b = head_to_world(R, u, wi * s, 0.005 if species == "monitor" else -0.01)
                tp = head_to_world(R, u + 0.01, wi * s, (0.005 if species == "monitor" else -0.01) - H["teeth"] * (0.3 if species == "monitor" else 0.4))
                cm.cone(bm, tuple(b), tuple(tp), 0.016 * R["hl"], 6)
                wj = interp(jus, jws, u - 0.02) * (0.74 if species == "monitor" else 0.86)
                b2 = head_to_world(R, u - 0.02, wj * s, 0.0 if species == "monitor" else 0.012)
                tp2 = head_to_world(R, u - 0.01, wj * s, (0.0 if species == "monitor" else 0.012) + H["teeth"] * (0.28 if species == "monitor" else 0.4))
                cm.cone(bmj, tuple(b2), tuple(tp2), 0.014 * R["hl"], 6)
            u += 0.075 if species == "croc" else 0.095
        teeth = cm.new_object("teeth", bm)
        jteeth = cm.new_object("jteeth", bmj)
    return skull, jaw, eyes, teeth, jteeth


def build_legs(R, S, species):
    bm = bmesh.new()
    claws = bmesh.new()
    lr = S["lr"]
    up = v3(0, 1, 0)
    toe_lens_f = [0.55, 0.8, 1.0, 1.05, 0.7]
    toe_lens_h = [0.5, 0.75, 1.0, 1.25, 0.65]
    nt = 5
    for k, L in enumerate(R["legs"]):
        hind = not L["front"]
        hip, knee, wrist, palm = L["hip"], L["knee"], L["wrist"], L["palm"]
        # start the limb inside the body so the union blends into a shoulder/hip
        inner = hip - L["sd2"] * lr * 1.2
        r_up = lr * (1.75 if hind else 1.45)
        up_pts = [inner, hip, hip + (knee - hip) * 0.35, hip + (knee - hip) * 0.7, knee]
        up_r = [r_up * 1.2, r_up * 1.15, r_up * (1.1 if hind else 1.05), lr * 1.2, lr * 1.02]
        cm.tube(bm, [tuple(p) for p in up_pts], up_r, ring=20)
        lo_pts = [knee, knee + (wrist - knee) * 0.3, knee + (wrist - knee) * 0.75, wrist]
        lo_r = [lr * 1.02, lr * 1.0, lr * 0.78, lr * 0.66]
        cm.tube(bm, [tuple(p) for p in lo_pts], lo_r, ring=18)
        # hand: flat palm
        td = L["toe_dir"]
        side_h = norm(np.cross(up, td))
        cm.tube(bm, [tuple(wrist), tuple(wrist + (palm - wrist) * 0.5), tuple(palm)], [lr * 0.7, lr * 0.75, lr * 0.8], ring=14, flat=0.55)
        cm.ellipsoid(bm, tuple(palm), (lr * 1.25, lr * 0.5, lr * 1.35), basis=(tuple(side_h), tuple(up), tuple(td)), seg=16, rings=8)
        lens = toe_lens_h if hind else toe_lens_f
        for ti in range(nt):
            ang = (ti - 2) * 0.34 * L["s"]
            d = rotate_about(td, up, ang)
            base = palm + d * lr * 0.8
            tl = lr * 2.6 * lens[ti]
            mid = base + d * tl * 0.55 + up * lr * 0.12
            tip = base + d * tl - up * lr * 0.18
            tip[1] = max(tip[1], lr * 0.2)
            cm.tube(bm, [tuple(palm + d * lr * 0.3), tuple(base), tuple(mid), tuple(tip)], [lr * 0.42, lr * 0.36, lr * 0.3, lr * 0.24], ring=10)
            cf = S.get("claw", 1.0)
            ctip = tip + d * lr * 1.0 * cf - up * lr * 0.4 * cf
            cm.cone(claws, tuple(tip - d * lr * 0.1), tuple(ctip), lr * 0.19 * (0.6 + 0.4 * cf), 8)
    legs = cm.new_object("legs", bm)
    claw_ob = cm.new_object("claws", claws)
    return legs, claw_ob


# ------------------------------------------------------------------ skeleton

def bone_frames(R, S):
    """Rest frames (origin, dir, up) per bone - identical formulas are used at runtime."""
    pts = R["pts"]
    n = len(pts)
    hb = S["hb"]
    up = v3(0, 1, 0)
    frames = {}
    bones = []
    frames["head"] = (R["hpos"], R["hdir"], R["hup"])
    bones.append(dict(name="head", head=tuple(R["hpos"]), tail=tuple(pts[0]), parent="sp%d" % hb, up=tuple(R["hup"])))
    hinge = R["head_origin"] + R["hdir"] * 0.04 * R["hl"]
    frames["jaw"] = (hinge, R["hdir"], R["hup"])
    bones.append(dict(name="jaw", head=tuple(hinge), tail=tuple(hinge + R["hdir"] * R["hl"] * 0.9), parent="head", up=tuple(R["hup"])))
    for i in range(hb, n - 1):
        d = norm(pts[i] - pts[i + 1])
        u = norm(up - d * np.dot(d, up))
        frames["sp%d" % i] = (pts[i], d, u)
        par = "sp%d" % (i + 1) if i + 1 <= n - 2 else None
        bones.append(dict(name="sp%d" % i, head=tuple(pts[i + 1]), tail=tuple(pts[i]), parent=par, up=tuple(u)))
    for k, L in enumerate(R["legs"]):
        gi = S["sh"] if k < 2 else S["pv"]
        pa = "sp%d" % gi
        d1 = norm(L["knee"] - L["hip"])
        u1 = norm(up - d1 * np.dot(d1, up))
        frames["leg%d_a" % k] = (L["hip"], d1, u1)
        bones.append(dict(name="leg%d_a" % k, head=tuple(L["hip"]), tail=tuple(L["knee"]), parent=pa, up=tuple(u1)))
        d2 = norm(L["wrist"] - L["knee"])
        u2 = norm(up - d2 * np.dot(d2, up)) if abs(np.dot(d2, up)) < 0.98 else norm(L["sd2"])
        frames["leg%d_b" % k] = (L["knee"], d2, u2)
        bones.append(dict(name="leg%d_b" % k, head=tuple(L["knee"]), tail=tuple(L["wrist"]), parent="leg%d_a" % k, up=tuple(u2)))
        d3 = L["toe_dir"]
        frames["leg%d_c" % k] = (L["wrist"], d3, up)
        bones.append(dict(name="leg%d_c" % k, head=tuple(L["wrist"]), tail=tuple(L["wrist"] + d3 * S["lr"] * 4.0), parent="leg%d_b" % k, up=tuple(up)))
    return bones, frames


# ------------------------------------------------------------------ texture

def texture(species, S, R, maps, res):
    mask = maps["mask"]
    P = maps["pos"][mask]
    N = maps["nrm"][mask]
    region = maps["region"][mask][:, 0] if "region" in maps else np.zeros(len(P))
    t = np.array(S["t"])
    sh, pv, hb = S["sh"], S["pv"], S["hb"]
    pts = R["pts"]
    # body parameter t and angle around the body
    tt = t[sh] - P[:, 2]
    yc = np.interp(tt, t, pts[:, 1])
    wv = np.interp(tt, t, np.array(S["w"]))
    hv = np.interp(tt, t, np.array(S["h"]))
    rel_y = (P[:, 1] - yc) / np.maximum(hv, 1e-4)
    rel_x = P[:, 0] / np.maximum(wv, 1e-4)
    ang_up = np.clip(rel_y / np.maximum(np.sqrt(rel_x ** 2 + rel_y ** 2), 1e-4), -1, 1)   # ~sin(theta)
    on_leg = (np.abs(P[:, 0]) > wv * 1.25) | ((P[:, 1] < yc - hv * 0.9) & (tt > t[sh] - 0.04) & (tt < t[pv] + 0.06))
    on_leg &= region < 0.5
    # head-local coordinates
    rel = P - R["head_origin"]
    hu = rel @ R["hdir"] / R["hl"]
    hx = rel @ R["hsd"] / R["hl"]
    hy = rel @ R["hup"] / R["hl"]
    on_head = (hu > -0.05) & (region < 0.5) & ~on_leg
    rng_seed = {"monitor": 1, "croc": 2, "skink": 3}[species]

    # scales (voronoi in rest space)
    cell = {"monitor": 0.0034, "croc": 0.006, "skink": 0.0045}[species]
    csize = np.full(len(P), cell)
    csize[on_head] *= 1.9
    csize[on_leg] *= 0.8
    F1, F2, CID = cm.voronoi3(P / csize[:, None], 0.8, rng_seed)
    edge = F2 - F1
    dome = cm.smoothstep(0.0, 0.35, edge)
    height = dome * 0.8 + (1 - F1 * 1.3).clip(0, 1) * 0.2

    if species == "monitor":
        base = np.array([0.075, 0.08, 0.085])
        cream = np.array([0.86, 0.76, 0.45])
        belly_c = np.array([0.78, 0.7, 0.45])
        col = np.tile(base, (len(P), 1))
        # spot field: cells of a coarser voronoi decide which scales are pale
        sF1, sF2, sC = cm.voronoi3(P / 0.011, 0.9, 11)
        band = np.mod((tt - 0.1) * 19.0, 1.0)
        body = (tt > 0.1) & (tt < 0.46) & ~on_leg & ~on_head
        spot = body & (band < 0.36) & (sC > 0.5) & (ang_up > -0.45)
        fleck = body & (CID > 0.93) & (ang_up > -0.2)
        tailb = (tt >= 0.46) & ~on_leg & (np.mod((tt - 0.46) * 14.0, 1.0) < 0.3) & (CID > 0.2)
        col[spot] = cream * (0.9 + 0.2 * CID[spot][:, None])
        col[fleck] = cream * 0.75
        col[tailb] = cream * (0.85 + 0.15 * CID[tailb][:, None])
        # neck: fine speckling
        neck = (tt > 0.1) & (tt < t[sh]) & ~on_head & (CID > 0.78) & (ang_up > -0.3)
        col[neck] = cream * 0.8
        # belly: pale with dark transverse bars
        bel = (ang_up < -0.55) & ~on_leg & (tt < 0.5)
        bars = np.mod(tt * 30.0, 1.0) < 0.3
        col[bel] = np.where(bars[bel][:, None], base * 1.4, belly_c)
        # legs: dark with dense pale spots, banded toes
        lg = on_leg & (CID > 0.8)
        col[lg] = cream * 0.85
        # head: dark crown with pale speckles, barred lips and chin, pale snout bands
        hd = on_head & (hu < 1.1)
        spk = hd & (CID > 0.72) & (hy > 0.05)
        col[spk] = cream * 0.8
        snout_band = hd & (hu > 0.5) & (np.mod(hu * 7.0, 1.0) < 0.3) & (hy > 0.02)
        col[snout_band] = cream * 0.85
        lips = hd & (np.abs(hy) < 0.06)
        chin = (region > 3.5) & (region < 4.5)
        lipbar = (lips | chin) & (np.mod(hu * 9.0, 1.0) < 0.45)
        col[lips | chin] = belly_c * 0.95
        col[lipbar] = base * 1.3
    elif species == "croc":
        base = np.array([0.2, 0.22, 0.14])
        dark = np.array([0.08, 0.09, 0.06])
        belly_c = np.array([0.72, 0.68, 0.52])
        col = np.tile(base, (len(P), 1))
        bands = (np.mod(tt * 18.0, 1.0) < 0.3) & (ang_up > 0.1) & (tt > 0.2)
        col[bands] = dark
        col *= (0.85 + 0.3 * cm.fbm3(P * 40.0, 3, 5))[:, None]
        bel = ang_up < -0.35
        col[bel] = belly_c
        # osteoderm rows on the back: raised rectangular scutes
        grid_t = np.mod(tt * 70.0, 1.0)
        grid_x = np.mod(np.arctan2(P[:, 0], P[:, 1] - yc + 1e-5) * 7.0, 1.0)
        scute = (ang_up > 0.45) & (tt > t[hb]) & (tt < 0.75)
        sh_h = cm.smoothstep(0.0, 0.2, np.minimum(grid_t, 1 - grid_t)) * cm.smoothstep(0.0, 0.2, np.minimum(grid_x, 1 - grid_x))
        height = np.where(scute, sh_h * 1.5 + dome * 0.2, height)
    else:  # skink
        base = np.array([0.45, 0.34, 0.2])
        stripe = np.array([0.12, 0.09, 0.06])
        belly_c = np.array([0.8, 0.76, 0.6])
        col = np.tile(base, (len(P), 1))
        rel_ang = np.abs(rel_x)
        side_band = (rel_ang > 0.62) & (ang_up > -0.25) & (ang_up < 0.35) & ~on_leg
        col[side_band] = stripe
        edge = (rel_ang > 0.5) & (ang_up >= 0.35) & (ang_up < 0.5) & ~on_leg
        col[edge] = base * 1.45
        col[(ang_up > 0.8)] = base * 1.2
        col[ang_up < -0.4] = belly_c
        col *= (0.9 + 0.2 * CID)[:, None]

    # scale shading: grooves darker, slight per-scale variation
    col = col * (0.72 + 0.34 * dome)[:, None] * (0.94 + 0.12 * CID)[:, None]
    rough = 0.82 - 0.35 * dome
    if species == "skink":
        rough = 0.45 - 0.2 * dome

    # mouth interior (skull underside plate / jaw top)
    mouth_pink = np.array([0.68, 0.38, 0.38])
    mouth = (on_head & (hy < 0.012) & (hy > -0.06) & (hu > 0.02) & (hu < 1.0) & (np.abs(hx) < 0.3)) & (N @ R["hup"] < -0.5)
    jtop = (region > 3.5) & (region < 4.5) & (N @ R["hup"] > 0.5)
    col[mouth | jtop] = mouth_pink
    height[mouth | jtop] = 0.3
    # nostrils
    ns = HEADS[species]["nostril"]
    nd = np.sqrt((hu - ns[0]) ** 2 + (np.abs(hx) - ns[1]) ** 2 + ((hy - ns[2]) * 1.5) ** 2)
    nost = on_head & (nd < 0.03)
    col[nost] = [0.02, 0.02, 0.02]
    height[nost] = -0.8
    # claws, teeth, eyes
    claw = (region > 0.5) & (region < 1.5)
    col[claw] = [0.5, 0.45, 0.38]
    rough[claw] = 0.35
    height[claw] = 0.0
    teeth = (region > 2.5) & (region < 3.5)
    col[teeth] = [0.85, 0.82, 0.72]
    rough[teeth] = 0.3
    height[teeth] = 0.0
    eye = (region > 1.5) & (region < 2.5)
    if eye.any():
        ey = HEADS[species]["eye"]
        # direction from eye centre in head-local space
        ex = np.abs(hx[eye]) - ey[1]
        eyy = hy[eye] - ey[2]
        eu = hu[eye] - ey[0]
        r_out = np.sqrt(eu ** 2 + eyy ** 2) / ey[3]
        facing = ex / ey[3]
        iris = np.array([0.55, 0.36, 0.12]) if species != "croc" else np.array([0.6, 0.55, 0.2])
        c_e = np.where((r_out < 0.55)[:, None], iris, [0.05, 0.04, 0.03])
        pupil = (r_out < 0.22) if species != "croc" else ((np.abs(eu) / ey[3] < 0.1) & (r_out < 0.5))
        c_e[pupil] = [0.01, 0.01, 0.01]
        c_e[facing < 0.2] = base * 1.2   # eyelid rim
        col[eye] = c_e
        rough[eye] = 0.06
        height[eye] = 0.0

    albedo = np.zeros((res, res, 3), np.float32)
    albedo[mask] = np.clip(col, 0, 1)
    hmap = np.zeros((res, res), np.float32)
    hmap[mask] = height
    rmap = np.zeros((res, res, 3), np.float32)
    rmap[mask, 1] = np.clip(rough, 0.03, 1)
    rmap[mask, 2] = 0.0
    albedo = cm.dilate(albedo, mask, 10)
    rmap = cm.dilate(rmap, mask, 10)
    strength = {"monitor": 3.0, "croc": 4.0, "skink": 1.5}[species] * res / 2048.0
    nmap = cm.height_to_normal(hmap, mask, strength)
    nmap = cm.dilate(nmap, mask, 10)
    # albedo is authored in sRGB-ish values; images are saved as sRGB PNGs
    return albedo, nmap, rmap


# ------------------------------------------------------------------ main

def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    species = argv[0] if argv else "monitor"
    quick = "--quick" in argv
    S = SPECIES[species]
    cm.clear_scene()
    R = rest_pose(S)
    # --- union parts
    bm = bmesh.new()
    body_loft(bm, S, R, species)
    body = cm.new_object("body", bm)
    skull, jaw, eyes, teeth, jteeth = build_head(R, species)
    legs, claws = build_legs(R, S, species)
    union = cm.join([body, skull, legs])
    cm.fix_normals(union)
    vox = S["voxel"] * (2.0 if quick else 1.0)
    cm.remesh(union, vox, smooth_iters=6, smooth_factor=0.5)
    cm.decimate(union, S["tris"] // (3 if quick else 1))
    cm.shade_smooth(union)
    print("union tris", cm.tri_count(union))
    # --- armature + weights
    bones, frames = bone_frames(R, S)
    arm = cm.make_armature(bones)
    cm.bind_auto(union, arm)
    # region attribute: 0 body, 1 claw, 2 eye, 3 teeth, 4 jaw
    parts = [(union, 0.0, None), (claws, 1.0, None), (eyes, 2.0, "head"), (jaw, 4.0, "jaw")]
    if teeth is not None:
        parts.append((teeth, 3.0, "head"))
        parts.append((jteeth, 3.0, "jaw"))
    for ob, reg, grp in parts:
        at = ob.data.attributes.new("region", 'FLOAT', 'POINT')
        at.data.foreach_set("value", [reg] * len(ob.data.vertices))
        if grp:
            cm.rigid_group(ob, grp)
        cm.shade_smooth(ob)
    # claws -> nearest hand bone
    me = claws.data
    for k in range(4):
        claws.vertex_groups.new(name="leg%d_c" % k)
    for v in me.vertices:
        g = cm.bv(v.co)
        best, bd = 0, 1e9
        for k, L in enumerate(R["legs"]):
            d = np.linalg.norm(np.array(g) - L["palm"])
            if d < bd:
                bd, best = d, k
        claws.vertex_groups["leg%d_c" % best].add([v.index], 1.0, 'REPLACE')
    final = cm.join([union] + [p[0] for p in parts[1:]])
    final.name = species
    cm.smooth_weights(final, 0.35, 2)
    # --- uv + texture
    cm.uv_unwrap(final, margin=0.003)
    res = S["tex"] // (4 if quick else 1)
    maps = cm.raster_maps(final, res, ["region"])
    print("rasterised", maps["mask"].sum(), "texels")
    albedo, nmap, rmap = texture(species, S, R, maps, res)
    tdir = os.path.join(OUT, "tex")
    os.makedirs(tdir, exist_ok=True)
    ia = cm.save_image(species + "_albedo", albedo, res, os.path.join(tdir, species + "_albedo.png"))
    inn = cm.save_image(species + "_normal", nmap, res, os.path.join(tdir, species + "_normal.png"), non_color=True)
    ir = cm.save_image(species + "_rough", rmap, res, os.path.join(tdir, species + "_rough.png"), non_color=True)
    mat = cm.make_material(species + "_skin", ia, inn, ir, normal_strength=1.0)
    final.data.materials.clear()
    final.data.materials.append(mat)
    # remove helper attribute before export
    if "region" in final.data.attributes:
        final.data.attributes.remove(final.data.attributes["region"])
    cm.export_glb(os.path.join(OUT, species + ".glb"), [final, arm])
    rig = {"frames": {k: {"o": list(map(float, v[0])), "d": list(map(float, v[1])), "u": list(map(float, v[2]))} for k, v in frames.items()},
           "species": species, "tris": cm.tri_count(final)}
    with open(os.path.join(OUT, species + ".rig.json"), "w") as f:
        json.dump(rig, f, indent=1)
    print("DONE", species, "tris", cm.tri_count(final))


main()
