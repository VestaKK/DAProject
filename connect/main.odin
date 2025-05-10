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
import "core:slice"

Options :: struct {
    port: int `args:"pos=0,requied" usage:"Client Port"`,
    lobby_id: i64 `args:"pos=1,required" usage:"Lobby ID"`,
    role: Role `args:"pos=2,required" usage:"Role"`,
    file_name: string `args:"pos=3", usage:Save File`,
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
    load_required: bool,
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
    save_bytes: []byte,

    window: struct {
        width, height: int
    },
        
    network: gp.Network,
    this_net_id: int,
}

Game_State :: struct {
    fences: []gp.Fence,
    player: Player
}

// Game Structs
Player :: struct {
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
    attack_done: bool,
    quadrant: [dynamic][4]f32
}

// Game State intialization
WIDTH :: 1000
HEIGHT :: 500 
GRID_WIDTH :: 20
CELL_SIZE :: 16
CANVAS_SIZE :: GRID_WIDTH * CELL_SIZE

QUANDRANT_ONE :: [4]f32{66, 66, 567, 293}
QUANDRANT_TWO :: [4]f32{567, 66, 1047, 293}
QUANDRANT_THREE :: [4]f32{66, 293, 567, 560}
QUANDRANT_FOUR :: [4]f32{567, 293, 1047, 560}

camera := rl.Camera2D{}

player := Player{}

framecount := 0

fences: [dynamic]gp.Fence

game_state := Game_State{
    fences = fences[:],
    player = player
}

current_fence := gp.Fence{
    dest = rl.Rectangle{0, 0, 20, 20}
}

last_fence_dest := rl.Rectangle{}
fence_src := rl.Rectangle{0, 48, 16, 16}

// Response scratch buffer
buf: [1024]byte

// Some error thing idk its a placeholder
last_error_string := ""

_main :: proc() {

    // Game State
    WINDOW_TITLE :: "Distributed Algorithms Project"
    WINDOW_HEIGHT :: 500
    WINDOW_WIDTH :: 1000
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

            // Load file if it exists
            load_save := false
            if opt.file_name != "" {
                save_bytes, err := os2.read_entire_file_from_path(opt.file_name, context.allocator) 
                if err != nil {
                    fmt.eprintln("Something happened whilst trying to open file")
                    fmt.eprintln(os2.error_string(err))
                    os2.exit(1)
                }
                state.save_bytes = save_bytes
            }
        
            lobby_data, create_ok := create_lobby(client, server_endpoint, bound_endpoint, opt.lobby_id, "My Lobby", "Anthony Albanese", state.save_bytes != nil)
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

    if opt.role == .Join {
        delete(state.lobby.lobby_name)
        delete(state.lobby.host_name)
    }

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
        delete(response.host.user_name)
        for peer_profile in response.players {
            gp.add_connection(&state.network, peer_profile.endpoint)
            delete(peer_profile.user_name)
        }
    }

    for !rl.WindowShouldClose() {
        bytes_read, endpoint, err := net.recv_udp(socket, buf[:])
        if bytes_read > 0 && endpoint == server_endpoint { 
            response: sh.Response
            cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &response)
            start_lobby_response := &response.(sh.Start_Lobby_Response)
            setup_connections(state, socket, start_lobby_response^)
            delete(start_lobby_response.players)
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
        delete(response.host.user_name)
        for peer_profile in response.players {
            if peer_profile.assigned_id == state.lobby.assigned_id {
                gp.add_connection(&state.network, peer_profile.endpoint, true)
            } else {
                gp.add_connection(&state.network, peer_profile.endpoint)
            }
            delete(peer_profile.user_name)
        }
    }

    for !rl.WindowShouldClose() {
        bytes_read, endpoint, err := net.recv_udp(socket, buf[:])
        if bytes_read > 0 && endpoint == server_endpoint { 
            response: sh.Response
            cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &response)
            start_lobby_response := &response.(sh.Start_Lobby_Response)
            setup_connections(state, socket, start_lobby_response^)
            delete(start_lobby_response.players)
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

create_lobby :: proc(client: net.UDP_Socket, server_endpoint, bound_endpoint: net.Endpoint, lobby_id: i64, lobby_name: string, host_name: string, load_required: bool) -> (lobby_data: Lobby_Data, ok: bool) {
    packet := sh.Packet(sh.Create_Lobby_Packet{lobby_id, lobby_name, host_name, bound_endpoint, load_required})
    send_packet(client, server_endpoint, packet)
    cl_response := expect_response(client, sh.Create_Response) or_return
    return {.Host, lobby_id, cl_response.assigned_id, lobby_name, host_name, host_name, load_required}, true
}

join_lobby :: proc(client: net.UDP_Socket, server_endpoint, bound_endpoint: net.Endpoint, lobby_id: i64, join_name: string) -> (lobby_data: Lobby_Data, ok: bool) {
    packet := sh.Packet(sh.Join_Lobby_Packet{lobby_id, join_name, bound_endpoint})
    send_packet(client, server_endpoint, packet)
    jl_response := expect_response(client, sh.Join_Lobby_Response) or_return
    return {.Join, lobby_id, jl_response.assigned_id, jl_response.lobby_name, join_name, jl_response.host_name, jl_response.load_required}, true
}

init_start_lobby :: proc(client: net.UDP_Socket, server_endpoint: net.Endpoint, lobby_data: Lobby_Data) {
    packet := sh.Packet(sh.Start_Lobby_Packet{lobby_id = lobby_data.lobby_id, host_id = lobby_data.assigned_id})
    send_packet(client, server_endpoint, packet)
}

send_game_message :: proc(s: ^State, message: gp.Message, destination: int) {
    ok := gp.send_message(&s.network, message, destination)
    if !ok { fmt.println("[error] Failed to send message: %v to destination: %v", message, destination) }
}

broadcast_game_message :: proc(s: ^State, message: gp.Message) {
    ok := gp.broadcast_message(&s.network, message)
    if !ok { fmt.println("[error] Failed to broadcast message: %v", message) }
}

DummyState :: struct {
    counter: int,
}

state: DummyState
snapshot: DummyState

play_game :: proc(s: ^State) {

    messages: []gp.Message
    cbor_err: cbor.Unmarshal_Error
    if s.lobby.load_required {

        // Load Data and do stuff
        if gp.this_is_host(s.network) {
            messages, cbor_err = gp.load_network(&s.network, &state, s.save_bytes)
        } else {
            messages, cbor_err = gp.wait_for_load_save(&s.network, &state)
        }

        for message in messages {
            // do things
        }

        gp.cleanup_loaded_messages(&s.network, messages)
    } else {
        gp.start_network(&s.network)
    }

    defer gp.close_network(&s.network)

    last_tick := time.tick_now()
    accum := time.Duration(0)
    game_time := rl.GetTime()

    rl.SetTargetFPS(60)

    background := rl.LoadTexture("./map.png")
    character := rl.LoadTexture("./Spritesheet.png")
    characterAttack := rl.LoadTexture("./actions.png")
    fenceT := rl.LoadTexture("./Fences.png")
    camera.zoom = f32(WIDTH) / CANVAS_SIZE

    initialise_player(i64(s.network.this_id), s)
    other_players := initialise_other_players(i64(s.network.this_id))

    quadrant_fences := []gp.Fence{}
    quadrant_fences = {}
    fence_update := false
    prev_quad := s.network.this_id

    broadcast_game_message(s, gp.Message(gp.Player_Start{i64(s.network.this_id)}))

    for !rl.WindowShouldClose() {

        time_now := time.tick_now()
        dt := time.tick_diff(last_tick, time_now)
        last_tick = time_now
        accum += dt
        curr := rl.GetTime()
        game_dt := game_time - rl.GetTime()
        game_time = curr

        gp.poll_for_packets(&s.network)         

        if (accum > time.Second / 60) {
            accum = 0
            messages := gp.get_messages(&s.network)
            defer gp.cleanup_messages(&s.network)

            for m in messages {
                #partial switch v in m {
                    case gp.Player_Start:
                        other_players[v.id].health = 100
                    case gp.Player_Move:
                        other_players[v.id] = v
                    case gp.Placed_Fence:
                        if v.id[0] != int(s.network.this_id) {
                            append(&fences, gp.Fence{v.dest, 20, {v.id[0], len(fences)}})
                            fence_update = true
                        }
                    case gp.Attack_Fence:
                        i := 0
                        for &fence in fences {
                            if fence.id == v.id {
                                fence_update = true
                                if v.destroyed {
                                    unordered_remove(&fences, i)
                                    break
                                }
                                fence.health = v.health
                            }
                            i += 1
                        }
                    case gp.Attack_Player:
                        if v.id == i64(s.network.this_id) {
                            player.health -= 1
                            if player.health <= 0 {
                                player.health = 0
                                player.color = rl.RED
                                broadcast_game_message(s, gp.Message(gp.Dead_Player{i64(s.network.this_id)}))
                            }
                        } 
                    case gp.Dead_Player:
                        other_players[v.id].health = 0
                        other_players[v.id].color = rl.RED
                    case gp.Send_Fences:
                        quadrant_fences = v.fences
                    case gp.Request_Fences:
                        send_fences := gp.Send_Fences{fences[:]}
                        send_game_message(s, gp.Message(send_fences), int(v.id))
                }
                    
            }
        }

        player.moved = false

        // send fences to relevant players
        if fence_update {
            for i in 0 ..= s.network.channels.len - 1 {
                if other_players[i].id != i64(s.network.this_id) {
                    quadrant := check_quadrant_owner({other_players[i].dest.x, other_players[i].dest.y}, s)
                    if quadrant == int(s.network.this_id) {
                        send_fences := gp.Send_Fences{fences[:]}
                        send_game_message(s, gp.Message(send_fences), int(other_players[i].id))
                    }
                }
            }
            fence_update = false
        }

        // check if player is in a different quadrant, request fences if so
        quadrant_owner := check_quadrant_owner(player.pos, s)
        if quadrant_owner != int(prev_quad) && quadrant_owner != int(s.network.this_id) {
            request_fences := gp.Request_Fences{i64(s.network.this_id)}
            send_game_message(s, gp.Message(request_fences), quadrant_owner)
            prev_quad = i8(quadrant_owner)
        }

        // if the player is alive, check movement
        if player.health > 0 {
            move_player(game_dt, s, quadrant_owner, quadrant_fences)
            camera.target = {player.pos[0] - CANVAS_SIZE/2 - 40, player.pos[1] - 120}
        }

        // Check if any other players are alive
        all_dead := true
        for other_player in other_players {
            if other_player.id != i64(s.network.this_id) && other_player.health > 0 {
                all_dead = false
            }
        }

        rl.BeginDrawing()
        rl.BeginMode2D(camera)
        rl.ClearBackground({155, 212, 195, 255}) 
        rl.DrawTexture(background, 1, 1, {255, 255, 255, 255})

        // If player is dead, draw message
        if player.health <= 0 {
            rl.DrawText("You have died", i32(player.pos.x - 100), i32(player.pos.y - 50), 20, {0, 0, 0, 255})
        }

        if all_dead {
            rl.DrawText("Winner", i32(player.pos.x - 100), i32(player.pos.y - 50), 20, {0, 0, 0, 255})
        }

        // draw health bar
        rl.DrawText(rl.TextFormat("%i/100", player.health), i32(player.pos.x - 195), i32(player.pos.y - 115), 12, rl.RED);

        // draw fences for own quadrant and quadrant currently in
        draw_fences(fences[:], fenceT)
        draw_fences(quadrant_fences, fenceT)

        // draw all other players, except this player
        for i in 0 ..= s.network.channels.len - 1 {
            if other_players[i].id != i64(s.network.this_id) {
                if other_players[i].attacking {
                    rl.DrawTexturePro(characterAttack, other_players[i].src, other_players[i].dest, {other_players[i].dest.width, other_players[i].dest.height}, 0, other_players[i].color)
                } else if other_players[i].placing_fence {
                    player_with_fence(other_players[i], character, fenceT, &current_fence)
                } else {
                    rl.DrawTexturePro(character, other_players[i].src, other_players[i].dest, {other_players[i].dest.width, other_players[i].dest.height}, 0, other_players[i].color)
                }
            }
        }

        // draw this player
        if player.attacking {
            rl.DrawTexturePro(characterAttack, player.attacking_src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)

            // check fence hits
            if quadrant_owner == int(s.network.this_id) {
                i := handle_fence_hit(fences[:])
                if i != -1 {
                    fence_update = true
                    if fences[i].health <= 0 {
                        unordered_remove(&fences, i)
                    }
                }
            } else {
                i := handle_fence_hit(quadrant_fences)
                if i != -1 {
                    attack_fence := gp.Attack_Fence{quadrant_fences[i].id, quadrant_fences[i].health, false}
                    if quadrant_fences[i].health <= 0 {
                        attack_fence.destroyed = true
                    }
                    send_game_message(s, gp.Message(attack_fence), quadrant_owner)
                }
            }

            // check player hits
            for &other_player in other_players {
                if other_player.id != i64(s.network.this_id) {
                    if player.pos[0] < other_player.dest.x + 20 && player.pos[0] > other_player.dest.x - 20 && player.pos[1] < other_player.dest.y + 20 && player.pos[1] > other_player.dest.y - 20{
                        other_player.health -= 1
                        attack_player := gp.Attack_Player{other_player.id}
                        broadcast_game_message(s, gp.Message(attack_player))
                        break
                    }
                }
            }
        } else if player.placing_fence {
            player_with_fence(gp.Player_Move{player.src, player.dest, player.color, i64(s.network.this_id), false, false, player.direction, player.health}, character, fenceT, &current_fence)
        } else {
            rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
        }

        // check if a player has placed a fence
        if player.place_fence {
            index := len(fences) - 1
            player.place_fence = false
            last_fence_dest = current_fence.dest
            if quadrant_owner != int(i64(s.network.this_id)) {
                placed_fence := gp.Placed_Fence{current_fence.dest, {int(i64(s.network.this_id)), index}}
                send_game_message(s, gp.Message(placed_fence), quadrant_owner)
            } else {
                append(&fences, gp.Fence{current_fence.dest, 20, {int(i64(s.network.this_id)), index}})
                fence_update = true
            }
        }

        // create message to send to other players
        player_move := gp.Player_Move{player.src, player.dest, player.color, i64(s.network.this_id), player.attacking, player.placing_fence, player.direction, player.health}
        if player.attacking {
            player_move.src = player.attacking_src
        }
        if(player.moved || player.placing_fence || player.attacking || player.attack_done) {
            broadcast_game_message(s, gp.Message(player_move))
        } 

        rl.EndDrawing()

        player.moving = false
        player.player_up, player.player_down, player.player_left, player.player_right = false, false, false, false

        framecount += 1
    }

    save_game_state()
    fmt.println(game_state)

    // clean up
    rl.UnloadTexture(fenceT)
    rl.UnloadTexture(background)
    rl.UnloadTexture(character)
    rl.UnloadTexture(characterAttack)
    delete(fences)
    delete(player.quadrant)

}

// Game Logic

save_game_state :: proc() {
    game_state.fences = slice.clone(fences[:])
    game_state.player = player
}

player_with_fence :: proc(player: gp.Player_Move, character: rl.Texture2D, fenceT: rl.Texture2D, current_fence: ^gp.Fence) {
    if player.direction == 0 {
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
        current_fence.dest = rl.Rectangle{player.dest.x + 20, player.dest.y + 25, 20, 20}
        rl.DrawTexturePro(fenceT, fence_src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
    } else if player.direction == 1 {
        current_fence.dest = rl.Rectangle{player.dest.x + 20, player.dest.y + 15, 20, 20}
        rl.DrawTexturePro(fenceT, fence_src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
    } else if player.direction == 2 {
        current_fence.dest = rl.Rectangle{player.dest.x + 15, player.dest.y + 20, 20, 20}
        rl.DrawTexturePro(fenceT, fence_src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
        rl.DrawTexturePro(character, player.src, player.dest, {player.dest.width, player.dest.height}, 0, player.color)
    } else if player.direction == 3 {
        current_fence.dest = rl.Rectangle{player.dest.x + 25, player.dest.y + 20, 20, 20}
        rl.DrawTexturePro(fenceT, fence_src, current_fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
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

move_player :: proc(dt: f64, s: ^State, quadrant_owner: int, quadrant_fences: []gp.Fence) {
    
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
        
        hit := false
        if quadrant_owner == int(s.network.this_id) {
            hit = check_fence_collision(fences[:], next_pos)
        } else {
            hit = check_fence_collision(quadrant_fences, next_pos)
        }
        if hit { next_pos = player.pos }
        player.pos = next_pos
    }
    
    player.facing = dir
    
    if player.player_frame > 3 {
        player.player_frame = 0
    }

    player.dest = rl.Rectangle{player.pos[0], player.pos[1], 60, 60}
}

check_fence_collision :: proc(fences: []gp.Fence, next_pos: [2]f32) -> bool {
    for fence in fences {
        if fence.dest != last_fence_dest && next_pos[0] < fence.dest.x + - 10 && next_pos[0] > fence.dest.x - 30 && next_pos[1] < fence.dest.y - 10 && next_pos[1] > fence.dest.y - 40 {
            return true
        }
    }
    return false
}

check_quadrant_owner :: proc(pos: [2]f32, s: ^State) -> int {
    switch s.network.channels.len {
        case 2:
            if (pos[0] > QUANDRANT_ONE[0] && pos[0] < QUANDRANT_ONE[2] && pos[1] > QUANDRANT_ONE[1] && pos[1] < QUANDRANT_ONE[3]) ||
                (pos[0] > QUANDRANT_THREE[0] && pos[0] < QUANDRANT_THREE[2] && pos[1] > QUANDRANT_THREE[1] && pos[1] < QUANDRANT_THREE[3]) {
                return 0
            } else {
                return 1
            }
        case 3:
            if (pos[0] > QUANDRANT_ONE[0] && pos[0] < QUANDRANT_ONE[2] && pos[1] > QUANDRANT_ONE[1] && pos[1] < QUANDRANT_ONE[3]) {
                return 0
            } else if (pos[0] > QUANDRANT_TWO[0] && pos[0] < QUANDRANT_TWO[2] && pos[1] > QUANDRANT_TWO[1] && pos[1] < QUANDRANT_TWO[3]) {
                return 1
            } else {
                return 2
            }
        case 4:
            if (pos[0] > QUANDRANT_ONE[0] && pos[0] < QUANDRANT_ONE[2] && pos[1] > QUANDRANT_ONE[1] && pos[1] < QUANDRANT_ONE[3]) {
                return 0
            } else if (pos[0] > QUANDRANT_TWO[0] && pos[0] < QUANDRANT_TWO[2] && pos[1] > QUANDRANT_TWO[1] && pos[1] < QUANDRANT_TWO[3]) {
                return 1
            } else if (pos[0] > QUANDRANT_THREE[0] && pos[0] < QUANDRANT_THREE[2] && pos[1] > QUANDRANT_THREE[1] && pos[1] < QUANDRANT_THREE[3]) {
                return 2
            } else {
                return 3
            }
    }
    return -1
}

initialise_other_players :: proc(id: i64) -> [4]gp.Player_Move {
    other_players := [4]gp.Player_Move{}
    for i in 0 ..= 3 {
        if i64(i) != i64(id) {
            if i == 0 {
                other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{80, 77, 60, 60}, {255, 255, 255, 255}, 0, false, false, 0, 0}
            } else if i == 1 {
                other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{967, 77, 60, 60}, {196, 238, 255, 255}, 1, false, false, 0, 0}
            } else if i == 2 {
                other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{80, 467, 60, 60}, {255, 196, 227, 255}, 2,false, false, 0, 0}
            } else if i == 3 {
                other_players[i] = gp.Player_Move{rl.Rectangle{0, 0, 48, 48}, rl.Rectangle{967, 467, 60, 60}, {255, 236, 196, 255}, 3, false, false, 0, 0}
            }
        }
    }
    return other_players
}

initialise_player :: proc(id: i64, s: ^State) {
    player.speed = 7
    player.src = rl.Rectangle{0, 0, 48, 48}
    player.attacking_src = rl.Rectangle{5, 0, 48, 48}
    player.moving = false
    player.player_up = false
    player.player_down = false 
    player.player_left = false 
    player.player_right = false
    player.player_frame = 0
    player.attacking = false
    player.place_fence = false
    player.placing_fence = false
    player.health = 100
    player.moved = false
    player.attack_done = false

    switch id {
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

    // setup quadrant ownership
    if s.network.channels.len == 2 {
        if id == 0 {
            append(&player.quadrant, QUANDRANT_ONE, QUANDRANT_THREE)
        } else {
            append(&player.quadrant, QUANDRANT_TWO, QUANDRANT_FOUR)
        }
    } else if s.network.channels.len == 3 {
        if id == 0 {
            append(&player.quadrant, QUANDRANT_ONE)
        } else if id == 1 {
            append(&player.quadrant, QUANDRANT_TWO)
        } else if id == 2 {
            append(&player.quadrant, QUANDRANT_THREE, QUANDRANT_FOUR)
        }
    } else if s.network.channels.len == 4 {
        if id == 0 {
            append(&player.quadrant, QUANDRANT_ONE)
        } else if id == 1 {
            append(&player.quadrant, QUANDRANT_TWO)
        } else if id == 2 {
            append(&player.quadrant, QUANDRANT_THREE)
        } else if id == 3 {
            append(&player.quadrant, QUANDRANT_FOUR)
        }
    }
}

draw_fences :: proc(fences: []gp.Fence, fenceT: rl.Texture2D) {
    for fence in fences {
        rl.DrawTexturePro(fenceT, fence_src, fence.dest, {player.dest.width, player.dest.height}, 0, rl.WHITE)
    }
}

handle_fence_hit :: proc(fences: []gp.Fence) -> int{
    i := 0
    for &fence in fences {
        if player.pos[0] < fence.dest.x && player.pos[0] > fence.dest.x - 40 && player.pos[1] < fence.dest.y && player.pos[1] > fence.dest.y - 50 {
            fence.health -= int(1)
            break
        }
        i += 1
    }
    if i == len(fences) {
        return -1
    } else {
        return i
    }
}


