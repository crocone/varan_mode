"""Sculpting helpers for species scripts (Godot coords, rig rest space)."""
import math
import numpy as np
import bmesh
import cmodel as cm

# surface regions understood by build_from_parts.surface()
R_FUR, R_EYE, R_NOSE, R_CLAW, R_PAD, R_INNER_EAR, R_LIP, R_BEAK, R_SCALE, R_WATTLE, R_SKIN = 0, 2, 5, 6, 9, 7, 8, 10, 11, 12, 13


class Mesh:
    """Accumulates primitives into one bmesh -> object."""

    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()

    def loft(self, stations, ring=28, up=(0, 1, 0), section=None, caps=True):
        """stations: list of (center(x,y,z), half_width, top, bottom)."""
        centers = [s[0] for s in stations]
        secs = [(s[1], s[2], s[3]) for s in stations]
        fn = None
        if section is not None:
            fn = lambda i, th: section(i, th)  # noqa: E731
        cm.loft(self.bm, centers, secs, up, ring, caps, caps, fn)
        return self

    def tube(self, pts, radii, ring=18, flat=1.0, up=(0, 1, 0)):
        cm.tube(self.bm, pts, radii, ring, up, flat)
        return self

    def ellipsoid(self, c, r, axes=None, seg=20, rings=12):
        cm.ellipsoid(self.bm, c, r, axes, seg, rings)
        return self

    def cone(self, base, tip, r, seg=8):
        cm.cone(self.bm, base, tip, r, seg)
        return self

    def build(self):
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        return cm.new_object(self.name, self.bm)


def nrm(v):
    v = np.asarray(v, dtype=np.float64)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def lerp(a, b, t):
    return np.asarray(a) * (1 - t) + np.asarray(b) * t


def keel_section(keel=0.18, flat_side=0.0):
    """Cross-section that narrows toward the bottom (deep chest keel)."""
    def fn(i, th):
        cs, sn = math.cos(th), math.sin(th)
        if sn < 0:
            cs *= 1.0 - keel * sn * sn
        if flat_side > 0:
            cs = math.copysign(abs(cs) ** (1.0 - flat_side), cs)
        return cs, sn
    return fn


def paw(mesh, claws, pads, center, fwd, size, toes=4, dew=True):
    """Canid-style paw: pad mass, knuckled toes in an arc, claws, pads underneath."""
    f = nrm(fwd)
    up = np.array([0.0, 1.0, 0.0])
    side = nrm(np.cross(up, f))
    c = np.asarray(center, dtype=np.float64)
    mesh.ellipsoid(tuple(c + up * size * 0.25), (size * 0.95, size * 0.55, size * 1.05), (tuple(side), tuple(up), tuple(f)), 18, 10)
    for i in range(toes):
        a = (i - (toes - 1) / 2) * 0.42
        d = nrm(f * math.cos(a) + side * math.sin(a))
        tc = c + d * size * 0.95 + up * size * 0.18
        mesh.ellipsoid(tuple(tc), (size * 0.34, size * 0.34, size * 0.42), (tuple(side), tuple(up), tuple(d)), 12, 8)
        claws.cone(tuple(tc + d * size * 0.3 + up * size * 0.05), tuple(tc + d * size * 0.75 - up * size * 0.22), size * 0.12, 6)
        pads.ellipsoid(tuple(tc - up * size * 0.2), (size * 0.24, size * 0.1, size * 0.26), None, 10, 6)
    pads.ellipsoid(tuple(c - up * size * 0.08 + f * size * 0.1), (size * 0.55, size * 0.14, size * 0.45), (tuple(side), tuple(up), tuple(f)), 14, 7)
    if dew:
        dc = c + up * size * 1.6 - side * size * 0.75 + f * size * 0.1
        claws.cone(tuple(dc), tuple(dc + f * size * 0.3 - up * size * 0.15), size * 0.09, 6)
