extends Node2D
## BLAME SHIFT - a night-shift, blame-shifting arcade score-chaser.
## Everything is drawn in code and every sound is synthesised: zero external assets.

const W := 960.0
const H := 540.0
const AREA := Rect2(40, 140, 880, 370)
const DOOR := Vector2(480, 526)
const SAVE_PATH := "user://blame_shift.save"
const MAX_STRIKES := 3
const NIGHT_LEN := 110.0      # real seconds per in-game night (10 PM -> 6 AM)
const PLANT_TIME := 0.55      # seconds you must hold SPACE to plant evidence
const REACH := 54.0           # how close you must be to an incident
const BLAME_RANGE := 240.0    # how far from the incident a victim can be
const COP_SIGHT := 150.0
const COMBO_TIME := 7.0
const COP := 5

enum State { TITLE, RUN, OVER }

class Customer:
	var pos := Vector2.ZERO
	var target := Vector2.ZERO
	var type := 0
	var speed := 70.0
	var wait := 0.0
	var state := 0        # 0 wandering, 1 blamed (frozen), 2 leaving
	var timer := 0.0
	var bob := 0.0
	var stuck := 0.0

class Incident:
	var pos := Vector2.ZERO
	var kind := 0
	var t := 12.0
	var max_t := 12.0
	var prog := 0.0

class Pop:
	var pos := Vector2.ZERO
	var text := ""
	var col := Color.WHITE
	var t := 1.2
	var size := 18

var TYPES: Array[Dictionary] = [
	{"name": "Teen", "mult": 1, "col": Color("e8743b"), "quip": "Typical teenager!"},
	{"name": "Mime", "mult": 2, "col": Color("f2f2f2"), "quip": "...(suspiciously silent)"},
	{"name": "Grandma", "mult": 3, "col": Color("c77dba"), "quip": "Not at my age!"},
	{"name": "Priest", "mult": 4, "col": Color("2b2b3a"), "quip": "Bless this frame-up!"},
	{"name": "Cat", "mult": 6, "col": Color("f0a73a"), "quip": "Meow. (Guilty.)"},
	{"name": "Cop", "mult": 0, "col": Color("3a5fcd"), "quip": ""},
]

var INCIDENTS: Array[Dictionary] = [
	{"name": "Slushie Spill", "col": Color("4dd2ff")},
	{"name": "Stolen Hot Dog", "col": Color("ff8c42")},
	{"name": "Broken Freezer", "col": Color("a0e7ff")},
	{"name": "Haunted Microwave", "col": Color("b388ff")},
	{"name": "Missing Lottery Tickets", "col": Color("ffd166")},
	{"name": "Exploding Nacho Machine", "col": Color("ffb703")},
]

var state := State.TITLE
var font: Font
var time := 0.0
var paused := false
var obstacles: Array[Rect2] = []
var customers: Array[Customer] = []
var incidents: Array[Incident] = []
var pops: Array[Pop] = []
var parts: Array[Dictionary] = []
var sfx: Dictionary = {}

var player_pos := Vector2(480, 440)
var facing := 1.0
var stamina := 1.0
var exhausted := false
var running := false
var acting := false
var tick_t := 0.0

var score := 0
var best := 0
var new_best := false
var strikes := 0
var combo := 1
var combo_t := 0.0
var night := 1
var night_t := 0.0
var spawn_t := 2.0
var banner_txt := ""
var banner_t := 0.0
var alert_txt := ""
var alert_t := 0.0
var shake := 0.0
var flash := 0.0
var over_t := 0.0


func _ready() -> void:
	font = ThemeDB.fallback_font
	randomize()
	obstacles = [Rect2(240, 260, 170, 34), Rect2(550, 330, 170, 34)]
	_build_sfx()
	_load_best()


# ------------------------------------------------------------------ input
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if state != State.RUN:
			if k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_SPACE:
				if state == State.OVER and over_t < 0.8:
					return
				_start()
		elif k == KEY_P or k == KEY_ESCAPE:
			paused = not paused


func _start() -> void:
	score = 0
	strikes = 0
	combo = 1
	combo_t = 0.0
	night = 1
	night_t = 0.0
	stamina = 1.0
	exhausted = false
	customers.clear()
	incidents.clear()
	pops.clear()
	parts.clear()
	player_pos = Vector2(480, 440)
	spawn_t = 2.0
	banner_txt = "NIGHT 1 - CLOCK IN"
	banner_t = 2.5
	alert_t = 0.0
	new_best = false
	over_t = 0.0
	paused = false
	for i in 4:
		_spawn_customer(false)
	state = State.RUN
	_play("shift")


# ------------------------------------------------------------------ main loop
func _process(delta: float) -> void:
	time += delta
	shake = maxf(0.0, shake - delta * 28.0)
	flash = maxf(0.0, flash - delta * 2.5)
	position = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake
	if state == State.OVER:
		over_t += delta
	if state == State.RUN and not paused:
		_update_play(delta)
		_update_fx(delta)
	elif state == State.OVER:
		_update_fx(delta)
	queue_redraw()


func _update_play(delta: float) -> void:
	# --- clock / nights
	night_t += delta
	banner_t = maxf(0.0, banner_t - delta)
	alert_t = maxf(0.0, alert_t - delta)
	if night_t >= NIGHT_LEN:
		_shift_change()

	# --- combo decay
	if combo_t > 0.0:
		combo_t -= delta
		if combo_t <= 0.0:
			combo = 1

	# --- player movement (SHIFT = sprint, of course)
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	running = Input.is_key_pressed(KEY_SHIFT) and stamina > 0.0 and not exhausted and dir != Vector2.ZERO
	var spd := 190.0
	if running:
		spd = 330.0
		stamina -= delta * 0.55
		if stamina <= 0.0:
			stamina = 0.0
			exhausted = true
	else:
		stamina = minf(1.0, stamina + delta * 0.35)
		if exhausted and stamina > 0.3:
			exhausted = false
	player_pos += dir.normalized() * spd * delta
	player_pos = player_pos.clamp(AREA.position + Vector2(14, 14), AREA.end - Vector2(14, 14))
	player_pos = _push_out(player_pos, 14.0)
	if dir.x != 0.0:
		facing = signf(dir.x)

	# --- incidents spawn / expire
	spawn_t -= delta
	var max_inc := mini(3 + floori(night / 2.0), 6)
	if spawn_t <= 0.0 and incidents.size() < max_inc:
		_spawn_incident()
		spawn_t = maxf(1.4, 4.6 - 0.45 * float(night - 1)) * randf_range(0.7, 1.2)
	if incidents.is_empty() and spawn_t > 1.0:
		spawn_t = 1.0
	for i in range(incidents.size() - 1, -1, -1):
		var inc := incidents[i]
		inc.t -= delta
		if inc.t <= 0.0:
			var nm: String = INCIDENTS[inc.kind]["name"]
			incidents.remove_at(i)
			_strike("%s - BLAMED ON YOU!" % nm.to_upper())
	if state != State.RUN:
		return

	# --- planting evidence (hold SPACE / E next to an incident)
	acting = Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E)
	var near := _near_incident()
	for inc in incidents:
		if inc == near and acting:
			inc.prog += delta
		else:
			inc.prog = maxf(0.0, inc.prog - delta * 2.0)
	if near != null and acting:
		tick_t -= delta
		if tick_t <= 0.0:
			tick_t = 0.14
			_play("tick")
	if near != null and near.prog >= PLANT_TIME:
		_plant(near)

	_update_customers(delta)


func _update_customers(delta: float) -> void:
	for i in range(customers.size() - 1, -1, -1):
		var c := customers[i]
		c.bob += delta * 8.0
		match c.state:
			0:
				if c.wait > 0.0:
					c.wait -= delta
				else:
					var to := c.target - c.pos
					if to.length() < 6.0:
						c.wait = randf_range(0.8, 3.0)
						c.target = _free_point(20.0)
					else:
						var before := c.pos
						c.pos += to.normalized() * c.speed * delta
						c.pos = _push_out(c.pos, 12.0)
						if c.pos.distance_to(before) < c.speed * delta * 0.4:
							c.stuck += delta
						else:
							c.stuck = 0.0
						if c.stuck > 0.5:
							c.target = _free_point(20.0)
							c.stuck = 0.0
			1:
				c.timer -= delta
				if c.timer <= 0.0:
					c.state = 2
			2:
				var to2 := DOOR - c.pos
				c.pos += to2.normalized() * 170.0 * delta
				if to2.length() < 14.0:
					customers.remove_at(i)
	# keep the store populated
	var active := 0
	for c in customers:
		if c.state != 2:
			active += 1
	if active < mini(4 + night, 10) and randf() < delta * 0.8:
		_spawn_customer(true)


func _update_fx(delta: float) -> void:
	for i in range(pops.size() - 1, -1, -1):
		var p := pops[i]
		p.t -= delta
		p.pos.y -= 30.0 * delta
		if p.t <= 0.0:
			pops.remove_at(i)
	for i in range(parts.size() - 1, -1, -1):
		var q := parts[i]
		q["p"] += q["v"] * delta
		q["v"] *= 0.94
		q["t"] -= delta
		if q["t"] <= 0.0:
			parts.remove_at(i)


# ------------------------------------------------------------------ game logic
func _spawn_customer(at_door: bool) -> void:
	var c := Customer.new()
	c.type = _pick_type()
	c.pos = DOOR if at_door else _free_point(20.0)
	c.target = _free_point(20.0)
	c.speed = randf_range(55.0, 95.0) * (0.9 + 0.08 * float(night))
	if c.type == 4:
		c.speed *= 1.35
	c.bob = randf() * 6.0
	customers.append(c)


func _pick_type() -> int:
	var cops := 0
	for c in customers:
		if c.type == COP and c.state != 2:
			cops += 1
	if cops < mini(1 + floori(night / 3.0), 2) and randf() < 0.18:
		return COP
	var weights: Array[int] = [5, 4, 3, 3, 2]
	var total := 0
	for w in weights:
		total += w
	var r := randi() % total
	for i in weights.size():
		r -= weights[i]
		if r < 0:
			return i
	return 0


func _spawn_incident() -> void:
	for attempt in 25:
		var p := _free_point(34.0)
		if p.distance_to(player_pos) < 90.0:
			continue
		var ok := true
		for inc in incidents:
			if inc.pos.distance_to(p) < 120.0:
				ok = false
		if not ok:
			continue
		var n := Incident.new()
		n.pos = p
		n.kind = randi() % INCIDENTS.size()
		n.max_t = maxf(7.0, 14.0 - float(night) * 0.9)
		n.t = n.max_t
		incidents.append(n)
		_play("ping")
		return


func _near_incident() -> Incident:
	var found: Incident = null
	var bd := REACH
	for inc in incidents:
		var d := player_pos.distance_to(inc.pos)
		if d < bd:
			bd = d
			found = inc
	return found


func _best_target(inc: Incident) -> Customer:
	var found: Customer = null
	var bd := BLAME_RANGE
	for c in customers:
		if c.state != 0 or c.type == COP:
			continue
		var d := c.pos.distance_to(inc.pos)
		if d < bd:
			bd = d
			found = c
	return found


func _plant(inc: Incident) -> void:
	# A cop who sees you planting evidence ends the fun.
	for c in customers:
		if c.type == COP and c.pos.distance_to(player_pos) < COP_SIGHT:
			incidents.erase(inc)
			_play("caught")
			_strike("A COP SAW YOU PLANTING EVIDENCE!")
			return
	var tgt := _best_target(inc)
	if tgt == null:
		inc.prog = 0.0
		_pop(player_pos + Vector2(0, -40), "Nobody to blame!", Color("ff6b6b"), 16)
		_play("caught")
		return
	var info: Dictionary = TYPES[tgt.type]
	var mult: int = info["mult"]
	var frac := inc.t / inc.max_t
	var pts := int((100.0 + 100.0 * frac) * float(mult) * float(combo))
	score += pts
	_pop(tgt.pos + Vector2(0, -44), "+%d" % pts, Color("ffd166"), 24)
	_pop(tgt.pos + Vector2(0, -66), str(info["quip"]), Color.WHITE, 14)
	_burst(tgt.pos, Color("ffd166"), 22)
	tgt.state = 1
	tgt.timer = 2.2
	combo = mini(combo + 1, 8)
	combo_t = COMBO_TIME
	incidents.erase(inc)
	_play("win")


func _strike(msg: String) -> void:
	strikes += 1
	combo = 1
	combo_t = 0.0
	shake = 10.0
	flash = 1.0
	alert_txt = msg
	alert_t = 2.2
	_play("strike")
	if strikes >= MAX_STRIKES:
		_game_over()


func _game_over() -> void:
	state = State.OVER
	over_t = 0.0
	if score > best:
		best = score
		new_best = true
		_save_best()


func _shift_change() -> void:
	var bonus := 500 * night
	score += bonus
	night += 1
	night_t = 0.0
	incidents.clear()
	strikes = maxi(0, strikes - 1)
	spawn_t = 3.0
	banner_txt = "SHIFT CHANGE! +%d" % bonus
	banner_t = 3.0
	_play("shift")


func _push_out(p: Vector2, rad: float) -> Vector2:
	for r in obstacles:
		var g := r.grow(rad)
		if g.has_point(p):
			var dl := p.x - g.position.x
			var dr := g.end.x - p.x
			var dt := p.y - g.position.y
			var db := g.end.y - p.y
			var m := minf(minf(dl, dr), minf(dt, db))
			if m == dl:
				p.x = g.position.x
			elif m == dr:
				p.x = g.end.x
			elif m == dt:
				p.y = g.position.y
			else:
				p.y = g.end.y
	return p


func _free_point(margin: float) -> Vector2:
	for i in 30:
		var p := Vector2(
			randf_range(AREA.position.x + margin, AREA.end.x - margin),
			randf_range(AREA.position.y + margin, AREA.end.y - margin))
		var ok := true
		for r in obstacles:
			if r.grow(margin).has_point(p):
				ok = false
		if ok:
			return p
	return AREA.get_center()


func _pop(p: Vector2, s: String, col: Color, size: int) -> void:
	var n := Pop.new()
	n.pos = p
	n.text = s
	n.col = col
	n.size = size
	pops.append(n)


func _burst(p: Vector2, col: Color, n: int) -> void:
	for i in n:
		parts.append({
			"p": p,
			"v": Vector2.from_angle(randf() * TAU) * randf_range(60.0, 240.0),
			"t": randf_range(0.4, 0.9),
			"c": col,
		})


func _clock_text() -> String:
	var mins := 22 * 60 + int(480.0 * night_t / NIGHT_LEN)
	var h24 := floori(float(mins) / 60.0) % 24
	var m := mins % 60
	var h12 := h24 % 12
	if h12 == 0:
		h12 = 12
	return "%d:%02d %s" % [h12, m, "AM" if h24 < 12 else "PM"]


# ------------------------------------------------------------------ save / load
func _load_best() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f != null:
			best = f.get_32()


func _save_best() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_32(best)


# ------------------------------------------------------------------ audio (synthesised)
func _gen(f0: float, f1: float, dur: float, vol := 0.3, square := true) -> PackedByteArray:
	var rate := 22050
	var n := int(rate * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var k := float(i) / float(n)
		phase += TAU * lerpf(f0, f1, k) / float(rate)
		var s := sin(phase)
		if square:
			s = 1.0 if s >= 0.0 else -1.0
		var env := (1.0 - k) * minf(1.0, float(i) / 200.0)
		data.encode_s16(i * 2, int(s * env * vol * 32767.0))
	return data


func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 22050
	w.stereo = false
	w.data = data
	return w


func _build_sfx() -> void:
	var sounds := {
		"ping": _wav(_gen(880.0, 1250.0, 0.09, 0.2)),
		"tick": _wav(_gen(500.0, 560.0, 0.04, 0.15)),
		"win": _wav(_gen(523.0, 523.0, 0.07, 0.25) + _gen(659.0, 659.0, 0.07, 0.25) + _gen(988.0, 988.0, 0.16, 0.25)),
		"strike": _wav(_gen(240.0, 60.0, 0.5, 0.35)),
		"caught": _wav(_gen(420.0, 120.0, 0.3, 0.3)),
		"shift": _wav(_gen(392.0, 392.0, 0.09, 0.22) + _gen(523.0, 523.0, 0.09, 0.22) + _gen(659.0, 659.0, 0.09, 0.22) + _gen(784.0, 784.0, 0.25, 0.22)),
	}
	for key in sounds:
		var pl := AudioStreamPlayer.new()
		pl.stream = sounds[key]
		pl.volume_db = -6.0
		add_child(pl)
		sfx[key] = pl


func _play(name: String) -> void:
	if sfx.has(name):
		(sfx[name] as AudioStreamPlayer).play()


# ------------------------------------------------------------------ drawing helpers
func _text(s: String, p: Vector2, size: int, col: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> void:
	var w := 700.0
	var x := p.x - w * 0.5
	if align == HORIZONTAL_ALIGNMENT_LEFT:
		x = p.x
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		x = p.x - w
	draw_string(font, Vector2(x + 1.5, p.y + 1.5), s, align, w, size, Color(0, 0, 0, 0.65 * col.a))
	draw_string(font, Vector2(x, p.y), s, align, w, size, col)


func _draw() -> void:
	_draw_store()
	if state == State.TITLE:
		_draw_title()
		return
	for inc in incidents:
		_draw_incident(inc)
	_draw_target_hint()
	for c in customers:
		_draw_customer(c)
	_draw_player()
	for q in parts:
		var a := clampf(float(q["t"]) * 2.0, 0.0, 1.0)
		draw_circle(q["p"], 3.0, Color(q["c"], a))
	for p in pops:
		_text(p.text, p.pos, p.size, Color(p.col, clampf(p.t * 2.0, 0.0, 1.0)))
	_draw_hud()
	if flash > 0.0:
		draw_rect(Rect2(0, 0, W, H), Color(1, 0, 0, flash * 0.28))
	if paused:
		draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, 0.6))
		_text("PAUSED", Vector2(W / 2.0, H / 2.0), 48, Color.WHITE)
		_text("press P to resume", Vector2(W / 2.0, H / 2.0 + 36), 18, Color("bbbbbb"))
	if state == State.OVER:
		_draw_over()


func _draw_store() -> void:
	draw_rect(Rect2(0, 0, W, H), Color("1b2733"))
	draw_rect(Rect2(0, 52, W, 88), Color("22313f"))
	draw_rect(Rect2(0, 140, W, H - 140), Color("2c3e50"))
	for x in range(0, int(W), 40):
		for y in range(140, int(H), 40):
			if (x + y) % 80 == 0:
				draw_rect(Rect2(x, y, 40, 40), Color(1, 1, 1, 0.035))
	# back shelves
	draw_rect(Rect2(40, 90, 880, 44), Color("3b2f2f"))
	for i in 44:
		var hue := fmod(float(i) * 0.13, 1.0)
		draw_rect(Rect2(46 + i * 20, 96, 14, 14), Color.from_hsv(hue, 0.6, 0.9))
		draw_rect(Rect2(46 + i * 20, 114, 14, 14), Color.from_hsv(fmod(hue + 0.5, 1.0), 0.5, 0.85))
	# neon sign (flickers, because night shift)
	var flick := 1.0 if sin(time * 31.0) > -0.9 else 0.45
	_text("QUIK-E-MART  *  OPEN 24 HRS", Vector2(W / 2.0, 80), 18, Color(1.0, 0.35, 0.75, flick))
	# islands
	for r in obstacles:
		draw_rect(r, Color("5b4636"))
		draw_rect(Rect2(r.position.x, r.position.y, r.size.x, 8), Color("7a5c47"))
		for i in 8:
			var hue2 := fmod(float(i) * 0.17 + r.position.x * 0.01, 1.0)
			draw_rect(Rect2(r.position.x + 8 + i * 20, r.position.y + 12, 13, 13), Color.from_hsv(hue2, 0.55, 0.9))
	# door
	draw_rect(Rect2(DOOR.x - 40, H - 8, 80, 8), Color("ffd166"))
	_text("EXIT", Vector2(DOOR.x, H - 12), 11, Color("ffd166"))


func _draw_person(p: Vector2, type: int, bob: float) -> void:
	var info: Dictionary = TYPES[type]
	var col: Color = info["col"]
	var c := p + Vector2(0, sin(bob) * 1.5)
	draw_circle(p + Vector2(0, 15), 12.0, Color(0, 0, 0, 0.28))
	if type == 4:
		# the cat
		draw_line(c + Vector2(8, 6), c + Vector2(21, -2.0 + sin(bob * 0.7) * 4.0), col, 4.0)
		draw_circle(c + Vector2(0, 4), 11.0, col)
		draw_circle(c + Vector2(0, -6), 8.0, col)
		draw_colored_polygon(PackedVector2Array([c + Vector2(-8, -9), c + Vector2(-4, -18), c + Vector2(-1, -10)]), col)
		draw_colored_polygon(PackedVector2Array([c + Vector2(8, -9), c + Vector2(4, -18), c + Vector2(1, -10)]), col)
		draw_circle(c + Vector2(-3, -7), 1.8, Color("2e8b57"))
		draw_circle(c + Vector2(3, -7), 1.8, Color("2e8b57"))
		draw_line(c + Vector2(-5, -4), c + Vector2(-13, -6), Color("ffffff"), 1.0)
		draw_line(c + Vector2(5, -4), c + Vector2(13, -6), Color("ffffff"), 1.0)
		return
	draw_circle(c + Vector2(0, 4), 13.0, col)
	var skin := Color("f1c27d")
	if type == 2:
		draw_circle(c + Vector2(0, -15), 11.0, Color("d9d9e3"))
	draw_circle(c + Vector2(0, -14), 9.0, Color("ffffff") if type == 1 else skin)
	draw_circle(c + Vector2(-3, -15), 1.6, Color("222222"))
	draw_circle(c + Vector2(3, -15), 1.6, Color("222222"))
	match type:
		0:
			draw_rect(Rect2(c.x - 9, c.y - 26, 18, 6), Color("ff4d4d"))
			draw_rect(Rect2(c.x - 2, c.y - 21, 13, 3), Color("ff4d4d"))
		1:
			for i in 3:
				draw_line(c + Vector2(-11, -2 + i * 5), c + Vector2(11, -2 + i * 5), Color("222222"), 2.0)
			draw_circle(c + Vector2(0, -23), 6.0, Color("222222"))
		2:
			draw_arc(c + Vector2(-3, -15), 3.0, 0.0, TAU, 12, Color("444444"), 1.0)
			draw_arc(c + Vector2(3, -15), 3.0, 0.0, TAU, 12, Color("444444"), 1.0)
		3:
			draw_rect(Rect2(c.x - 3, c.y - 6, 6, 5), Color.WHITE)
		5:
			draw_rect(Rect2(c.x - 10, c.y - 27, 20, 7), Color("1d3b8b"))
			draw_circle(c + Vector2(5, 2), 3.0, Color("ffd166"))


func _draw_customer(c: Customer) -> void:
	var info: Dictionary = TYPES[c.type]
	var p := c.pos
	if c.type == COP:
		var seen := player_pos.distance_to(c.pos) < COP_SIGHT
		draw_circle(p, COP_SIGHT, Color(1, 0.2, 0.2, 0.16 if seen else 0.06))
		draw_arc(p, COP_SIGHT, 0.0, TAU, 48, Color(1, 0.3, 0.3, 0.5 if seen else 0.22), 2.0)
	if c.state == 1:
		p += Vector2(randf_range(-2.0, 2.0), 0)
		draw_arc(p, 24.0, 0.0, TAU, 24, Color("ff3b3b"), 3.0)
		_text("GUILTY!", p + Vector2(0, -42), 16, Color("ff3b3b"))
	_draw_person(p, c.type, c.bob)
	if c.state == 0:
		var m: int = info["mult"]
		if c.type != COP:
			_text("x%d" % m, p + Vector2(0, -30), 11, Color(1, 1, 1, 0.55))
		else:
			_text("COP", p + Vector2(0, -32), 11, Color(0.6, 0.75, 1.0, 0.8))


func _draw_player() -> void:
	var c := player_pos + Vector2(0, sin(time * (16.0 if running else 8.0)) * 1.5)
	draw_circle(player_pos + Vector2(0, 15), 12.0, Color(0, 0, 0, 0.3))
	draw_circle(c + Vector2(0, 4), 13.0, Color("d62839"))
	draw_rect(Rect2(c.x - 4, c.y - 6, 8, 14), Color("ffffff"))
	draw_circle(c + Vector2(0, -14), 9.0, Color("f1c27d"))
	draw_circle(c + Vector2(-3.0 + facing * 1.5, -15), 1.6, Color("222222"))
	draw_circle(c + Vector2(3.0 + facing * 1.5, -15), 1.6, Color("222222"))
	draw_rect(Rect2(c.x - 10, c.y - 26, 20, 6), Color("2a9d8f"))
	draw_rect(Rect2(c.x + (2.0 if facing > 0.0 else -13.0), c.y - 21, 11, 3), Color("2a9d8f"))
	draw_rect(Rect2(c.x - 9, c.y + 1, 7, 4), Color("ffffff"))  # name tag
	if running:
		draw_circle(player_pos + Vector2(-facing * 14.0, 12), 3.0, Color(1, 1, 1, 0.35))
	if stamina < 1.0:
		var bw := 30.0
		draw_rect(Rect2(player_pos.x - bw / 2.0, player_pos.y + 22, bw, 4), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(player_pos.x - bw / 2.0, player_pos.y + 22, bw * stamina, 4), Color("ff6b6b") if exhausted else Color("7df9ff"))


func _draw_incident(inc: Incident) -> void:
	var info: Dictionary = INCIDENTS[inc.kind]
	var col: Color = info["col"]
	var frac := inc.t / inc.max_t
	var pulse := 1.0 + 0.12 * sin(time * 8.0)
	draw_circle(inc.pos, 22.0 * pulse, Color(col, 0.3))
	draw_circle(inc.pos, 12.0, col)
	_text("!", inc.pos + Vector2(0, 7), 20, Color("222222"))
	var ring := Color("ff3b3b").lerp(Color("5dff7a"), frac)
	draw_arc(inc.pos, 29.0, -PI / 2.0, -PI / 2.0 + TAU * frac, 40, ring, 4.0)
	if inc.prog > 0.0:
		draw_arc(inc.pos, 19.0, -PI / 2.0, -PI / 2.0 + TAU * clampf(inc.prog / PLANT_TIME, 0.0, 1.0), 24, Color.WHITE, 5.0)
	_text(str(info["name"]), inc.pos + Vector2(0, 50), 12, Color.WHITE)
	if fmod(time, 0.8) < 0.5:
		_text("BLAME: YOU", inc.pos + Vector2(0, -40), 12, Color("ff6b6b"))
	if _near_incident() == inc and inc.prog <= 0.0:
		_text("[HOLD SPACE]", inc.pos + Vector2(0, 64), 12, Color("ffe14d"))


func _draw_target_hint() -> void:
	var near := _near_incident()
	if near == null:
		return
	draw_arc(near.pos, BLAME_RANGE, 0.0, TAU, 64, Color(1, 1, 1, 0.12), 2.0)
	var tgt := _best_target(near)
	if tgt != null:
		var info: Dictionary = TYPES[tgt.type]
		draw_dashed_line(near.pos, tgt.pos, Color("ffe14d"), 2.0, 8.0)
		draw_arc(tgt.pos, 22.0 + sin(time * 10.0) * 2.0, 0.0, TAU, 32, Color("ffe14d"), 3.0)
		_text("FRAME x%d" % int(info["mult"]), tgt.pos + Vector2(0, 40), 13, Color("ffe14d"))


func _draw_hud() -> void:
	draw_rect(Rect2(0, 0, W, 52), Color(0, 0, 0, 0.7))
	_text("SCORE %d" % score, Vector2(16, 28), 24, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT)
	_text("BEST %d" % best, Vector2(16, 46), 12, Color("aaaaaa"), HORIZONTAL_ALIGNMENT_LEFT)
	_text(_clock_text(), Vector2(W / 2.0, 28), 26, Color("7df9ff"))
	_text("NIGHT %d" % night, Vector2(W / 2.0, 46), 12, Color("aaaaaa"))
	# pink slips
	_text("PINK SLIPS", Vector2(W - 16, 18), 11, Color("aaaaaa"), HORIZONTAL_ALIGNMENT_RIGHT)
	for i in MAX_STRIKES:
		var x := W - 16.0 - 24.0 * float(MAX_STRIKES - i)
		var used := i < strikes
		draw_rect(Rect2(x, 24, 20, 22), Color("ff8fab") if used else Color(1, 1, 1, 0.12))
		if used:
			_text("X", Vector2(x + 10, 41), 16, Color("7a1230"))
	# combo
	if combo > 1:
		_text("COMBO x%d" % combo, Vector2(260, 30), 22, Color("ffd166"), HORIZONTAL_ALIGNMENT_LEFT)
		draw_rect(Rect2(260, 38, 120, 5), Color(1, 1, 1, 0.15))
		draw_rect(Rect2(260, 38, 120.0 * clampf(combo_t / COMBO_TIME, 0.0, 1.0), 5), Color("ffd166"))
	# stamina
	draw_rect(Rect2(16, H - 22, 140, 10), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(16, H - 22, 140.0 * stamina, 10), Color("ff6b6b") if exhausted else Color("7df9ff"))
	_text("HOLD SHIFT TO SPRINT", Vector2(16, H - 28), 11, Color("bbbbbb"), HORIZONTAL_ALIGNMENT_LEFT)
	if night == 1 and night_t < 25.0 and state == State.RUN:
		_text("Hold SPACE next to a ! to frame the nearest customer. Rarer suspects = more points. Dodge the cops' red zones!", Vector2(W / 2.0, H - 40), 13, Color(1, 1, 1, 0.75))
	if alert_t > 0.0:
		_text(alert_txt, Vector2(W / 2.0, 108), 22, Color(1.0, 0.42, 0.42, clampf(alert_t * 2.0, 0.0, 1.0)))
	if banner_t > 0.0:
		_text(banner_txt, Vector2(W / 2.0, 220), 40, Color(0.49, 0.98, 1.0, clampf(banner_t, 0.0, 1.0)))


func _draw_title() -> void:
	draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, 0.55))
	var bob := sin(time * 2.0) * 4.0
	_text("BLAME SHIFT", Vector2(W / 2.0, 190 + bob), 72, Color("ff5fa2"))
	_text("It's 3 AM. You did it. Make it somebody else's fault.", Vector2(W / 2.0, 232), 20, Color("dddddd"))
	for i in 6:
		var x := 150.0 + float(i) * 132.0
		_draw_person(Vector2(x, 330), i, time * 6.0 + float(i))
		var info: Dictionary = TYPES[i]
		_text(str(info["name"]), Vector2(x, 366), 14, Color.WHITE)
		if i == COP:
			_text("WITNESS!", Vector2(x, 384), 13, Color("ff6b6b"))
		else:
			_text("x%d" % int(info["mult"]), Vector2(x, 384), 14, Color("ffd166"))
	_text("WASD / Arrows: move     SHIFT: sprint     Hold SPACE: plant evidence     P: pause", Vector2(W / 2.0, 430), 15, Color("bbbbbb"))
	_text("Press ENTER to clock in", Vector2(W / 2.0, 480), 28, Color("7df9ff") if fmod(time, 1.0) < 0.7 else Color(0.49, 0.98, 1.0, 0.3))
	if best > 0:
		_text("BEST: %d" % best, Vector2(W / 2.0, 508), 16, Color("ffd166"))


func _draw_over() -> void:
	draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, 0.7))
	_text("YOU'RE FIRED!", Vector2(W / 2.0, 200), 64, Color("ff5f5f"))
	_text("Final score: %d" % score, Vector2(W / 2.0, 255), 28, Color.WHITE)
	if new_best:
		_text("NEW BEST!", Vector2(W / 2.0, 290), 22, Color("ffd166"))
	else:
		_text("Best: %d" % best, Vector2(W / 2.0, 290), 18, Color("aaaaaa"))
	_text("You survived %d night(s) and framed an entire neighborhood." % night, Vector2(W / 2.0, 330), 16, Color("cccccc"))
	if over_t > 0.8:
		_text("Press ENTER to clock back in", Vector2(W / 2.0, 400), 24, Color("7df9ff"))
