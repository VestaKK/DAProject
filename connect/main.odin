package main

import "core:net"
import "core:fmt"
import "core:os/os2"
import "core:encoding/cbor"
import sh "../shared"

main :: proc() {
    endpoint := net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = 1111}
    client, make_err := net.make_bound_udp_socket(net.IP4_Address{127,0,0,1}, 1234)
    if make_err != nil {
        fmt.eprintln(net.last_platform_error_string())
        os2.exit(1)
    }
    defer net.close(client)

    packet: sh.Packet
    packet = sh.Create_Lobby_Packet{name = "My Lobby", size = 4}
    bytes, marshal_err := cbor.marshal_into_bytes(packet)

    if marshal_err != nil {
        fmt.eprintfln("Problem marshalling data: %v", marshal_err)
        os2.exit(1)
    }

    bytes_written, send_err := net.send_udp(client, bytes[:], endpoint)
    if send_err != nil {
        fmt.eprintln(net.last_platform_error_string())
        os2.exit(1)
    }

    buf: [64]byte
    bytes_read, _, read_err := net.recv_udp(client, buf[:])
    if read_err != nil {
        fmt.eprintln(net.last_platform_error_string())
        os2.exit(1)
    }
    fmt.println(transmute(string)buf[:bytes_read])
}