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


Host_Data :: struct {
    lobby_id: i64,
    assigned_id: i64,
    lobby_name: string,
    host_name: string,
}

Role :: enum {
    Host,
    Join,
}

Options :: struct {
    port: int `args:"pos=0,requied" usage:"Client Port"`,
    lobby_id: i64 `args:"pos=1,required" usage:"Lobby ID"`,
    role: Role `args:"pos=2,required" usage:"Role"`,
}

buf: [1024]byte
last_error_string := ""

_main :: proc() {

    opt: Options
    style := flags.Parsing_Style.Odin
    flags.parse_or_exit(&opt, os2.args, style)

    endpoint := net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = 1111}
    client, make_err := net.make_bound_udp_socket(net.IP4_Address{127,0,0,1}, opt.port)
    if make_err != nil {
        fmt.eprintln(net.last_platform_error_string())
        os2.exit(1)
    }
    defer net.close(client)

    if opt.role == .Host {
        host_data, create_ok := create_lobby(client, endpoint, opt.lobby_id, "My Lobby", "Anthony Albanese")

        if !create_ok {
            fmt.eprintln(last_error_string)
            os2.exit(1)
        } 
        fmt.println(host_data)

        start_ok := start_lobby(client, endpoint, host_data)
        if !start_ok {
            fmt.eprintln(last_error_string)
            os2.exit(1)
        }
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

expect_response :: proc(client: net.UDP_Socket, $T: typeid) -> (T, bool) where intrinsics.type_is_variant_of(sh.Response, T) {
    bytes_read, _, read_err := net.recv_udp(client, buf[:])
    if read_err != nil {
        fmt.eprintln(net.last_platform_error_string()) 
        os2.exit(1)
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

create_lobby :: proc(client: net.UDP_Socket, server_endpoint: net.Endpoint, lobby_id: i64, lobby_name: string, host_name: string) -> (host_data: Host_Data, ok: bool) {
    packet := sh.Packet(sh.Create_Lobby_Packet{lobby_id, lobby_name, host_name})
    send_packet(client, server_endpoint, packet)
    cl_response := expect_response(client, sh.Create_Response) or_return
    return {lobby_id, cl_response.assigned_id, lobby_name, host_name}, true
}

start_lobby :: proc(client: net.UDP_Socket, server_endpoint: net.Endpoint, host_data: Host_Data) -> bool {
    packet := sh.Packet(sh.Start_Lobby_Packet{lobby_id = host_data.lobby_id, assigned_id = host_data.assigned_id})
    send_packet(client, server_endpoint, packet)
    st_response := expect_response(client, sh.Start_Lobby_Response) or_return
    return true
}

