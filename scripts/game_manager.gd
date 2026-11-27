extends Node
## Game / gamemode definitions used by the host lobby.

const GAMES: Array = ["Shooter", "Campaign"]

## Per-game gamemodes. Keys must match GAMES entries.
const GAMEMODES: Dictionary = {
	"Shooter": ["Deathmatch", "Defusal", "Team Deathmatch"],
	"Campaign": ["Co-op", "Story"]
}


func get_games() -> Array:
	return GAMES.duplicate()


func get_gamemodes(game: String) -> Array:
	if GAMEMODES.has(game):
		return GAMEMODES[game].duplicate()
	return []


func get_default_gamemode(game: String) -> String:
	var modes := get_gamemodes(game)
	if modes.is_empty():
		return ""
	return modes[0]
