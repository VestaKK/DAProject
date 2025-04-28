package main

import "core:fmt"
import "core:net"
import "core:os/os2"
import "core:encoding/cbor"
import sh "../shared"
import "core:mem"
import "core:thread"


Lobby :: struct {
    joined_count: i64,
    id_counter: i64,
    lobby_name: string,
    host_name: string,
    host_profile: sh.Private_Profile, 
    joined: [sh.MAX_PLAYER_COUNT - 1]sh.Private_Profile,
}

lobbies: map[i64]^Lobby
buf: [1024]byte

main :: proc() { 

    // Get IP DHCP IPv4 address for this device
    // We just choose the first one since it's unlikely for
    // a single machine to have more than 2 IP addresses linked to the device
    interfaces, _ := net.enumerate_interfaces()
    bound_address := net.Address{}
    loop: for interface in interfaces{
        if _, ok := interface.dhcp_v4.(net.IP4_Address); ok {
            for lease in interface.unicast {
                switch address in lease.address {
                    case net.IP4_Address:
                        bound_address = address
                        break loop
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
    net.destroy_interfaces(interfaces)

    fmt.println(bound_address)
    server, make_err := net.make_bound_udp_socket(bound_address, 30)
    if make_err != nil {
        fmt.eprintln(net.last_platform_error_string())
        os2.exit(1)
    }
    defer net.close(server)

    for {
        bytes_read, client_endpoint, read_err := net.recv_udp(server, buf[:])
        if read_err != nil {
            continue
        }

        packet: sh.Packet

        cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &packet)

        deal_with_packet(server, packet, client_endpoint)
    }
}


init_lobby :: proc(data: sh.Create_Lobby_Packet, host_endpoint: net.Endpoint) -> Lobby {
    new_lobby := Lobby{
        lobby_name = data.lobby_name,
        host_name = data.host_name,
    }

    new_lobby.host_profile = sh.Private_Profile{
        endpoint = host_endpoint,
        assigned_id = new_lobby.id_counter,
        user_name = new_lobby.host_name,
    }

    new_lobby.id_counter += 1
    return new_lobby
}

deal_with_packet :: proc(server: net.UDP_Socket, packet: sh.Packet, remote: net.Endpoint) -> (cbor_err: cbor.Marshal_Error) {

    send_err :: proc(server: net.UDP_Socket, remote: net.Endpoint, err: string) {
        send_response(server, remote, sh.Response(sh.Error(err)))
    }

    send_response:: proc(server: net.UDP_Socket, remote: net.Endpoint, response: sh.Response) {
        bytes, _ := cbor.marshal_into_bytes(response) 
        defer delete(bytes)
        bytes_sent, send_err := net.send_udp(server, bytes, remote) 
        if send_err != nil {
            fmt.eprintfln("Problem sending packet: %v", send_err)
        }
        return
    }

    #partial switch data in packet {
        case sh.Create_Lobby_Packet:
            if data.lobby_id in lobbies {
                send_err(server, remote, "Lobby id already exists")
                return
            }

            new_lobby := init_lobby(data, remote)
            lobbies[data.lobby_id] = new_clone(new_lobby)
            success_response := sh.Response(sh.Create_Response{assigned_id = new_lobby.host_profile.assigned_id})
            send_response(server, remote, success_response)

         case sh.Join_Lobby_Packet:
            lobby, ok := lobbies[data.lobby_id]
            if !ok {
                send_err(server, remote, "Invalid lobby ID")
                return
            }

            if lobby.joined_count >= sh.MAX_PLAYER_COUNT - 1 {
                send_err(server, remote, "Lobby is full")
                return
            }

            if lobby.host_profile.endpoint == remote {
                send_err(server, remote, "You are the host of this lobby")
                return
            }

            for profile in lobby.joined[:lobby.joined_count] {
                if profile.endpoint == remote {
                    send_err(server, remote, "You already joined this lobby")
                    return
                }
            }

            assigned_id := lobby.id_counter
            lobby.joined[lobby.joined_count] = sh.Private_Profile{ 
                endpoint = remote,
                assigned_id = assigned_id,
                user_name = data.join_name,
            }
            lobby.joined_count += 1
            lobby.id_counter += 1

            success_response := sh.Response(sh.Join_Lobby_Response{assigned_id, lobby.lobby_name, lobby.host_name}) 
            send_response(server, remote, success_response)
        case sh.Leave_Lobby_Packet:
            lobby, ok := lobbies[data.lobby_id]
            if !ok {
                send_err(server, remote, "Invalid lobby ID")
                return
            }

            for profile, i in lobby.joined[:lobby.joined_count] {
                if profile.assigned_id == data.assigned_id {
                    last := lobby.joined_count - 1
                    lobby.joined[i] = lobby.joined[last]
                    lobby.joined[last] = {}
                    lobby.joined_count -= 1 
                    success_response := sh.Response(sh.Leave_Lobby_Response{})
                    send_response(server, remote, success_response)
                    return
                }
            }

            send_err(server, remote, "Invalid assigned ID")
        case sh.Start_Lobby_Packet:
            lobby, ok := lobbies[data.lobby_id]

            if !ok {
                send_err(server, remote, "Invalid lobby ID")
            }

            if lobby.host_profile.assigned_id != data.host_id {
                send_err(server, remote, "Not the host of this lobby")
            }

            // Send Start Lobby Response
            success_response := sh.Response(sh.Start_Lobby_Response{host = lobby.host_profile, players = lobby.joined[:lobby.joined_count]})
            send_response(server, lobby.host_profile.endpoint, success_response)

            for player_profile in lobby.joined[:lobby.joined_count] {
                send_response(server, player_profile.endpoint, success_response)
            }

            _, lobby_data := delete_key(&lobbies, data.lobby_id)
            free(lobby_data)
    }
    return
}