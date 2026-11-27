# Character models

Place PSX character assets here.

## Folder layout

```
assets/characters/models/
  <model_id>/
    model.tscn   (preferred — Godot-imported scene you can tweak)
    # or .glb / .gltf / .fbx
```

Example after importing **Characters PSX** (Elbolilloduro):

1. Download from https://elbolilloduro.itch.io/characters-psx
2. Import an FBX into Godot (drag into `models/civilian_01/`)
3. Open the imported scene, fix scale/rotation if needed, save as `model.tscn`
4. Set `character_model_id = "civilian_01"` on the player (or use the future model menu)

Until a model is present, a blue placeholder body is used so multiplayer still works.

## Node structure (player)

```
BaseController (CharacterBody3D)
├── CollisionShape3D          # gameplay capsule
├── ModelRoot (CharacterModel)# visual body (hidden for local FPS camera)
│   └── Instance              # imported character
├── Head
│   └── Camera3D
├── FootstepPlayers
├── Base Hud
└── EscapeMenu
```
