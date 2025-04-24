package main

import "core:fmt"
import "core:net"
import "core:os/os2"
import "core:encoding/cbor"
import sh "../shared"

buf: [1024]byte
main :: proc() { 
    server, make_err := net.make_bound_udp_socket(net.IP4_Address{127,0,0,1}, 1111)
    if make_err != nil {
        fmt.eprintln(net.last_platform_error_string())
        os2.exit(1)
    }
    defer net.close(server)

    for {
        bytes_read, remote, read_err := net.recv_udp(server, buf[:])
        if read_err != nil {
            continue
        } 

        packet: sh.Packet
        cbor.unmarshal_from_string(transmute(string)buf[:bytes_read], &packet)

        fmt.println(packet)
        #partial switch data in packet{
            case sh.Create_Lobby_Packet:
                fmt.println(data.name)
        }

        msg := "Hi Logang"
        bytes_written, send_err := net.send_udp(server, transmute([]byte)msg[:], remote)
        if send_err != nil {
            continue
        }
    }
}