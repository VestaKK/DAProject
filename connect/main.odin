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
            lobby_data, create_ok := create_lobby(client, server_endpoint, opt.lobby_id, "My Lobby", "Anthony Albanese")
            if !create_ok {
                fmt.eprintln(last_error_string)
                os2.exit(1)
            } 
            state.lobby = lobby_data

            rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
            host_scene(&state, client, server_endpoint)

        case .Join:
            lobby_data, join_ok := join_lobby(client, server_endpoint, opt.lobby_id, "Tony Abbott")
            if !join_ok {
                fmt.eprintln(last_error_string)
                os2.exit(1)
            }
            state.lobby = lobby_data

            rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
            join_scene(&state, client, server_endpoint)
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
        //state.this_net_id, _  = gp.init_network(&state.network, socket, response.host.endpoint)
        //for peer_profile in response.players {
        //    gp.add_connection(&state.network, peer_profile.endpoint)
        //}
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
        fmt.println(response.host)
        for peer in response.players {
            fmt.println(peer)
        }
        //gp.init_network(&state.network, socket, response.host.endpoint)
        //for peer_profile in response.players {
        //  net_id, _ := gp.add_connection(&state.network, peer_profile.endpoint)
        //    if peer_profile.assigned_id == state.lobby.assigned_id {
        //        state.this_net_id = net_id
        //    }
        //}
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

create_lobby :: proc(client: net.UDP_Socket, server_endpoint: net.Endpoint, lobby_id: i64, lobby_name: string, host_name: string) -> (lobby_data: Lobby_Data, ok: bool) {
    packet := sh.Packet(sh.Create_Lobby_Packet{lobby_id, lobby_name, host_name})
    send_packet(client, server_endpoint, packet)
    cl_response := expect_response(client, sh.Create_Response) or_return
    return {.Host, lobby_id, cl_response.assigned_id, lobby_name, host_name, host_name}, true
}

join_lobby :: proc(client: net.UDP_Socket, server_endpoint: net.Endpoint, lobby_id: i64, join_name: string) -> (lobby_data: Lobby_Data, ok: bool) {
    packet := sh.Packet(sh.Join_Lobby_Packet{lobby_id, join_name})
    send_packet(client, server_endpoint, packet)
    jl_response := expect_response(client, sh.Join_Lobby_Response) or_return
    return {.Join, lobby_id, jl_response.assigned_id, jl_response.lobby_name, join_name, jl_response.host_name}, true
}

init_start_lobby :: proc(client: net.UDP_Socket, server_endpoint: net.Endpoint, lobby_data: Lobby_Data) {
    packet := sh.Packet(sh.Start_Lobby_Packet{lobby_id = lobby_data.lobby_id, host_id = lobby_data.assigned_id})
    send_packet(client, server_endpoint, packet)
}
