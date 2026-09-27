class_name Species
extends RefCounted
## Species profiles. One shared Creature + Brain implementation is driven by
## these values. Masses in kg, speeds in m/s, lengths in m (at ref_mass).

const DEFS := {
	"monitor": {
		"name": "Lace Monitor", "rig": "reptile", "cat": "reptile",
		"ref_mass": 12.0, "length": 1.8, "radius_k": 0.07,
		"walk": 2.2, "run": 5.6, "turn": 4.0, "accel": 9.0,
		"hp": 1.0, "dmg": 1.5, "eats": ["insect", "frog", "reptile", "rodent", "bird", "fish", "mammal", "egg"],
		"prey_ratio": 0.4, "carrion": true, "detect": 22.0, "smell": 90.0,
		"active": "day", "swims": true, "swim_mult": 0.75, "aggression": 0.6, "courage": 0.7, "flee_hp": 0.4,
		"sounds": {"attack": "hiss", "hurt": "hurt", "alert": "hiss"},
	},
	"croc": {
		"name": "Saltwater Crocodile", "rig": "reptile", "cat": "croc",
		"ref_mass": 260.0, "length": 4.2, "radius_k": 0.09,
		"walk": 1.0, "run": 3.0, "turn": 1.8, "accel": 6.0, "swim_speed": 2.4,
		"hp": 1.5, "dmg": 1.6, "eats": ["reptile", "rodent", "bird", "fish", "mammal", "frog"],
		"prey_ratio": 1.5, "carrion": true, "detect": 20.0, "smell": 40.0,
		"active": "any", "swims": true, "aquatic": true, "aggression": 0.9, "courage": 1.0, "flee_hp": 0.2,
		"sounds": {"attack": "croc_lunge", "hurt": "croc_growl", "alert": "croc_growl"},
	},
	"skink": {
		"name": "Skink", "rig": "reptile", "cat": "reptile",
		"ref_mass": 0.018, "length": 0.22, "radius_k": 0.12,
		"walk": 0.5, "run": 3.2, "turn": 8.0, "accel": 20.0,
		"hp": 1.0, "dmg": 0.1, "eats": ["insect"], "prey_ratio": 0.3, "detect": 7.0,
		"active": "day", "aggression": 0.0, "courage": 0.0, "flee_hp": 1.0, "hides": true,
		"sounds": {"alert": "skink_rustle", "hurt": "skink_rustle"},
	},
	"dingo": {
		"name": "Dingo", "rig": "mammal", "gait": "trot", "cat": "mammal",
		"ref_mass": 16.0, "length": 1.0, "radius_k": 0.22,
		"walk": 1.6, "run": 8.6, "turn": 5.0, "accel": 12.0,
		"hp": 1.0, "dmg": 1.1, "eats": ["reptile", "rodent", "bird", "mammal"], "prey_ratio": 0.8,
		"carrion": true, "detect": 30.0, "smell": 60.0, "chase_time": 18.0, "stamina_drain": 0.035,
		"active": "dusk_night", "pack": true, "aggression": 0.7, "courage": 0.75, "flee_hp": 0.45,
		"sounds": {"attack": "dingo_growl", "hurt": "dingo_yelp", "alert": "dingo_bark", "idle": "dingo_howl"},
	},
	"wallaby": {
		"name": "Wallaby", "rig": "mammal", "gait": "hop", "cat": "mammal",
		"ref_mass": 9.0, "length": 0.8, "radius_k": 0.22,
		"walk": 1.2, "run": 7.5, "turn": 4.5, "accel": 10.0,
		"hp": 0.9, "dmg": 0.5, "eats": [], "prey_ratio": 0.0, "detect": 32.0,
		"active": "dusk", "herd": true, "grazer": true, "stamina_drain": 0.11, "aggression": 0.0, "courage": 0.2, "flee_hp": 1.0,
		"sounds": {"alert": "hop", "hurt": "dingo_yelp"},
	},
	"mouse": {
		"name": "Hopping Mouse", "rig": "mammal", "gait": "hop", "cat": "rodent",
		"ref_mass": 0.035, "length": 0.12, "radius_k": 0.25,
		"walk": 0.6, "run": 3.8, "turn": 9.0, "accel": 25.0,
		"hp": 1.0, "dmg": 0.05, "eats": [], "prey_ratio": 0.0, "detect": 10.0,
		"active": "any", "grazer": true, "aggression": 0.0, "courage": 0.0, "flee_hp": 1.0, "hides": true,
		"sounds": {"alert": "mouse_squeak", "hurt": "mouse_squeak"},
	},
	"frog": {
		"name": "Green Tree Frog", "rig": "frog", "cat": "frog",
		"ref_mass": 0.014, "length": 0.08, "radius_k": 0.4,
		"walk": 0.4, "run": 2.0, "turn": 8.0, "accel": 30.0,
		"hp": 0.8, "dmg": 0.0, "eats": ["insect"], "prey_ratio": 0.3, "detect": 6.0,
		"active": "dusk_night", "swims": true, "swim_mult": 0.9, "aggression": 0.0, "courage": 0.0, "flee_hp": 1.0,
		"sounds": {"idle": "frog_croak", "alert": "frog_plop"},
	},
	"grasshopper": {
		"name": "Grasshopper", "rig": "insect", "cat": "insect",
		"ref_mass": 0.005, "length": 0.07, "radius_k": 0.4,
		"walk": 0.15, "run": 2.6, "turn": 10.0, "accel": 40.0,
		"hp": 1.0, "dmg": 0.0, "eats": [], "prey_ratio": 0.0, "detect": 3.5,
		"active": "day_any", "grazer": true, "aggression": 0.0, "courage": 0.0, "flee_hp": 1.0,
		"sounds": {"alert": "insect_hop"},
	},
	"fish": {
		"name": "Spangled Perch", "rig": "fish", "cat": "fish",
		"ref_mass": 0.4, "length": 0.3, "radius_k": 0.2,
		"walk": 0.8, "run": 3.5, "turn": 5.0, "accel": 12.0,
		"hp": 0.6, "dmg": 0.0, "eats": [], "prey_ratio": 0.0, "detect": 5.0,
		"active": "any", "aquatic": true, "fish": true, "aggression": 0.0, "courage": 0.0, "flee_hp": 1.0,
		"sounds": {"alert": "splash_small"},
	},
	"turkey": {
		"name": "Brush-turkey", "rig": "bird", "cat": "bird", "bird": "turkey",
		"ref_mass": 2.2, "length": 0.65, "radius_k": 0.25,
		"walk": 1.1, "run": 5.0, "turn": 6.0, "accel": 12.0, "fly_speed": 7.0,
		"hp": 0.8, "dmg": 0.45, "eats": ["insect"], "prey_ratio": 0.2, "detect": 20.0,
		"active": "day", "aggression": 0.5, "courage": 0.35, "flee_hp": 0.6, "flies_short": true,
		"sounds": {"alert": "turkey_call", "hurt": "wings", "idle": "turkey_call", "attack": "turkey_call"},
	},
	"crow": {
		"name": "Raven", "rig": "bird", "cat": "bird", "bird": "crow",
		"ref_mass": 0.65, "length": 0.5, "radius_k": 0.25,
		"walk": 1.0, "run": 2.5, "turn": 7.0, "accel": 14.0, "fly_speed": 8.0,
		"hp": 0.7, "dmg": 0.3, "eats": ["insect", "frog", "reptile"], "prey_ratio": 0.12, "carrion": true,
		"detect": 45.0, "smell": 110.0, "active": "day", "flies": true, "aggression": 0.3, "courage": 0.3, "flee_hp": 0.7,
		"sounds": {"alert": "crow_caw", "idle": "crow_caw", "hurt": "crow_caw_2"},
	},
	"eagle": {
		"name": "Wedge-tailed Eagle", "rig": "bird", "cat": "bird", "bird": "eagle",
		"ref_mass": 4.0, "length": 0.95, "radius_k": 0.3,
		"walk": 1.0, "run": 2.0, "turn": 2.5, "accel": 10.0, "fly_speed": 11.0,
		"hp": 0.6, "dmg": 1.4, "eats": ["reptile", "rodent", "mammal", "bird"], "prey_ratio": 0.3,
		"carrion": true, "detect": 60.0, "smell": 0.0, "active": "day", "flies": true, "raptor": true,
		"aggression": 0.8, "courage": 0.6, "flee_hp": 0.5,
		"sounds": {"alert": "eagle_screech", "attack": "eagle_screech", "hurt": "eagle_screech", "idle": "eagle_screech"},
	},
}


static func get_def(id: String) -> Dictionary:
	return DEFS[id]
