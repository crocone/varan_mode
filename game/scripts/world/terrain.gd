class_name Terrain
extends RefCounted
## Heightfield terrain, biome queries and static world features (trees, rocks,
## logs, mounds...). Creatures never use physics: they sample this data.

const HALF := 170.0
const PLAY_HALF := 150.0      # playable boundary
const CELL := 1.0
const N := 341
const WATER_Y := 0.0
const GRID := 10.0            # feature grid cell size

# Landmarks
const NEST_POS := Vector2(-72, 92)
const POND_POS := Vector2(-26, 50)
const POND_R := 17.0
const OUTCROP_POS := Vector2(86, -80)
const DEN_POS := Vector2(-108, -112)
const SCRUB_POS := Vector2(80, 90)

const RIVER_CTRL := [
	Vector2(-200, -78), Vector2(-150, -62), Vector2(-112, -30), Vector2(-70, -40),
	Vector2(-28, -12), Vector2(8, 14), Vector2(46, 4), Vector2(82, 30),
	Vector2(112, 62), Vector2(146, 74), Vector2(200, 96)]

var rng := RandomNumberGenerator.new()
var h := PackedFloat32Array()
var rdist := PackedFloat32Array()
var river_pts := PackedVector2Array()
var n_large := FastNoiseLite.new()
var n_mid := FastNoiseLite.new()
var n_small := FastNoiseLite.new()
var n_wood := FastNoiseLite.new()

# Features. Each is a Dictionary; grids map Vector2i -> Array[int] of indices.
var trees: Array = []       # {p:Vector2, trunk:float, canopy:float, height:float, kind:int}
var bushes: Array = []      # {p, r, kind}   kind 0 shrub, 1 spinifex
var boulders: Array = []    # {p, r, y, hgt}
var slabs: Array = []       # {p, rx, rz, ry, yaw, base}
var logs: Array = []        # {a:Vector2, b:Vector2, r:float, y:float}
var mounds: Array = []      # termite mounds {p, r, hgt}
var turkey_mounds: Array = [] # {p, r, eggs:int, regen:float}
var shelters: Array = []    # {p, r, max_mass}
var reeds: Array = []       # {p}

var g_obst := {}    # collision: trees, boulders, mounds (circles) and logs (capsules)
var g_slab := {}
var g_canopy := {}
var g_bush := {}
var g_shelter := {}
var g_trees := {}


func generate(seed_value: int) -> void:
	rng.seed = seed_value
	n_large.seed = seed_value
	n_large.frequency = 0.0075
	n_large.fractal_octaves = 3
	n_mid.seed = seed_value + 1
	n_mid.frequency = 0.03
	n_mid.fractal_octaves = 2
	n_small.seed = seed_value + 2
	n_small.frequency = 0.12
	n_small.fractal_octaves = 1
	n_wood.seed = seed_value + 3
	n_wood.frequency = 0.018
	n_wood.fractal_octaves = 2
	_build_river()
	h.resize(N * N)
	for j in N:
		var z := -HALF + j * CELL
		for i in N:
			var x := -HALF + i * CELL
			h[j * N + i] = _compute_height(x, z, rdist[j * N + i])
	_place_features()


# ------------------------------------------------------------------ river

func _build_river() -> void:
	var c: Array = RIVER_CTRL
	for s in range(c.size() - 1):
		var p0: Vector2 = c[max(s - 1, 0)]
		var p1: Vector2 = c[s]
		var p2: Vector2 = c[s + 1]
		var p3: Vector2 = c[min(s + 2, c.size() - 1)]
		for k in 10:
			var t := k / 10.0
			river_pts.append(_catmull(p0, p1, p2, p3, t))
	river_pts.append(c[c.size() - 1])
	rdist.resize(N * N)
	rdist.fill(999.0)
	var margin := 40.0
	for s in range(river_pts.size() - 1):
		var a := river_pts[s]
		var b := river_pts[s + 1]
		var i0 := int(clampf((minf(a.x, b.x) - margin + HALF) / CELL, 0, N - 1))
		var i1 := int(clampf((maxf(a.x, b.x) + margin + HALF) / CELL, 0, N - 1))
		var j0 := int(clampf((minf(a.y, b.y) - margin + HALF) / CELL, 0, N - 1))
		var j1 := int(clampf((maxf(a.y, b.y) + margin + HALF) / CELL, 0, N - 1))
		var ab := b - a
		var ab2 := ab.length_squared()
		for j in range(j0, j1 + 1):
			var z := -HALF + j * CELL
			for i in range(i0, i1 + 1):
				var x := -HALF + i * CELL
				var ap := Vector2(x, z) - a
				var t := clampf(ap.dot(ab) / ab2, 0.0, 1.0)
				var d := (ap - ab * t).length()
				var idx := j * N + i
				if d < rdist[idx]:
					rdist[idx] = d


static func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


func river_width(x: float, z: float) -> float:
	return 8.5 + 3.0 * n_mid.get_noise_2d(x * 0.4, z * 0.4)


func pond_dist(x: float, z: float) -> float:
	var d := Vector2(x, z) - POND_POS
	d.x *= 0.8
	return d.length() + n_mid.get_noise_2d(x * 1.5, z * 1.5) * 4.0


func _compute_height(x: float, z: float, rd: float) -> float:
	var base := 2.8 + n_large.get_noise_2d(x, z) * 2.4 + n_mid.get_noise_2d(x, z) * 0.55 + n_small.get_noise_2d(x, z) * 0.08
	# rocky outcrop plateau
	var od := Vector2(x, z).distance_to(OUTCROP_POS) + n_mid.get_noise_2d(x * 0.7, z * 0.7) * 9.0
	base += 7.0 * (1.0 - smoothstep(16.0, 34.0, od))
	# dingo den rise
	var dd := Vector2(x, z).distance_to(DEN_POS)
	base += 2.5 * (1.0 - smoothstep(6.0, 22.0, dd))
	# flat nesting ground
	var nd := Vector2(x, z).distance_to(NEST_POS)
	base = lerpf(2.2 + n_small.get_noise_2d(x, z) * 0.1, base, smoothstep(9.0, 26.0, nd))
	# billabong
	var pd := pond_dist(x, z)
	if pd < POND_R + 12.0:
		if pd < POND_R:
			var q := pd / POND_R
			base = minf(base, -1.5 * (1.0 - q * q) - 0.05)
		else:
			base = lerpf(0.05, base, smoothstep(POND_R, POND_R + 12.0, pd))
	# river
	var w := river_width(x, z)
	var bankw := 11.0 + 7.0 * n_mid.get_noise_2d(x * 0.8 + 50.0, z * 0.8)
	if rd < w:
		var q2 := rd / w
		base = minf(base, -2.3 * (1.0 - q2 * q2) - 0.05)
	elif rd < w + bankw:
		base = lerpf(0.05, base, smoothstep(w, w + bankw, rd))
	# escarpment around the map edge (gap where the river passes)
	var e := maxf(absf(x), absf(z)) + n_mid.get_noise_2d(x * 0.5, z * 0.5) * 7.0
	var cliff := smoothstep(HALF - 34.0, HALF - 10.0, e) * (16.0 + n_large.get_noise_2d(z, x) * 5.0)
	cliff *= smoothstep(w + 2.0, w + 24.0, rd)
	return base + cliff


# ------------------------------------------------------------------ sampling

func hmap(x: float, z: float) -> float:
	# Triangle interpolation that exactly matches the rendered terrain mesh
	# (quads split along the (i,j)-(i+1,j+1) diagonal).
	var fx := clampf((x + HALF) / CELL, 0.0, N - 1.001)
	var fz := clampf((z + HALF) / CELL, 0.0, N - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var k := j * N + i
	var h00 := h[k]
	var h11 := h[k + N + 1]
	if tx >= tz:
		var h10 := h[k + 1]
		return h00 + (h10 - h00) * tx + (h11 - h10) * tz
	var h01 := h[k + N]
	return h00 + (h11 - h01) * tx + (h01 - h00) * tz


## Ground height including walkable rock slabs.
func height(x: float, z: float) -> float:
	var y := hmap(x, z)
	var cell: Array = g_slab.get(Vector2i(floori(x / GRID), floori(z / GRID)), [])
	for si in cell:
		var s: Dictionary = slabs[si]
		var d: Vector2 = Vector2(x, z) - s.p
		var c := cos(s.yaw)
		var sn := sin(s.yaw)
		var lx: float = (d.x * c - d.y * sn) / s.rx
		var lz: float = (d.x * sn + d.y * c) / s.rz
		var q: float = lx * lx + lz * lz
		if q < 1.0:
			y = maxf(y, s.base + s.ry * sqrt(1.0 - q))
	return y


func normal(x: float, z: float) -> Vector3:
	var e := 0.6
	var dx := height(x + e, z) - height(x - e, z)
	var dz := height(x, z + e) - height(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


func on_slab(x: float, z: float) -> bool:
	return height(x, z) > hmap(x, z) + 0.08


func water_depth(x: float, z: float) -> float:
	return WATER_Y - height(x, z)


func rd_at(x: float, z: float) -> float:
	var i := int(clampf((x + HALF) / CELL, 0, N - 1))
	var j := int(clampf((z + HALF) / CELL, 0, N - 1))
	return rdist[j * N + i]


func in_river(x: float, z: float) -> bool:
	return rd_at(x, z) < river_width(x, z) + 1.0 and water_depth(x, z) > 0.0


func woodland(x: float, z: float) -> float:
	var v := n_wood.get_noise_2d(x, z) * 0.9
	v += 0.55 * (1.0 - smoothstep(20.0, 75.0, Vector2(x, z).distance_to(Vector2(-95, 60))))
	v += 0.35 * (1.0 - smoothstep(15.0, 45.0, Vector2(x, z).distance_to(Vector2(20, 70))))
	v -= 0.6 * (1.0 - smoothstep(20.0, 55.0, Vector2(x, z).distance_to(SCRUB_POS)))
	v -= 0.5 * (1.0 - smoothstep(20.0, 40.0, Vector2(x, z).distance_to(OUTCROP_POS)))
	v -= 0.4 * (1.0 - smoothstep(8.0, 18.0, Vector2(x, z).distance_to(NEST_POS)))
	return clampf(v, 0.0, 1.0)


func rocky(x: float, z: float) -> float:
	var od := Vector2(x, z).distance_to(OUTCROP_POS)
	var r := 1.0 - smoothstep(20.0, 40.0, od)
	var n := normal(x, z)
	r = maxf(r, smoothstep(0.82, 0.62, n.y))
	return clampf(r, 0.0, 1.0)


func moisture(x: float, z: float) -> float:
	var rd := rd_at(x, z) - river_width(x, z)
	var pd := pond_dist(x, z) - POND_R
	return clampf(1.0 - minf(rd, pd) / 18.0, 0.0, 1.0)


func zone_name(x: float, z: float) -> String:
	var p := Vector2(x, z)
	if p.distance_to(NEST_POS) < 22.0:
		return "Nesting Grounds"
	if pond_dist(x, z) < POND_R + 10.0:
		return "The Billabong"
	if rd_at(x, z) < river_width(x, z) + 12.0:
		return "River"
	if p.distance_to(OUTCROP_POS) < 42.0:
		return "Red Rocks"
	if p.distance_to(DEN_POS) < 40.0:
		return "Dingo Country"
	if absf(x) > PLAY_HALF - 25.0 or absf(z) > PLAY_HALF - 25.0:
		return "Escarpment"
	if woodland(x, z) > 0.45:
		return "Woodland"
	if p.distance_to(SCRUB_POS) < 55.0:
		return "Spinifex Scrub"
	return "Open Country"


# ------------------------------------------------------------------ feature grid

func _grid_add(grid: Dictionary, p: Vector2, r: float, idx: int) -> void:
	var i0 := floori((p.x - r) / GRID)
	var i1 := floori((p.x + r) / GRID)
	var j0 := floori((p.y - r) / GRID)
	var j1 := floori((p.y + r) / GRID)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var key := Vector2i(i, j)
			if not grid.has(key):
				grid[key] = []
			grid[key].append(idx)


func _cell(grid: Dictionary, x: float, z: float) -> Array:
	return grid.get(Vector2i(floori(x / GRID), floori(z / GRID)), [])


## Obstacles are stored as {kind:"c"/"s", ...}. Returns pushed-out position.
var obstacles: Array = []


func _add_obstacle_circle(p: Vector2, r: float, small_pass := 0.0) -> void:
	obstacles.append({"k": 0, "p": p, "r": r, "pass": small_pass})
	_grid_add(g_obst, p, r, obstacles.size() - 1)


func _add_obstacle_capsule(a: Vector2, b: Vector2, r: float, small_pass := 0.0) -> void:
	obstacles.append({"k": 1, "a": a, "b": b, "r": r, "pass": small_pass})
	var mid := (a + b) * 0.5
	_grid_add(g_obst, mid, (a - b).length() * 0.5 + r, obstacles.size() - 1)


## Resolve a creature circle (radius cr, body mass) against obstacles.
func push_out(p: Vector2, cr: float, mass: float) -> Vector2:
	for iter in 2:
		var cell := _cell(g_obst, p.x, p.y)
		for oi in cell:
			var o: Dictionary = obstacles[oi]
			if mass < o.pass:
				continue
			var closest: Vector2
			if o.k == 0:
				closest = o.p
			else:
				var ab: Vector2 = o.b - o.a
				var t := clampf((p - o.a).dot(ab) / ab.length_squared(), 0.0, 1.0)
				closest = o.a + ab * t
			var d := p - closest
			var rr: float = o.r + cr
			var dl := d.length()
			if dl < rr:
				if dl < 0.001:
					d = Vector2(1, 0)
					dl = 1.0
				p = closest + d / dl * rr
	return p


func blocked(p: Vector2, cr: float, mass: float) -> bool:
	return push_out(p, cr, mass).distance_squared_to(p) > 0.0001


## Shade factor 0 (full sun) .. 1 (deep shade) from canopy and bushes.
func shade(x: float, z: float) -> float:
	var s := 0.0
	var p := Vector2(x, z)
	for ti in _cell(g_canopy, x, z):
		var t: Dictionary = trees[ti]
		var d: float = p.distance_to(t.p) / t.canopy
		if d < 1.0:
			s = maxf(s, 0.85 * smoothstep(1.0, 0.55, d))
	for bi in _cell(g_bush, x, z):
		var b: Dictionary = bushes[bi]
		var d2: float = p.distance_to(b.p) / b.r
		if d2 < 1.0:
			s = maxf(s, 0.7 * smoothstep(1.0, 0.4, d2))
	return s


## Concealment from vegetation 0 (open) .. 1 (fully concealed) for a creature of `mass`.
func cover(x: float, z: float, mass: float) -> float:
	var c := 0.0
	var p := Vector2(x, z)
	for bi in _cell(g_bush, x, z):
		var b: Dictionary = bushes[bi]
		var d: float = p.distance_to(b.p) / b.r
		if d < 0.95:
			var bushc := 0.9 if b.kind == 0 else 0.8
			c = maxf(c, bushc * clampf(1.6 - mass * 0.15, 0.2, 1.0))
	# tall grass hides small animals
	if mass < 3.0:
		var g := grassiness(x, z)
		c = maxf(c, g * 0.55 * clampf(1.2 - mass * 0.4, 0.0, 1.0))
	return c


## Returns a shelter dict if (x,z) is inside a shelter usable by `mass`, else {}.
func shelter_at(x: float, z: float, mass: float) -> Dictionary:
	var p := Vector2(x, z)
	for si in _cell(g_shelter, x, z):
		var s: Dictionary = shelters[si]
		if mass <= s.max_mass and p.distance_to(s.p) < s.r:
			return s
	return {}


func nearest_shelter(p: Vector2, mass: float, max_d: float) -> Dictionary:
	var best := {}
	var bd := max_d
	for s in shelters:
		if mass > s.max_mass:
			continue
		var d := p.distance_to(s.p)
		if d < bd:
			bd = d
			best = s
	return best


func nearest_bush(p: Vector2, max_d: float) -> Dictionary:
	var best := {}
	var bd := max_d
	for b in bushes:
		var d := p.distance_to(b.p)
		if d < bd:
			bd = d
			best = b
	return best


func grassiness(x: float, z: float) -> float:
	var g := 0.55 + n_mid.get_noise_2d(x + 300.0, z) * 0.6
	g -= woodland(x, z) * 0.35
	g -= rocky(x, z) * 0.9
	var hh := hmap(x, z)
	if hh < 0.25:
		g -= 1.0
	g += moisture(x, z) * 0.25
	if Vector2(x, z).distance_to(NEST_POS) < 12.0:
		g -= 0.4
	return clampf(g, 0.0, 1.0)


## Find a point of water edge near p (for drinking). Returns Vector3 on shore or null-ish (y=-999).
func nearest_shore(p: Vector2, max_d := 90.0) -> Vector3:
	var best := Vector3(0, -999, 0)
	var bd := max_d
	var step := 3.0
	var r := step
	while r <= max_d:
		var n := int(TAU * r / step)
		for k in n:
			var a := TAU * k / n
			var q := p + Vector2(cos(a), sin(a)) * r
			if absf(q.x) > PLAY_HALF or absf(q.y) > PLAY_HALF:
				continue
			var hh := height(q.x, q.y)
			if hh > 0.01 and hh < 0.12:
				var d := p.distance_to(q)
				if d < bd:
					bd = d
					best = Vector3(q.x, hh, q.y)
		if best.y > -900.0:
			return best
		r += step
	return best


func clamp_play(p: Vector2) -> Vector2:
	return Vector2(clampf(p.x, -PLAY_HALF, PLAY_HALF), clampf(p.y, -PLAY_HALF, PLAY_HALF))


func random_land_point(center: Vector2, radius: float, min_h := 0.3, tries := 30) -> Vector2:
	for t in tries:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * radius
		var q := clamp_play(center + Vector2(cos(a), sin(a)) * r)
		var hh := height(q.x, q.y)
		if hh > min_h and hh < 12.0 and not blocked(q, 0.3, 999.0):
			return q
	return center


func random_water_point(center: Vector2, radius: float, min_depth := 0.6, tries := 40) -> Vector2:
	for t in tries:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * radius
		var q := clamp_play(center + Vector2(cos(a), sin(a)) * r)
		if water_depth(q.x, q.y) > min_depth:
			return q
	return Vector2(INF, INF)


# ------------------------------------------------------------------ feature placement

func _free_spot(p: Vector2, r: float) -> bool:
	for oi in _cell(g_obst, p.x, p.y):
		var o: Dictionary = obstacles[oi]
		if o.k == 0 and p.distance_to(o.p) < o.r + r:
			return false
		if o.k == 1 and p.distance_to((o.a + o.b) * 0.5) < o.r + r + (o.a - o.b).length() * 0.5:
			return false
	return true


func _place_features() -> void:
	# Termite mounds at the nest (the player's birthplace) and scattered.
	var nest_mounds := [Vector2(-72, 92), Vector2(-64, 99), Vector2(-79, 101), Vector2(-66, 84)]
	for mp in nest_mounds:
		_add_mound(mp, rng.randf_range(0.9, 1.2), rng.randf_range(1.8, 2.6))
	for k in 16:
		var q := random_land_point(Vector2(0, 0), 140.0, 0.8)
		if woodland(q.x, q.y) > 0.15 and _free_spot(q, 3.0):
			_add_mound(q, rng.randf_range(0.7, 1.3), rng.randf_range(1.2, 3.2))

	# River red gums on the banks.
	for s in range(0, river_pts.size(), 2):
		var a := river_pts[s]
		if absf(a.x) > PLAY_HALF + 10 or absf(a.y) > PLAY_HALF + 10:
			continue
		var dir := (river_pts[min(s + 1, river_pts.size() - 1)] - river_pts[max(s - 1, 0)]).normalized()
		var side := Vector2(-dir.y, dir.x) * (1.0 if rng.randf() < 0.5 else -1.0)
		var q := a + side * (river_width(a.x, a.y) + rng.randf_range(4.0, 12.0))
		if height(q.x, q.y) > 0.4 and rng.randf() < 0.75 and _free_spot(q, 5.0):
			_add_tree(q, 1, rng.randf_range(0.45, 0.65))
	# Billabong ring of trees.
	for k in 10:
		var a2 := rng.randf() * TAU
		var q2 := POND_POS + Vector2(cos(a2) * 1.25, sin(a2)) * (POND_R + rng.randf_range(4.0, 10.0))
		if height(q2.x, q2.y) > 0.4 and _free_spot(q2, 5.0):
			_add_tree(q2, 1, rng.randf_range(0.4, 0.6))
	# Woodland eucalypts.
	for k in 1400:
		var q3 := Vector2(rng.randf_range(-PLAY_HALF, PLAY_HALF), rng.randf_range(-PLAY_HALF, PLAY_HALF))
		var hh := height(q3.x, q3.y)
		if hh < 0.5:
			continue
		var w := woodland(q3.x, q3.y)
		var chance := w * 0.55 + 0.02
		if rocky(q3.x, q3.y) > 0.5:
			chance *= 0.2
		if rng.randf() < chance and _free_spot(q3, 4.2):
			_add_tree(q3, 0, rng.randf_range(0.22, 0.42))
	# Bushes and spinifex.
	for k in 2600:
		var q4 := Vector2(rng.randf_range(-PLAY_HALF, PLAY_HALF), rng.randf_range(-PLAY_HALF, PLAY_HALF))
		var hh2 := height(q4.x, q4.y)
		if hh2 < 0.35:
			continue
		var w2 := woodland(q4.x, q4.y)
		var scrub := 1.0 - smoothstep(20.0, 70.0, q4.distance_to(SCRUB_POS))
		scrub = maxf(scrub, 1.0 - smoothstep(20.0, 60.0, q4.distance_to(DEN_POS)))
		var chance2 := 0.05 + w2 * 0.12 + scrub * 0.25
		if q4.distance_to(NEST_POS) < 26.0:
			chance2 += 0.2
		if rng.randf() > chance2:
			continue
		if not _free_spot(q4, 1.2):
			continue
		var kind := 1 if rng.randf() < scrub * 0.8 + 0.1 - w2 * 0.3 else 0
		var r := rng.randf_range(0.9, 1.9) if kind == 0 else rng.randf_range(0.7, 1.3)
		bushes.append({"p": q4, "r": r, "kind": kind})
		_grid_add(g_bush, q4, r, bushes.size() - 1)
	# Rocks: outcrop boulders and slabs.
	for k in 70:
		var q5 := OUTCROP_POS + Vector2(rng.randf_range(-38, 38), rng.randf_range(-38, 38))
		var od := q5.distance_to(OUTCROP_POS)
		if od > 40.0:
			continue
		if _free_spot(q5, 2.0):
			var br := rng.randf_range(0.8, 3.2) * (1.3 - od / 60.0)
			_add_boulder(q5, br, k % 3 == 0)
	for k in 18:
		var q6 := OUTCROP_POS + Vector2(rng.randf_range(-30, 30), rng.randf_range(-30, 30))
		if _free_spot(q6, 3.0):
			_add_slab(q6, rng.randf_range(2.5, 5.0), rng.randf_range(1.8, 3.5), rng.randf_range(0.5, 1.0))
	# Dingo den boulders ring.
	for k in 12:
		var a3 := TAU * k / 12.0 + rng.randf() * 0.3
		var q7 := DEN_POS + Vector2(cos(a3), sin(a3)) * rng.randf_range(8.0, 14.0)
		if _free_spot(q7, 1.5):
			_add_boulder(q7, rng.randf_range(1.0, 2.6), k % 4 == 0)
	# Scattered rocks & basking slabs everywhere, a few near the nest.
	for sp in [Vector2(-60, 88), Vector2(-80, 84), Vector2(-70, 106)]:
		_add_slab(sp, rng.randf_range(1.6, 2.2), rng.randf_range(1.2, 1.6), 0.35)
	for k in 90:
		var q8 := random_land_point(Vector2(0, 0), 150.0, 0.5)
		if q8.distance_to(NEST_POS) < 14.0 or not _free_spot(q8, 2.0):
			continue
		if rng.randf() < 0.5:
			_add_boulder(q8, rng.randf_range(0.5, 1.8), rng.randf() < 0.3)
		else:
			_add_slab(q8, rng.randf_range(1.2, 3.0), rng.randf_range(1.0, 2.2), rng.randf_range(0.25, 0.6))
	# Hollow logs.
	var log_spots := [Vector2(-58, 94), Vector2(-84, 90), Vector2(-74, 78)]
	for k in 36:
		log_spots.append(random_land_point(Vector2(-60, 40), 110.0, 0.5))
	for lp in log_spots:
		if woodland(lp.x, lp.y) < 0.2 and lp.distance_to(NEST_POS) > 30.0 and rng.randf() < 0.6:
			continue
		if not _free_spot(lp, 2.5):
			continue
		var ang := rng.randf() * TAU
		var ln := rng.randf_range(2.2, 4.5)
		var lr := rng.randf_range(0.22, 0.4)
		var a4: Vector2 = lp - Vector2(cos(ang), sin(ang)) * ln * 0.5
		var b4: Vector2 = lp + Vector2(cos(ang), sin(ang)) * ln * 0.5
		logs.append({"a": a4, "b": b4, "r": lr, "y": height(lp.x, lp.y)})
		_add_obstacle_capsule(a4, b4, lr, 0.35)
		# both ends are entrances; the hollow shelters small animals
		shelters.append({"p": lp, "r": ln * 0.5 + 0.2, "max_mass": 0.35, "kind": "log"})
		_grid_add(g_shelter, lp, ln * 0.5 + 0.3, shelters.size() - 1)
	# Brush-turkey mounds in the woodland.
	var tk_spots := [Vector2(-104, 64), Vector2(-88, 40), Vector2(-120, 86), Vector2(12, 74), Vector2(-40, 104)]
	for tp in tk_spots:
		var q9 := random_land_point(tp, 6.0, 0.6)
		turkey_mounds.append({"p": q9, "r": 1.8, "eggs": 3, "regen": 0.0})
	# Reeds around the billabong and slow river edges.
	for k in 700:
		var a5 := rng.randf() * TAU
		var q10 := POND_POS + Vector2(cos(a5) * 1.25, sin(a5)) * (POND_R + rng.randf_range(-3.0, 2.0))
		if rng.randf() < 0.5:
			var s2 := rng.randi_range(0, river_pts.size() - 2)
			var rp := river_pts[s2]
			var dir2 := (river_pts[s2 + 1] - rp).normalized()
			q10 = rp + Vector2(-dir2.y, dir2.x) * (river_width(rp.x, rp.y) + rng.randf_range(-2.0, 1.5)) * (1.0 if rng.randf() < 0.5 else -1.0)
		var hh3 := height(q10.x, q10.y)
		if hh3 > -0.5 and hh3 < 0.6 and absf(q10.x) < PLAY_HALF and absf(q10.y) < PLAY_HALF:
			reeds.append({"p": q10})
	# Bushes also act as shelters for tiny animals (hatchlings).
	for bi in bushes.size():
		var b: Dictionary = bushes[bi]
		if b.kind == 0 and b.r > 1.2:
			shelters.append({"p": b.p, "r": b.r * 0.55, "max_mass": 0.08, "kind": "bush"})
			_grid_add(g_shelter, b.p, b.r, shelters.size() - 1)


func _add_tree(p: Vector2, kind: int, trunk: float) -> void:
	var canopy := trunk * 12.0 + rng.randf_range(0.0, 1.5)
	var hgt := trunk * 22.0 + rng.randf_range(0.0, 3.0)
	var r0 := (0.045 if kind == 1 else 0.035) * 0.9 * hgt
	trees.append({"p": p, "trunk": r0, "r0": r0, "canopy": canopy, "height": hgt, "kind": kind, "y": hmap(p.x, p.y)})
	var idx := trees.size() - 1
	_grid_add(g_canopy, p, canopy, idx)
	_grid_add(g_trees, p, r0 + 1.0, idx)
	_add_obstacle_circle(p, r0 * 1.05)


func _add_boulder(p: Vector2, r: float, crevice: bool) -> void:
	boulders.append({"p": p, "r": r, "y": hmap(p.x, p.y), "hgt": r * rng.randf_range(0.8, 1.4), "seed": rng.randi()})
	_add_obstacle_circle(p, r * 0.9)
	if crevice:
		var a := rng.randf() * TAU
		var sp := p + Vector2(cos(a), sin(a)) * (r * 0.9 + 0.25)
		shelters.append({"p": sp, "r": 0.5, "max_mass": 0.3, "kind": "crevice"})
		_grid_add(g_shelter, sp, 0.6, shelters.size() - 1)


func _add_slab(p: Vector2, rx: float, rz: float, ry: float) -> void:
	var base := hmap(p.x, p.y) - ry * 0.35
	slabs.append({"p": p, "rx": rx, "rz": rz, "ry": ry, "yaw": rng.randf() * TAU, "base": base, "seed": rng.randi()})
	_grid_add(g_slab, p, maxf(rx, rz), slabs.size() - 1)


func _add_mound(p: Vector2, r: float, hgt: float) -> void:
	mounds.append({"p": p, "r": r, "hgt": hgt, "y": hmap(p.x, p.y)})
	_add_obstacle_circle(p, r * 0.8)


func nearest_mound(p: Vector2, max_d: float) -> Dictionary:
	var best := {}
	var bd := max_d
	for m in mounds:
		var d: float = p.distance_to(m.p) - m.r
		if d < bd:
			bd = d
			best = m
	return best


func nearest_slab(p: Vector2, max_d: float) -> Dictionary:
	var best := {}
	var bd := max_d
	for s in slabs:
		var d := p.distance_to(s.p)
		if d < bd:
			bd = d
			best = s
	return best


## Visible trunk radius of a (straight) tree at height y above its base.
static func trunk_radius(t: Dictionary, y: float) -> float:
	return t.r0 * clampf(1.0 - 1.09 * y / t.height, 0.3, 1.0)


## Tree whose trunk surface is within `d` of point p.
func tree_near(p: Vector2, d: float) -> Dictionary:
	for ti in _cell(g_trees, p.x, p.y):
		var t: Dictionary = trees[ti]
		if p.distance_to(t.p) - t.r0 < d:
			return t
	return {}


func nearest_tree(p: Vector2, max_d: float) -> Dictionary:
	var best := {}
	var bd := max_d
	for t in trees:
		var d := p.distance_to(t.p)
		if d < bd:
			bd = d
			best = t
	return best
