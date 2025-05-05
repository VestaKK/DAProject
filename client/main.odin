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
    model: struct {
        color: rl.Color,
        size: [2]f32,
    },
    src: rl.Rectangle,
    dest: rl.Rectangle
}

camera := rl.Camera2D{}
player := Player{
        id = 1,
        pos = {80 ,77},
        speed = 7,
        model = {
            color = {0, 0, 0, 255},
            size = {CELL_SIZE, CELL_SIZE},
        }
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

    dir: [2]f32
    if rl.IsKeyDown(.A) {
        if player.pos[0] > 66 {
            dir += {+1, 0}
        }
    }
    if rl.IsKeyDown(.D) {
        if player.pos[0] < 1047 {
            dir += {-1, 0}
        }
    } 
    if rl.IsKeyDown(.S) {
        if player.pos[1] < 560 {
            dir += {0, -1}
        }
    }
    if rl.IsKeyDown(.W) {
        if player.pos[1] > 66 {
            dir += {0, +1}
        }
    }

    if dir != {} {
        dir_norm := lg.normalize(dir)
        player.pos += dir_norm * grid_speed(player.speed) * f32(dt)
        fmt.eprintln("Player pos: ", player.pos)
    }
    player.facing = dir
    player.model.color = get_ani(player)
}

main :: proc() {
    rl.InitWindow(WIDTH, HEIGHT, "Game")

    time := rl.GetTime()
    background := rl.LoadTexture("./map.png")
    character := rl.LoadTexture("./Spritesheet.png")
    player.src = rl.Rectangle{0, 0, 48, 48}
    camera.zoom = f32(WIDTH) / CANVAS_SIZE

    for !rl.WindowShouldClose() {
        curr := rl.GetTime()
        dt := time - rl.GetTime()
        time = curr

        move_player(dt)
        player.dest = rl.Rectangle{player.pos[0] - (player.model.size[0]/2), player.pos[1] - (player.model.size[1]/2), 60, 60}
        camera.target = {player.pos[0] - CANVAS_SIZE/2 - 40, player.pos[1] - 120}
        
        rl.BeginDrawing()
        rl.BeginMode2D(camera)
        rl.ClearBackground({155, 212, 195, 255}) 
        rl.DrawTexture(background, 1, 1, {255, 255, 255, 255})
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        rl.EndDrawing()
    }
    rl.UnloadTexture(background)
    rl.UnloadTexture(character)
    rl.CloseWindow()
}