package main

import "core:net"
import "core:fmt"
import "core:os/os2"
import "core:encoding/cbor"
import sh "../shared"
import b "core:bytes"
import "core:mem"
import "base:intrinsics"
import "core:flags"
import rl "vendor:raylib"
import gp "game_packet"
import "core:time"
import lg "core:math/linalg"

Options :: struct {
    port: int `args:"pos=0,requied" usage:"Client Port"`,
    lobby_id: i64 `args:"pos=1,required" usage:"Lobby ID"`,
    role: Role `args:"pos=2,required" usage:"Role"`,
}

Lobby_Data:: struct {

    // Host or Joining
    role: Role,

    // Unique lobby id
    lobby_id: i64,

    // id as assigned by server
    assigned_id: i64,
    lobby_name: string,
    user_name: string,
    host_name: string,
}

Role :: enum {
    Host,
    Join,
}

Scene :: enum {
    Start,
    Load,
    Game,
}

State :: struct {

    lobby: Lobby_Data,

    window: struct {
        width, height: int
    },
        
    network: gp.Network,
    this_net_id: int,
}

// Game Structs
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
    color: rl.Color,
    health: i32,
    moved: bool,
    attack_done: bool
}

Fence :: struct {
    src: rl.Rectangle,
    dest: rl.Rectangle,
    health: int,
    id: [2]int
}

// Game State intialization
WIDTH :: 1000
HEIGHT :: 500 
GRID_WIDTH :: 20
CELL_SIZE :: 16
CANVAS_SIZE :: GRID_WIDTH * CELL_SIZE

camera := rl.Camera2D{}

player := Player{
    id = 1,
    pos = {80, 77},
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
    placing_fence = false,
    color = rl.WHITE,
    health = 100,
    moved = false,
    attack_done = false
}

framecount := 0

fences: [dynamic]Fence

current_fence := Fence{
    src = rl.Rectangle{0, 48, 16, 16},
    dest = rl.Rectangle{0, 0, 20, 20}
}

last_fence_dest := rl.Rectangle{}

// Response scratch buffer
buf: [1024]byte

// Some error thing idk its a placeholder
last_error_string := ""

_main :: proc() {

    // Game State
    WINDOW_TITLE :: "Distributed Algorithms Project"
    WINDOW_HEIGHT :: 500
    WINDOW_WIDTH :: 500
    state: State
    state.window.height = WINDOW_HEIGHT
    state.window.width = WINDOW_WIDTH

    // Argument Parsing Things
    opt: Options
    style := flags.Parsing_Style.Odin
    flags.parse_or_exit(&opt, os2.args, style)

    // Get IP DHCP IPv4 address for this device
    // We just choose the first one since it's unlikely for
    // a single machine to have more than 2 IP addresses linked to the device
    interfaces, _ := net.enumerate_interfaces()
    defer net.destroy_interfaces(interfaces)
    bound_address := net.Address{}
    outer: for interface in interfaces {
        if _, ok := interface.dhcp_v4.(net.IP4_Address); ok {
            for lease in interface.unicast {
                switch address in lease.address {
                    case net.IP4_Address:
                        bound_address = address
                        break outer
                    case net.IP6_Address:
                        // skip cause IP6 is complicated?
                }
            }
        }
    }
    if bound_address == {} {
        fmt.eprintln("Could not find an IPv4 address for this machine")
        os2.exit(1)
    }

    // Make socket
    bound_endpoint := net.Endpoint{bound_address, opt.port}
    fmt.println(bound_endpoint)
    
    client, make_err := net.make_bound_udp_socket(bound_address, opt.port)
    if make_err != nil {
        fmt.eprintln(net.last_platform_error_string())
        os2.exit(1)
    }
    defer net.close(client)

    server_endpoint := net.Endpoint{net.IP4_Address{120, 156, 242, 163}, 1111}
    rl.SetTraceLogLevel(.FATAL)

    switch opt.role {
        case .Host:
            lobby_data, create_ok := create_lobby(client, server_endpoint, bound_endpoint, opt.lobby_id, "My Lobby", "Anthony Albanese")
            if !create_ok {
                fmt.eprintln(last_error_string)
                os2.exit(1)
            } 
            state.lobby = lobby_data

            rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
            host_scene(&state, client, server_endpoint)

        case .Join:
            lobby_data, join_ok := join_lobby(client, server_endpoint, bound_endpoint, opt.lobby_id, "Tony Abbott")
            if !join_ok {
                fmt.eprintln(last_error_string)
                os2.exit(1)
            }
            state.lobby = lobby_data

            rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
            join_scene(&state, client, server_endpoint)
    }

    play_game(&state)

    rl.CloseWindow()
}

host_scene :: proc(state: ^State, socket: net.UDP_Socket, server_endpoint: net.Endpoint) {

    // Wait for host to start the game
    for !rl.WindowShouldClose() {
        if rl.IsKeyPressed(.A) {
            init_start_lobby(socket, server_endpoint, state.lobby)
            break
        }
        rl.BeginDrawing()
        rl.ClearBackground({200, 200, 140, 255}) 
        text_width := rl.MeasureText("Press A to start the lobby", 20)
        rl.DrawText("Press A to start the lobby", (i32(state.window.width) - text_width)/2, i32(state.window.height)/2, 20, {0, 0, 0, 255})
        rl.EndDrawing()
    }

    err := net.set_blocking(socket, false)
    if err != nil {
        fmt.eprintln(err)
        os2.exit(1)
    }

    setup_connections :: proc(state: ^State, socket: net.UDP_Socket, response: sh.Start_Lobby_Response) {
        state.this_net_id, _  = gp.init_network(
            &state.network, 
            socket, 
            response.host.endpoint,
            gp.default_delete_proc,
            gp.default_clone_proc,
            true
        )
        for peer_profile in response.players {
            gp.add_connection(&state.network, peer_profile.endpoint)
        }
    }

    for !rl.WindowShouldClose() {
        bytes_read, endpoint, err := net.recv_udp(socket, buf[:])
        if bytes_read > 0 && endpoint == server_endpoint { 
            response: sh.Response
            cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &response)
            start_lobby_response := &response.(sh.Start_Lobby_Response)
            setup_connections(state, socket, start_lobby_response^)
            break
        }
        rl.BeginDrawing()
        rl.ClearBackground({200, 200, 140, 255}) 
        text_width := rl.MeasureText("Linking Clients...", 20)
        rl.DrawText("Linking Clients...", (i32(state.window.width) - text_width)/2, i32(state.window.height)/2, 20, {0, 0, 0, 255})
        rl.EndDrawing()
    }
}

join_scene :: proc(state: ^State, socket: net.UDP_Socket, server_endpoint: net.Endpoint) {
    err := net.set_blocking(socket, false) 
    if err != nil {
        fmt.eprintln(err)
        os2.exit(1)
    }

    setup_connections :: proc(state: ^State, socket: net.UDP_Socket, response: sh.Start_Lobby_Response) {
        state.this_net_id, _  = gp.init_network(
            &state.network, 
            socket, 
            response.host.endpoint,
            gp.default_delete_proc,
            gp.default_clone_proc,
        )
        for peer_profile in response.players {
            if peer_profile.assigned_id == state.lobby.assigned_id {
                gp.add_connection(&state.network, peer_profile.endpoint, true)
            } else {
                gp.add_connection(&state.network, peer_profile.endpoint)
            }
        }
    }

    for !rl.WindowShouldClose() {
        bytes_read, endpoint, err := net.recv_udp(socket, buf[:])
        if bytes_read > 0 && endpoint == server_endpoint { 
            response: sh.Response
            cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &response)
            start_lobby_response := &response.(sh.Start_Lobby_Response)
            setup_connections(state, socket, start_lobby_response^)
            break
        }

        rl.BeginDrawing()
        rl.ClearBackground({200, 200, 140, 255}) 
        text_width := rl.MeasureText("Waiting for lobby to start...", 20)
        rl.DrawText("Waiting for lobby to start...", (i32(state.window.width) - text_width)/2, i32(state.window.height)/2, 20, {0, 0, 0, 255})
        rl.EndDrawing()
    }
}

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    defer {
        if len(track.allocation_map) > 0 {
            fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
            for _, entry in track.allocation_map {
                fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
            }
        }
        if len(track.bad_free_array) > 0 {
            fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
            for entry in track.bad_free_array {
                fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
            }
        }
        mem.tracking_allocator_destroy(&track)
    }

    _main()
}

send_packet :: proc(socket: net.UDP_Socket, remote: net.Endpoint, packet: sh.Packet) {
    bytes, _ := cbor.marshal_into_bytes(packet)
    defer delete(bytes)
    bytes_sent, send_err := net.send_udp(socket, bytes, remote) 
    if send_err != nil {
        fmt.eprintfln("Problem sending packet: %v", send_err)
    }
    return
}

read_response :: proc(socket: net.UDP_Socket) -> (sh.Response, net.Endpoint, bool) {
    bytes_read, endpoint, read_err := net.recv_udp(socket, buf[:])
    if read_err != nil {
        fmt.eprintln(net.last_platform_error_string()) 
        os2.exit(1)
    }

    // non blocking case
    if bytes_read <= 0 {
        return {}, {}, false
    }

    response: sh.Response
    cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &response)
    return response, endpoint, true
}

send_response:: proc(socket: net.UDP_Socket, remote: net.Endpoint, response: sh.Response) {
    bytes, _ := cbor.marshal_into_bytes(response) 
    defer delete(bytes)
    bytes_sent, send_err := net.send_udp(socket, bytes, remote) 
    if send_err != nil {
        fmt.eprintfln("Problem sending packet: %v", send_err)
    }
    return
}

expect_response :: proc(client: net.UDP_Socket, $T: typeid) -> (T, bool) where intrinsics.type_is_variant_of(sh.Response, T) {
    bytes_read, _, read_err := net.recv_udp(client, buf[:])
    if read_err != nil {
        fmt.eprintln(net.last_platform_error_string()) 
        os2.exit(1)
    }

    // non-blocking case
    if bytes_read <= 0 {
        return {}, false
    }

    response: sh.Response
    cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &response)
    data, ok := response.(T)
    if !ok {
        last_error_string = response.(sh.Error)
        return {}, false
    }
    return data, true
}

create_lobby :: proc(client: net.UDP_Socket, server_endpoint, bound_endpoint: net.Endpoint, lobby_id: i64, lobby_name: string, host_name: string) -> (lobby_data: Lobby_Data, ok: bool) {
    packet := sh.Packet(sh.Create_Lobby_Packet{lobby_id, lobby_name, host_name, bound_endpoint})
    send_packet(client, server_endpoint, packet)
    cl_response := expect_response(client, sh.Create_Response) or_return
    return {.Host, lobby_id, cl_response.assigned_id, lobby_name, host_name, host_name}, true
}

join_lobby :: proc(client: net.UDP_Socket, server_endpoint, bound_endpoint: net.Endpoint, lobby_id: i64, join_name: string) -> (lobby_data: Lobby_Data, ok: bool) {
    packet := sh.Packet(sh.Join_Lobby_Packet{lobby_id, join_name, bound_endpoint})
    send_packet(client, server_endpoint, packet)
    jl_response := expect_response(client, sh.Join_Lobby_Response) or_return
    return {.Join, lobby_id, jl_response.assigned_id, jl_response.lobby_name, join_name, jl_response.host_name}, true
}

init_start_lobby :: proc(client: net.UDP_Socket, server_endpoint: net.Endpoint, lobby_data: Lobby_Data) {
    packet := sh.Packet(sh.Start_Lobby_Packet{lobby_id = lobby_data.lobby_id, host_id = lobby_data.assigned_id})
    send_packet(client, server_endpoint, packet)
}


play_game :: proc(s: ^State) {
    gp.start_network(&s.network)
    defer gp.close_network(&s.network)

    last_tick := time.tick_now()
    accum := time.Duration(0)
    game_time := rl.GetTime()

    rl.InitWindow(WIDTH, HEIGHT, "Game")
    rl.SetTargetFPS(60)

    background := rl.LoadTexture("./map.png")
    character := rl.LoadTexture("./Spritesheet.png")
    characterAttack := rl.LoadTexture("./actions.png")
    fenceT := rl.LoadTexture("./Fences.png")
    camera.zoom = f32(WIDTH) / CANVAS_SIZE

    other_players := [4]gp.Player_Move{}

    for i in 0 ..= 3 {
        if i64(i) == s.lobby.assigned_id {
            continue
        }
        if i == 0 {
            other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{80, 77, 60, 60}, {255, 255, 255, 255}, 0, false, false, 0}
        } else if i == 1 {
            other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{967, 77, 60, 60}, {196, 238, 255, 255}, 1, false, false, 0}
        } else if i == 2 {
            other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{80, 467, 60, 60}, {255, 196, 227, 255}, 2,false, false, 0}
        } else if i == 3 {
            other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{967, 467, 60, 60}, {255, 236, 196, 255}, 3, false, false, 0}
        }
    }

    switch s.lobby.assigned_id {
        case 0:
            player.pos = {80, 77}
            player.color = {255, 255, 255, 255}
        case 1:
            player.pos = {967, 77}
            player.color = {196, 238, 255, 255}
        case 2:
            player.pos = {80, 467}
            player.color = {255, 196, 227, 255}
        case 3:
            player.pos = {967, 467}
            player.color = {255, 236, 196, 255}
    }

    for !rl.WindowShouldClose() {

        time_now := time.tick_now()
        dt := time.tick_diff(last_tick, time_now)
        last_tick = time_now
        accum += dt
        curr := rl.GetTime()
        game_dt := game_time - rl.GetTime()
        game_time = curr


        should_snap, snap_ready := gp.poll_for_packets(&s.network) 

        if should_snap || snap_ready {
        } 

        if (accum > time.Second / 60) {
            accum = 0
            messages := gp.get_messages(&s.network)
            defer gp.cleanup_messages(&s.network)

            for m in messages {
                #partial switch v in m {
                    case struct{}:
                        // do nothign
                    case int:
                        fmt.println(v)
                    case gp.Player_Move:
                        other_players[v.id] = v
                    case gp.Placed_Fence:
                        if v.id[0] != int(s.lobby.assigned_id) {
                            append(&fences, Fence{v.src, v.dest, 20, {v.id[0], v.id[1]}})
                        }
                    case gp.Attack_Fence:
                        i := 0
                        for &fence in fences {
                            if fence.id == v.id {
                                if v.destroyed {
                                    unordered_remove(&fences, i)
                                    break
                                }
                                fence.health = v.health
                            }
                            i += 1
                        }
                    }
                    
                }
            }

        player.moved = false
        move_player(game_dt)
        player.dest = rl.Rectangle{player.pos[0], player.pos[1], 60, 60}
        camera.target = {player.pos[0] - CANVAS_SIZE/2 - 40, player.pos[1] - 120}

        rl.BeginDrawing()

        rl.BeginMode2D(camera)
        rl.ClearBackground({155, 212, 195, 255}) 
        rl.DrawTexture(background, 1, 1, {255, 255, 255, 255})

        // draw health bar
        rl.DrawText(rl.TextFormat("%i/100", player.health), i32(player.pos.x - 195), i32(player.pos.y - 115), 12, rl.RED);

        for fence in fences {
            rl.DrawTexturePro(fenceT, fence.src, fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        }

        for other_player in other_players {
            if other_player.id == s.lobby.assigned_id {
                continue
            }
            if other_player.attacking {
                rl.DrawTexturePro(characterAttack, other_player.src, other_player.dest, {other_player.dest.width, other_player.dest.height}, 0, other_player.color)
            } else if other_player.placing_fence {
                player_with_fence(other_player, character, fenceT, &current_fence)
            } else {
                rl.DrawTexturePro(character, other_player.src, other_player.dest, {other_player.dest.width, other_player.dest.height}, 0, other_player.color)
            }
        }

        if player.attacking {
            rl.DrawTexturePro(characterAttack, player.attacking_src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
            i := 0
            for &fence in fences {
                if player.pos[0] < fence.dest.x && player.pos[0] > fence.dest.x - 40 && player.pos[1] < fence.dest.y && player.pos[1] > fence.dest.y - 50 {
                    fence.health -= int(1)
                    attack_fence := gp.Attack_Fence{fence.id, fence.health, false}
                    if fence.health <= 0 {
                        unordered_remove(&fences, i)
                        attack_fence.destroyed = true
                        fmt.println("FENCE DESTROYED 1")
                    }
                    ok := gp.broadcast_message(&s.network, gp.Message(attack_fence))
                    if !ok {
                        fmt.println("UH OH")
                    }
                    break
                }
                i += 1
            }
        } else if player.placing_fence {
            player_with_fence(gp.Player_Move{player.src, player.dest, player.color, s.lobby.assigned_id, false, false, player.direction}, character, fenceT, &current_fence)
        } else {
            rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
        }

        player_move := gp.Player_Move{player.src, player.dest, player.color, s.lobby.assigned_id, player.attacking, player.placing_fence, player.direction}
        if player.attacking {
            player_move.src = player.attacking_src
        }

        if(player.moved || player.placing_fence || player.attacking || player.attack_done) {
            ok := gp.broadcast_message(&s.network, gp.Message(player_move))
            if !ok {
                fmt.println("UH OH")
            }
        } 

        if player.place_fence {
            index := len(fences) - 1
            append(&fences, Fence{current_fence.src, current_fence.dest, 20, {int(s.lobby.assigned_id), index}})
            player.place_fence = false
            last_fence_dest = current_fence.dest
            placed_fence := gp.Placed_Fence{current_fence.src, current_fence.dest, {int(s.lobby.assigned_id), index}}
            ok := gp.broadcast_message(&s.network, gp.Message(placed_fence))
            if !ok {
                fmt.println("UH OH")
            }
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

// Game Logic

player_with_fence :: proc(player: gp.Player_Move, character: rl.Texture2D, fenceT: rl.Texture2D, current_fence: ^Fence) {
    if player.direction == 0 {
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
        current_fence.dest = rl.Rectangle{player.dest.x + 20, player.dest.y + 25, 20, 20}
        rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
    } else if player.direction == 1 {
        current_fence.dest = rl.Rectangle{player.dest.x + 20, player.dest.y + 15, 20, 20}
        rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
    } else if player.direction == 2 {
        current_fence.dest = rl.Rectangle{player.dest.x + 15, player.dest.y + 20, 20, 20}
        rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
    } else if player.direction == 3 {
        current_fence.dest = rl.Rectangle{player.dest.x + 25, player.dest.y + 20, 20, 20}
        rl.DrawTexturePro(fenceT, current_fence.src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
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
            player.moved = true
        }
    }
    if rl.IsKeyDown(.D) {
        if player.pos[0] < 1047 {
            player.moving = true
            player.player_right = true
            player.direction = 3
            player.moved = true
        }
    } 
    if rl.IsKeyDown(.S) {
        if player.pos[1] < 560 {
            player.moving = true
            player.player_down = true
            player.direction = 0
            player.moved = true
        }
    }
    if rl.IsKeyDown(.W) {
        if player.pos[1] > 66 {
            player.moving = true
            player.player_up = true
            player.direction = 1
            player.moved = true
        }
    }
    if rl.IsKeyDown(.E) {
        player.attack_done = false
        player.attacking = true
        player.attacking_src.y = (4 * player.attacking_src.height) + (f32(player.direction) * player.attacking_src.height)
    } else if  rl.IsKeyReleased(.E) {
        player.attack_done = true
    }
    else {
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
        next_pos := player.pos + (dir_norm * grid_speed(player.speed) * f32(dt))
        
        for fence in fences {
            if fence.dest != last_fence_dest && next_pos[0] < fence.dest.x + - 10 && next_pos[0] > fence.dest.x - 30 && next_pos[1] < fence.dest.y - 10 && next_pos[1] > fence.dest.y - 40 {
                next_pos = player.pos
                break
            }
        }

        player.pos = next_pos
    }
    
    player.facing = dir
    
    if player.player_frame > 3 {
        player.player_frame = 0
    }
}



