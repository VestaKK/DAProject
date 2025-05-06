package main

import "core:fmt"
import lg "core:math/linalg"
import rl "vendor:raylib"

WIDTH :: 1000
HEIGHT :: 500 
GRID_WIDTH :: 20
CELL_SIZE :: 16
CANVAS_SIZE :: GRID_WIDTH * CELL_SIZE

Player :: struct {
    id: i64,
    using pos: [2]f32,
    facing: [2]f32,
    speed: f32,
    src: rl.Rectangle,
    dest: rl.Rectangle,
    moving: bool,
    player_up: bool,
    player_down: bool,
    player_left: bool,
    player_right: bool, 
    player_frame: i32,
    direction: i32,
    attacking: bool,
    attacking_src: rl.Rectangle,
    place_fence: bool,
    placing_fence: bool,
    player_num: i32
}
Fence :: struct {
    src: rl.Rectangle,
    dest: rl.Rectangle
}
CurrentFence :: struct {
    src: rl.Rectangle,
    dest: rl.Rectangle
}

camera := rl.Camera2D{}
player := Player{
        id = 1,
        pos = {80 ,77},
        speed = 7,
        src = rl.Rectangle{0, 0, 48, 48},
        attacking_src = rl.Rectangle{5, 0, 48, 48},
        moving = false, 
        player_up = false, 
        player_down = false,  
        player_left = false,  
        player_right = false,
        player_frame = 0,
        attacking = false,
        place_fence = false,
        placing_fence = false
}
framecount := 0
fences: [dynamic]Fence
current_fence := CurrentFence{
    src = rl.Rectangle{0, 48, 16, 16},
    dest = rl.Rectangle{0, 0, 20, 20}
}

get_ani :: proc(player: Player) -> rl.Color {
    switch player.facing {
        case {0, 0}:
            return {100, 100, 100, 255}
        case {0, 1}:
            return {255, 0, 0, 255}
        case {0, -1}:
            return {0, 255, 0, 255}
        case {1, 0}:
            return {0, 0, 255, 255}
        case {-1, 0}:
            return {255, 0, 255, 255}
        case {1, 1}:
            return {255, 255, 0, 255}
        case {1, -1}:
            return {0, 255, 255, 255}
        case {-1, 1}:
            return {125, 125, 125, 255}
        case {-1, -1}:
            return {76, 29, 144, 255}
    }
    return {255, 0, 0, 255}
}

move_player :: proc(dt: f64) {
    
    grid_speed :: proc(speed: f32) -> f32 {
        return CELL_SIZE * speed
    }

    if player.attacking {
        player.attacking_src.x = 48
    } else {
        player.attacking_src.x = 0
    }

    dir: [2]f32
    if rl.IsKeyDown(.A) {
        if player.pos[0] > 66 {
            player.moving = true
            player.player_left = true
            player.direction = 2
        }
    }
    if rl.IsKeyDown(.D) {
        if player.pos[0] < 1047 {
            player.moving = true
            player.player_right = true
            player.direction = 3
        }
    } 
    if rl.IsKeyDown(.S) {
        if player.pos[1] < 560 {
            player.moving = true
            player.player_down = true
            player.direction = 0
        }
    }
    if rl.IsKeyDown(.W) {
        if player.pos[1] > 66 {
            player.moving = true
            player.player_up = true
            player.direction = 1
        }
    }
    if rl.IsKeyDown(.E) {
        player.attacking = true
        player.attacking_src.y = (4 * player.attacking_src.height) + (f32(player.direction) * player.attacking_src.height)
    } else {
        player.attacking = false
    }
    if rl.IsKeyDown(.Q) {
        player.placing_fence = true
        player.place_fence = false
    } else if rl.IsKeyReleased(.Q) {
        player.placing_fence = false
        player.place_fence = true
    }

    player.src.x = 0

    if player.moving {
        if player.player_up {
            dir = {0, 1}
        } else if player.player_down {
            dir = {0, -1}
        } else if player.player_left {
            dir = {1, 0}
        } else if player.player_right {
            dir = {-1, 0}
        }
        if framecount % 8 == 1 {
            player.player_frame += 1
        }
        player.src.x = player.src.width * f32(player.player_frame)
    }

    player.src.y = player.src.height * f32(player.direction)

    if dir != {} {
        dir_norm := lg.normalize(dir)
        player.pos += dir_norm * grid_speed(player.speed) * f32(dt)
    }
    
    player.facing = dir
    
    if player.player_frame > 3 {
        player.player_frame = 0
    }
}

main :: proc() {
    rl.InitWindow(WIDTH, HEIGHT, "Game")
    rl.SetTargetFPS(60)

    time := rl.GetTime()
    background := rl.LoadTexture("./map.png")
    character := rl.LoadTexture("./Spritesheet.png")
    characterAttack := rl.LoadTexture("./actions.png")
    fenceT := rl.LoadTexture("./Fences.png")
    camera.zoom = f32(WIDTH) / CANVAS_SIZE

    for !rl.WindowShouldClose() {
        curr := rl.GetTime()
        dt := time - rl.GetTime()
        time = curr

        move_player(dt)
        player.dest = rl.Rectangle{player.pos[0], player.pos[1], 60, 60}
        camera.target = {player.pos[0] - CANVAS_SIZE/2 - 40, player.pos[1] - 120}
        
        rl.BeginDrawing()
        rl.BeginMode2D(camera)
        rl.ClearBackground({155, 212, 195, 255}) 
        rl.DrawTexture(background, 1, 1, {255, 255, 255, 255})

        for fence in fences {
            rl.DrawTexturePro(fenceT, fence.src, fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        }

        if player.attacking {
            rl.DrawTexturePro(characterAttack, player.attacking_src, player.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        } else if player.placing_fence {
            if player.direction == 0 {
                rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
                current_fence.dest = rl.Rectangle{player.pos[0] + 20, player.pos[1] + 25, 20, 20}
                rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
            } else if player.direction == 1 {
                current_fence.dest = rl.Rectangle{player.pos[0] + 20, player.pos[1] + 15, 20, 20}
                rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
                rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
            } else if player.direction == 2 {
                current_fence.dest = rl.Rectangle{player.pos[0] + 15, player.pos[1] + 20, 20, 20}
                rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
                rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
            } else if player.direction == 3 {
                current_fence.dest = rl.Rectangle{player.pos[0] + 25, player.pos[1] + 20, 20, 20}
                rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
                rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
            } 
        } else {
            rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        }
        if player.place_fence {
            append(&fences, Fence{current_fence.src, current_fence.dest})
            player.place_fence = false
        }

        rl.EndDrawing()

        player.moving = false
        player.player_up, player.player_down, player.player_left, player.player_right = false, false, false, false

        framecount += 1
    }
    
    rl.UnloadTexture(fenceT)
    rl.UnloadTexture(background)
    rl.UnloadTexture(character)
    rl.UnloadTexture(characterAttack)
    rl.CloseWindow()
}