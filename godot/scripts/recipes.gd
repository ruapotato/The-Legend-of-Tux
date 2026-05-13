extends Node

# Craft recipe registry. Each recipe entry:
#   id           — unique key (also the inventory item name granted)
#   display      — human-readable label
#   cost         — Dictionary of resource_id → amount
#   description  — flavour line shown next to the craft button
#   station      — "" (anywhere) or "workbench" / "forge" / etc.
#   key_item     — true → set GameState.inventory[id] = true on craft
#                  false → call GameState.add_resource(id, amount_out)
#   amount_out   — only used when key_item=false
#
# Loaded as an autoload so any UI can read the table.

const RECIPES: Dictionary = {
	"sapling_blade": {
		"display": "Sapling Blade",
		"cost": {"wood": 3},
		"description": "A practice sword carved from a young sapling.",
		"station": "workbench",
		"key_item": true,
	},
	"bark_round": {
		"display": "Bark Round",
		"cost": {"wood": 4},
		"description": "A round shield woven from inner bark.",
		"station": "workbench",
		"key_item": true,
	},
	"hammer": {
		"display": "Builder's Hammer",
		"cost": {"wood": 3, "stone": 2},
		"description": "Enters build mode to place wooden pieces.",
		"station": "workbench",
		"key_item": true,
	},
	"stone_axe": {
		"display": "Stone Axe",
		"cost": {"wood": 4, "stone": 2},
		"description": "Fells trees in half the swings.",
		"station": "workbench",
		"key_item": true,
	},
	"cooked_meat": {
		"display": "Cooked Meat",
		"cost": {"meat_raw": 1},
		"description": "Fills stamina and warmth. Cook over a fire.",
		"station": "workbench",
		"key_item": false,
		"amount_out": 1,
	},
}


# All recipes available at a given station. station="" means anywhere.
func recipes_for_station(station: String) -> Array:
	var out: Array = []
	for id in RECIPES.keys():
		var r: Dictionary = RECIPES[id]
		if station == "" or String(r.get("station", "")) == station:
			out.append({"id": id, "data": r})
	return out


# True if the player has the resources for this recipe right now.
func can_craft(id: String) -> bool:
	if not RECIPES.has(id):
		return false
	var r: Dictionary = RECIPES[id]
	return GameState.has_resources(r.get("cost", {}))


# Atomic craft: spend resources, then grant output. Returns true on
# success. Caller can read the recipe's `key_item` to know whether to
# surface a key-item or resource notification.
func craft(id: String) -> bool:
	if not can_craft(id):
		return false
	var r: Dictionary = RECIPES[id]
	if not GameState.consume_resources(r.get("cost", {})):
		return false
	if r.get("key_item", false):
		GameState.acquire_item(id)
	else:
		GameState.add_resource(id, int(r.get("amount_out", 1)))
	return true
