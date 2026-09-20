extends RefCounted
## Dice in place of a battle.
##
## This is scaffolding with a known expiry date: at M7 the real battle sim replaces it
## and this file gets called only for battles no human is present to fight. It exists
## so the campaign loop can close now rather than waiting on the hardest part of the
## project, and so the handoff (campaign -> battle -> casualties -> campaign) is
## exercised from the start instead of being bolted on at the end.

const Rules := preload("res://sim/rules.gd")

const LUCK := 0.25           # +/- swing on each side's effective strength
const LOSER_MIN := 0.6       # the beaten side loses at least this share of its regiments
const WINNER_SHARE := 0.5    # the winner's losses, scaled by how close the fight was


static func power(kinds: Array) -> int:
	var total := 0
	for kind in kinds:
		total += int(Rules.KINDS[kind]["strength"])
	return total


## Returns {"attacker_wins": bool, "attacker_losses": int, "defender_losses": int},
## counted in regiments. The caller removes them and disbands whatever is left empty.
static func resolve(attacker: Array, defender: Array, rng: RandomNumberGenerator) -> Dictionary:
	if attacker.is_empty() and defender.is_empty():
		return {"attacker_wins": false, "attacker_losses": 0, "defender_losses": 0}
	if attacker.is_empty():
		return {"attacker_wins": false, "attacker_losses": 0, "defender_losses": 0}
	if defender.is_empty():
		return {"attacker_wins": true, "attacker_losses": 0, "defender_losses": 0}

	# ponytail: no terrain, no defender's advantage, no unit matchups. All of that is
	# the real battle's job -- putting it here would only be a worse version of it.
	var att := float(power(attacker)) * rng.randf_range(1.0 - LUCK, 1.0 + LUCK)
	var def := float(power(defender)) * rng.randf_range(1.0 - LUCK, 1.0 + LUCK)
	var attacker_wins := att >= def
	var closeness: float = minf(att, def) / maxf(att, def)

	var winner: Array = attacker if attacker_wins else defender
	var loser: Array = defender if attacker_wins else attacker
	var winner_losses := mini(winner.size() - 1, int(round(winner.size() * closeness * WINNER_SHARE)))
	var loser_losses := int(ceil(loser.size() * rng.randf_range(LOSER_MIN, 1.0)))

	return {
		"attacker_wins": attacker_wins,
		"attacker_losses": maxi(0, winner_losses if attacker_wins else loser_losses),
		"defender_losses": maxi(0, loser_losses if attacker_wins else winner_losses),
	}
